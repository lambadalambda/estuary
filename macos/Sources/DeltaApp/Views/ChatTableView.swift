import AppKit
import SwiftUI

/// AppKit-backed message list (issue: appkit-message-table-port): an
/// NSTableView with SwiftUI bubbles in recycled hosting rows. Exists
/// because both SwiftUI containers failed one half of the chat contract —
/// the eager VStack obeys scroll commands but renders O(window), List
/// virtualizes but silently drops programmatic scrolls. Here every
/// behavior is an explicit, synchronous AppKit call:
///
/// - open lands at the bottom after the first entry assembly;
/// - `followBottomGeneration` bumps scroll to the bottom, immediately;
/// - `viewIsAtBottom` derives from documentVisibleRect (no sentinel);
/// - nearing the top triggers loadOlder; prepends restore the reading
///   position via saved-anchor math;
/// - MDN visibility reports the actual visible row range.
///
/// Row heights are measured once per (entry, width) through a sizing
/// hosting view and cached — exact heights keep every scroll computation
/// deterministic (the LazyVStack estimation failures are the origin story
/// of half this file's requirements).
struct ChatTableView: NSViewRepresentable {
    @Bindable var model: AppModel
    let accountId: UInt32
    let selectionGeneration: UInt64
    let chat: ChatItem
    let onForward: (UInt32) -> Void
    let onPreview: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model, accountId: accountId,
            selectionGeneration: selectionGeneration, chat: chat,
            onForward: onForward, onPreview: onPreview)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.apply(
            entries: model.messageListEntries,
            followGeneration: model.followBottomGeneration)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let model: AppModel
        private let accountId: UInt32
        private let selectionGeneration: UInt64
        private let chat: ChatItem
        private let onForward: (UInt32) -> Void
        private let onPreview: (URL) -> Void

        private var entries: [MessageListEntry] = []
        private var ids: [String] = []
        private var lastFollowGeneration: UInt64?
        private var heightCache: [String: CGFloat] = [:]
        private var cachedWidth: CGFloat = 0
        private var visibleReported: Set<String> = []
        private var loadingOlder = false
        private var applying = false

        private var table: NSTableView!
        private var scroll: NSScrollView!
        private let sizingHost = NSHostingController(rootView: AnyView(EmptyView()))

        /// Trigger loadOlder when the viewport top is within this many
        /// points of the loaded content's top.
        private static let loadOlderThreshold: CGFloat = 300
        /// "At bottom" tolerance: overlay scroller bounce and fractional
        /// row heights make exact equality flappy.
        private static let bottomSlop: CGFloat = 4

        init(
            model: AppModel, accountId: UInt32, selectionGeneration: UInt64,
            chat: ChatItem, onForward: @escaping (UInt32) -> Void,
            onPreview: @escaping (URL) -> Void
        ) {
            self.model = model
            self.accountId = accountId
            self.selectionGeneration = selectionGeneration
            self.chat = chat
            self.onForward = onForward
            self.onPreview = onPreview
        }

        func makeScrollView() -> NSScrollView {
            let table = NSTableView()
            table.headerView = nil
            table.style = .plain
            table.selectionHighlightStyle = .none
            table.backgroundColor = .clear
            table.intercellSpacing = NSSize(width: 0, height: 6)
            let column = NSTableColumn(identifier: .init("bubble"))
            table.addTableColumn(column)
            table.dataSource = self
            table.delegate = self
            self.table = table

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameChanged),
                name: NSView.frameDidChangeNotification,
                object: scroll)
            scroll.postsFrameChangedNotifications = true
            self.scroll = scroll
            return scroll
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Update application

        func apply(entries newEntries: [MessageListEntry], followGeneration: UInt64) {
            let newIds = newEntries.map(\.id)
            let transition = entriesTransition(from: ids, to: newIds)
            let followRequested =
                lastFollowGeneration != nil && followGeneration != lastFollowGeneration
            lastFollowGeneration = followGeneration

            if transition != .none {
                applying = true
                applyTransition(transition, newEntries: newEntries, newIds: newIds)
                applying = false
            }
            if followRequested || transition == .initial {
                scrollToBottom()
            }
            syncDerivedState()
        }

        private func applyTransition(
            _ transition: EntriesTransition,
            newEntries: [MessageListEntry], newIds: [String]
        ) {
            switch transition {
            case .none:
                return
            case .initial:
                entries = newEntries
                ids = newIds
                table.reloadData()
                scrollToBottom()
            case .inPlace:
                let old = entries
                entries = newEntries
                ids = newIds
                refreshChangedRows(from: old)
            case .appended(let count):
                entries = newEntries
                ids = newIds
                table.insertRows(
                    at: IndexSet(
                        integersIn: (newEntries.count - count) ..< newEntries.count),
                    withAnimation: [])
            case .prepended(let count):
                let anchor = saveAnchor()
                entries = newEntries
                ids = newIds
                table.insertRows(
                    at: IndexSet(integersIn: 0 ..< count), withAnimation: [])
                restoreAnchor(anchor)
            case .slide(let droppedTop, let appended):
                let anchor = saveAnchor()
                entries = newEntries
                ids = newIds
                table.beginUpdates()
                table.removeRows(
                    at: IndexSet(integersIn: 0 ..< droppedTop), withAnimation: [])
                table.insertRows(
                    at: IndexSet(
                        integersIn: (newEntries.count - appended) ..< newEntries.count),
                    withAnimation: [])
                table.endUpdates()
                if !isAtBottom() { restoreAnchor(anchor) }
            case .reset:
                let anchor = saveAnchor()
                let wasAtBottom = isAtBottom()
                entries = newEntries
                ids = newIds
                heightCache.removeAll()
                table.reloadData()
                if wasAtBottom {
                    scrollToBottom()
                } else {
                    restoreAnchor(anchor)
                }
            }
        }

        /// In-place refresh: only rows whose entry actually changed get a
        /// new rootView (and a height invalidation when the change can
        /// resize the bubble — reactions arriving, state ticks are free).
        private func refreshChangedRows(from old: [MessageListEntry]) {
            guard old.count == entries.count else {
                table.reloadData()
                return
            }
            var resized = IndexSet()
            for row in 0 ..< entries.count where old[row] != entries[row] {
                if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NSHostingView<AnyView> {
                    view.rootView = rowContent(entries[row])
                }
                heightCache.removeValue(forKey: heightKey(entries[row]))
                resized.insert(row)
            }
            if !resized.isEmpty {
                table.noteHeightOfRows(withIndexesChanged: resized)
            }
        }

        // MARK: Scroll geometry

        private func contentHeight() -> CGFloat {
            table.frame.height
        }

        private func isAtBottom() -> Bool {
            let clip = scroll.contentView.bounds
            return chatIsAtBottom(
                viewportMaxY: clip.maxY, contentHeight: contentHeight(),
                lastRowMinY: ids.isEmpty
                    ? nil : table.rect(ofRow: ids.count - 1).minY,
                slop: Self.bottomSlop)
        }

        private func scrollToBottom() {
            table.layoutSubtreeIfNeeded()
            let clip = scroll.contentView.bounds
            let target = max(0, contentHeight() - clip.height)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            model.scrollDebug("table: pin bottom (y=\(Int(target)))")
        }

        private struct Anchor {
            let id: String
            let offsetInViewport: CGFloat
        }

        /// First fully-visible row + its offset from the viewport top: the
        /// reading position, independent of everything above it.
        private func saveAnchor() -> Anchor? {
            let visible = table.rows(in: scroll.contentView.bounds)
            guard visible.length > 0, visible.location < ids.count else { return nil }
            let row = visible.location
            let rowRect = table.rect(ofRow: row)
            return Anchor(
                id: ids[row],
                offsetInViewport: rowRect.minY - scroll.contentView.bounds.minY)
        }

        private func restoreAnchor(_ anchor: Anchor?) {
            guard let anchor, let row = ids.firstIndex(of: anchor.id) else { return }
            table.layoutSubtreeIfNeeded()
            let rowRect = table.rect(ofRow: row)
            let target = max(0, rowRect.minY - anchor.offsetInViewport)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            model.scrollDebug("table: restore anchor \(anchor.id) (y=\(Int(target)))")
        }

        @objc private func boundsChanged() {
            guard !applying else { return }
            syncDerivedState()
        }

        @objc private func frameChanged() {
            // Width changed: every cached height is stale.
            let width = scroll.contentView.bounds.width
            if width != cachedWidth, width > 0 {
                let wasAtBottom = isAtBottom()
                cachedWidth = width
                heightCache.removeAll()
                table.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integersIn: 0 ..< entries.count))
                if wasAtBottom { scrollToBottom() }
            }
        }

        /// The single funnel for scroll-derived model state: at-bottom,
        /// loadOlder proximity, and MDN visibility.
        private func syncDerivedState() {
            let atBottom = isAtBottom()
            if model.viewIsAtBottom != atBottom {
                model.scrollDebug("table: at-bottom=\(atBottom)")
                model.viewIsAtBottom = atBottom
            }
            if AppModel.scrollDebugEnabled {
                let clip = scroll.contentView.bounds
                model.scrollDebug(
                    "geo: offset=\(Int(clip.minY)) content=\(Int(contentHeight())) "
                        + "container=\(Int(clip.height))")
            }
            maybeLoadOlder()
            reportVisibility()
        }

        private func maybeLoadOlder() {
            guard model.hasMoreMessages, !loadingOlder,
                  scroll.contentView.bounds.minY < Self.loadOlderThreshold
            else { return }
            loadingOlder = true
            Task { [weak self] in
                guard let self else { return }
                // Outcome-based scrolling is the SwiftUI path; the table
                // restores position itself in the .prepended transition.
                _ = await self.model.loadOlderMessages()
                self.loadingOlder = false
            }
        }

        private func reportVisibility() {
            let range = table.rows(in: scroll.contentView.bounds)
            guard range.location != NSNotFound else { return }
            var nowVisible: Set<String> = []
            for row in range.location ..< (range.location + range.length)
            where row < entries.count {
                if case .message(let message, _) = entries[row] {
                    nowVisible.insert(entries[row].id)
                    if !visibleReported.contains(entries[row].id) {
                        model.messageVisibilityChanged(
                            accountId: accountId, chatId: chat.id,
                            selectionGeneration: selectionGeneration,
                            message: message, visible: true)
                    }
                }
            }
            for id in visibleReported.subtracting(nowVisible) {
                if let row = ids.firstIndex(of: id),
                   case .message(let message, _) = entries[row] {
                    model.messageVisibilityChanged(
                        accountId: accountId, chatId: chat.id,
                        selectionGeneration: selectionGeneration,
                        message: message, visible: false)
                }
            }
            visibleReported = nowVisible
        }

        // MARK: Rows

        nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
            MainActor.assumeIsolated { entries.count }
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("bubble-cell")
            let content = rowContent(entries[row])
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSHostingView<AnyView> {
                reused.rootView = content
                return reused
            }
            let hosting = NSHostingView(rootView: content)
            hosting.identifier = identifier
            return hosting
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let entry = entries[row]
            let key = heightKey(entry)
            if let cached = heightCache[key] { return cached }
            let width = scroll?.contentView.bounds.width ?? cachedWidth
            guard width > 0 else { return 44 }
            let height = sizingHost.fittingHeight(
                of: rowContent(entry), forWidth: width)
            heightCache[key] = height
            return height
        }

        private func heightKey(_ entry: MessageListEntry) -> String {
            entry.id
        }

        private func rowContent(_ entry: MessageListEntry) -> AnyView {
            switch entry {
            case .dayMarker(_, let label):
                return AnyView(
                    DayMarkerView(label: label)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2))
            case .message(let message, let showAuthor):
                return AnyView(
                    MessageBubbleView(
                        model: model, message: message, showAuthor: showAuthor,
                        inGroup: chat.isGroup,
                        onForward: { [onForward] in onForward(message.id) },
                        onPreview: onPreview)
                    .padding(.horizontal, 16))
            }
        }
    }
}

extension NSHostingController where Content == AnyView {
    /// Height of `content` when constrained to `width` — the row-height
    /// measurement primitive for the chat table's cache. The width is
    /// fixed and `fixedSize(vertical:)` pins the height to the content's
    /// IDEAL at that width: wrapping Text reports its full wrapped height
    /// (NSHostingView.fittingSize returned one line — the truncated-bubble
    /// bug), while greedy decorations like the quote accent bar keep
    /// their ideal size instead of inflating an unbounded proposal (the
    /// giant-bubble bug the first, (width, ∞)-proposal fix introduced).
    @MainActor func fittingHeight(
        of content: some View, forWidth width: CGFloat
    ) -> CGFloat {
        rootView = AnyView(
            content
                .frame(width: width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true))
        return sizeThatFits(in: NSSize(width: width, height: 0)).height
    }
}
