import AVFoundation
import QuickLook
import SwiftUI
import UniformTypeIdentifiers


struct ChatDetailView: View {
    @Bindable var model: AppModel
    let accountId: UInt32
    let selectionGeneration: UInt64
    let chat: ChatItem

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(
                model: model, accountId: accountId,
                selectionGeneration: selectionGeneration, chat: chat)
            ChatComposerView(model: model, accountId: accountId, chat: chat)
        }
        .navigationTitle(chat.name)
        .navigationSubtitle(chat.isContactRequest ? "Contact request" : "")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let caption = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            let quotedMsgId = model.replyTo?.id
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        Task { @MainActor in
                            sendDroppedFile(
                                url: url, caption: caption,
                                quotedMsgId: quotedMsgId)
                        }
                    }
                }
            }
            return true
        }
    }

    private func sendDroppedFile(url: URL, caption: String, quotedMsgId: UInt32?) {
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            await model.sendAttachment(
                accountId: accountId, chatId: chat.id, path: url.path,
                caption: caption, quotedMsgId: quotedMsgId)
        }
    }
}

private struct MessageListView: View {
    @Bindable var model: AppModel
    let accountId: UInt32
    let selectionGeneration: UInt64
    let chat: ChatItem
    @State private var forwardingMsgId: UInt32?
    @State private var quickLookURL: URL?

    // The AppKit table is the sole container since the five-behavior
    // gauntlet + user sign-off (appkit-message-table-port). The SwiftUI
    // containers it replaced — eager VStack (correct but O(window)) and
    // List (fast but drops programmatic scrolls) — are preserved in git
    // history and in the spike issue's data, not in this file.
    var body: some View {
        ChatTableView(
            model: model, accountId: accountId,
            selectionGeneration: selectionGeneration, chat: chat,
            onForward: { forwardingMsgId = $0 },
            onPreview: { quickLookURL = $0 })
            .id(chat.id)
            .quickLookPreview($quickLookURL)
            .sheet(item: $forwardingMsgId) { msgId in
                ForwardSheet(model: model, msgId: msgId)
            }
    }
}

private struct ChatComposerView: View {
    @Bindable var model: AppModel
    let accountId: UInt32
    let chat: ChatItem
    @State private var showAttachPicker = false
    @State private var attachmentCaption = ""
    @State private var attachmentReplyId: UInt32?
    @FocusState private var composerFocused: Bool

    var body: some View {
        composer
            .onAppear { composerFocused = true }
            .onChange(of: chat.id) { composerFocused = true }
            .fileImporter(isPresented: $showAttachPicker, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    sendFile(
                        url: url, caption: attachmentCaption,
                        quotedMsgId: attachmentReplyId)
                }
            }
    }

    @ViewBuilder
    private var composer: some View {
        if chat.isContactRequest {
            HStack(spacing: 12) {
                Button("Accept") {
                    Task { await model.acceptSelectedChat() }
                }
                .buttonStyle(.borderedProminent)
                Button("Block", role: .destructive) {
                    Task { await model.blockSelectedChat() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .composerCard()
        } else {
            VStack(spacing: 0) {
                if let replyTo = model.replyTo {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hex: replyTo.senderColor))
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(replyTo.senderName)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color(hex: replyTo.senderColor))
                            Text(replyTo.text.isEmpty ? (replyTo.fileName ?? "Attachment") : replyTo.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            model.replyTo = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                // Baseline alignment centers the icons with a single line
                // and keeps them anchored to the last line as the field
                // grows — no hand-tuned paddings.
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Button {
                        attachmentCaption = model.draft.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        attachmentReplyId = model.replyTo?.id
                        showAttachPicker = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    // Grows up to 5 lines; Return sends, Option+Return
                    // inserts a newline.
                    TextField("Message \(chat.name)…", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1 ... 5)
                        .focused($composerFocused)
                        .onSubmit(sendDraft)
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? EstuaryTheme.accent : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || model.isSendingCurrentConversation)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .composerCard()
        }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        composerFocused = true
        Task { await model.send(text) }
    }

    private func sendFile(url: URL, caption: String, quotedMsgId: UInt32?) {
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            await model.sendAttachment(
                accountId: accountId, chatId: chat.id, path: url.path,
                caption: caption, quotedMsgId: quotedMsgId)
        }
    }
}

extension View {
    /// One rounded-card recipe for the chat chrome: message bubbles and the
    /// composer share it, so radius, surface, and shadow can't drift apart.
    fileprivate func cardSurface(_ fill: AnyShapeStyle, shadowed: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fill)
                .shadow(color: .black.opacity(shadowed ? 0.10 : 0), radius: 1.5, y: 1))
    }

    /// Floating input card over the tiled chat backdrop — an incoming-bubble
    /// surface, so the composer reads as part of the conversation instead of
    /// a separate square bar. The top padding keeps a strip of backdrop
    /// visible between the scrolled messages and the card.
    fileprivate func composerCard() -> some View {
        cardSurface(AnyShapeStyle(EstuaryTheme.incomingBubble), shadowed: true)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 10)
    }
}

extension UInt32: @retroactive Identifiable {
    public var id: UInt32 { self }
}

// MARK: - Forward sheet

struct ForwardSheet: View {
    let model: AppModel
    let msgId: UInt32
    @Environment(\.dismiss) private var dismiss
    /// Full unfiltered chat list — the sidebar may be showing search results.
    @State private var targets: [ChatItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forward to…")
                .font(.title3.bold())
            List(targets) { chat in
                Button {
                    dismiss()
                    Task { await model.forwardMessage(msgId: msgId, to: chat.id) }
                } label: {
                    HStack {
                        AvatarView(name: chat.name, colorHex: chat.color, size: 24)
                        Text(chat.name)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 320)
        .task { targets = await model.forwardTargets() }
    }
}

/// Chat surface + the tiled brand pattern (per-appearance variant).
struct ChatBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            EstuaryTheme.chatSurface
            if let tile = EstuaryTheme.chatTile(dark: scheme == .dark) {
                Image(nsImage: tile)
                    .resizable(resizingMode: .tile)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Day separator

struct DayMarkerView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

// MARK: - Message bubble

struct MessageBubbleView: View {
    let model: AppModel
    let message: MessageItem
    let showAuthor: Bool
    var inGroup = false
    var onForward: () -> Void = {}
    /// Quick Look request (space-bar-style preview owned by the chat view).
    var onPreview: (URL) -> Void = { _ in }

    var body: some View {
        if message.isInfo {
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .frame(maxWidth: .infinity)
        } else if message.isOutgoing {
            HStack(alignment: .bottom) {
                Spacer(minLength: 80)
                bubbleWithReactions
                    .frame(maxWidth: 560, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                if inGroup {
                    // Avatar on the first bubble of a sender's run; the rest
                    // keep the indent so bubbles stay aligned.
                    if showAuthor {
                        ChatAvatarView(
                            name: message.senderName,
                            colorHex: message.senderColor,
                            avatarPath: message.senderAvatar,
                            size: 28)
                    } else {
                        Color.clear.frame(width: 28, height: 1)
                    }
                }
                bubbleWithReactions
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 80)
            }
        }
    }

    private var bubbleWithReactions: some View {
        // Reactions render INSIDE the bubble card (Telegram-style pills);
        // the wrapper only carries the context menu now.
        bubble
            .contextMenu { contextMenu }
    }

    private var bubble: some View {
        // Content defines the bubble width (bubbles hug their text and stay
        // anchored to their side); the timestamp overlays bottom-trailing
        // instead of stretching the bubble to the full row width.
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 3) {
            if showAuthor {
                Text(message.senderName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: message.senderColor))
            }
            if let quote = message.quote {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(message.isOutgoing
                            ? Color.white.opacity(0.85) : Color(hex: quote.senderColor))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        if !quote.senderName.isEmpty {
                            Text(quote.senderName)
                                .font(.caption.weight(.bold))
                                // Contact colors are tuned for light/dark
                                // surfaces, not the deep-teal bubble — on
                                // outgoing everything must stay white.
                                .foregroundStyle(message.isOutgoing
                                    ? Color.white : Color(hex: quote.senderColor))
                        }
                        Text(quote.text)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(message.isOutgoing ? .white : .primary)
                            .opacity(0.85)
                    }
                }
                .padding(6)
                .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            mediaContent

            if !message.text.isEmpty {
                if containsLink(message.text) {
                    // AppKit-backed: per-range hand cursor + native link
                    // clicks; SwiftUI's pointerStyle loses to the selection
                    // pointer here.
                    LinkText(
                        text: message.text,
                        textColor: message.isOutgoing ? .white : .labelColor,
                        linkColor: message.isOutgoing
                            ? .white : EstuaryTheme.accentNSColor)
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                        .foregroundStyle(message.isOutgoing ? .white : .primary)
                }
            }
            if !message.reactions.isEmpty {
                ReactionChipsView(model: model, message: message)
                    .padding(.top, 3)
            }
            }
            // Reserved line so the overlaid footer never covers text.
            .padding(.bottom, 15)
            HStack(spacing: 4) {
                TimelineView(.everyMinute) { timeline in
                    Text(messageTimestamp(message.timestamp, now: timeline.date))
                        .font(.caption2)
                }
                if message.isOutgoing {
                    DeliveryStateView(state: message.state)
                }
            }
            .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.75) : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The card fill is deliberately close to the surface (calm);
        // the faint shadow is what delineates incoming bubbles.
        .cardSurface(
            message.isOutgoing
                ? AnyShapeStyle(EstuaryTheme.bubble)
                : AnyShapeStyle(EstuaryTheme.incomingBubble),
            shadowed: !message.isOutgoing)
    }

    /// Display size derived from core's stored pixel dimensions, so the
    /// bubble has its final size BEFORE the image blob is loaded/downloaded —
    /// no post-hoc growth, no scroll drift.
    private var imageDisplaySize: CGSize? {
        guard message.width > 0, message.height > 0 else { return nil }
        let w = CGFloat(message.width)
        let h = CGFloat(message.height)
        let scale = min(320 / w, 320 / h, 1)
        return CGSize(width: max(w * scale, 40), height: max(h * scale, 40))
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch message.kind {
        case .image, .gif, .sticker:
            let image = message.file.flatMap(ImageCache.load)
            if let size = imageDisplaySize {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Blob still downloading: reserve the final size.
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { openFile() }
            } else if let image {
                // Dimensions unknown: size from the decoded image (stable
                // across renders once the file exists).
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { openFile() }
            } else {
                fileRow(icon: "photo")
            }
        case .audio, .voice:
            AudioMessageView(message: message)
        case .video:
            fileRow(icon: "video.fill")
        case .file, .vcard, .webxdc, .unknown:
            if message.file != nil {
                fileRow(icon: message.kind == .webxdc ? "app.gift" : "doc.fill")
            }
        case .text:
            EmptyView()
        }
    }

    private func fileRow(icon: String) -> some View {
        Button(action: openFile) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.fileName ?? "Attachment")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if message.fileSize > 0 {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(message.fileSize), countStyle: .file))
                            .font(.caption2)
                            .opacity(0.7)
                    }
                }
            }
            .foregroundStyle(message.isOutgoing ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// Tap: Quick Look preview in place; "Open in App" lives in the menu.
    private func openFile() {
        if let file = message.file {
            onPreview(URL(fileURLWithPath: file))
        }
    }

    private func openInApp() {
        if let file = message.file {
            NSWorkspace.shared.open(URL(fileURLWithPath: file))
        }
    }

    // Telegram-style menu (issue: telegram-style-context-menu): the pure
    // descriptor decides the rows, this just renders them.
    @ViewBuilder
    private var contextMenu: some View {
        let entries = messageContextMenuEntries(
            for: message, quickReactions: defaultQuickReactions)
        ForEach(entries.indices, id: \.self) { index in
            menuEntry(entries[index])
        }
    }

    @ViewBuilder
    private func menuEntry(_ entry: MessageMenuEntry) -> some View {
        switch entry {
        case .reactionPalette(let emojis, let selected):
            // Horizontal emoji strip; the user's current reaction shows
            // selected, and picking it again clears it (toggle semantics).
            // Palette items display their ICON only — a text label renders
            // as an empty slot — so the emoji is rasterized into one.
            ControlGroup {
                ForEach(emojis, id: \.self) { emoji in
                    let isSelected = selected == emoji
                    Toggle(
                        isOn: Binding(
                            get: { isSelected },
                            set: { _ in
                                Task {
                                    await model.toggleReaction(
                                        message: message, emoji: emoji)
                                }
                            })
                    ) {
                        Label {
                            Text(emoji)
                        } icon: {
                            if let icon = Self.emojiIcon(emoji, selected: isSelected) {
                                Image(nsImage: icon)
                            }
                        }
                    }
                }
            }
            .controlGroupStyle(.palette)
        case .reply:
            Button { model.replyTo = message } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
        case .copyText:
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
        case .copyMedia:
            Button(action: copyMedia) {
                Label("Copy Media", systemImage: "photo.on.rectangle")
            }
        case .saveAs:
            Button(action: saveAs) {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
        case .quickLook:
            Button(action: openFile) {
                Label("Quick Look", systemImage: "eye")
            }
        case .openInApp:
            Button(action: openInApp) {
                Label("Open in App", systemImage: "arrow.up.forward.app")
            }
        case .forward:
            Button(action: onForward) {
                Label("Forward…", systemImage: "arrowshape.turn.up.right")
            }
        case .reacted(let total):
            reactedMenu(total: total)
        case .delete:
            Button(role: .destructive) {
                Task { await model.deleteMessage(msgId: message.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .divider:
            Divider()
        }
    }

    private func reactedMenu(total: UInt32) -> some View {
        let summary = reactedSummary(for: message)
        return Menu {
            // Informational rows (Telegram opens profiles here; we don't
            // have those yet), kept as no-op buttons so avatars render at
            // full color instead of disabled-grey.
            ForEach(summary.rows.indices, id: \.self) { index in
                let row = summary.rows[index]
                Button {
                } label: {
                    Label {
                        Text("\(row.name)   \(row.emoji)")
                    } icon: {
                        // Rendered per menu open, uncached: dcvm caps the
                        // rows at three and ImageCache holds the decoded
                        // avatar photos.
                        if let avatar = Self.rasterizeMenuIcon(ChatAvatarView(
                            name: row.name, colorHex: row.color,
                            avatarPath: row.avatarPath, size: 18))
                        {
                            Image(nsImage: avatar)
                        }
                    }
                }
            }
            if summary.othersCount > 0 {
                Text("and \(summary.othersCount) more")
            }
        } label: {
            Label("\(total) Reacted", systemImage: "hands.clap")
        }
    }

    /// Menu items can only carry a plain image, so palette emojis and
    /// avatar bubbles are rasterized at menu-icon size (palette items
    /// additionally render their ICON only — a text label comes out as an
    /// empty slot).
    @MainActor
    private static func rasterizeMenuIcon(_ content: some View) -> NSImage? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    /// Rasterized emoji for palette slots, cached — the menu re-renders on
    /// every open and the set of quick reactions is tiny and fixed. The
    /// user's current reaction gets a circle baked in (Telegram-style):
    /// palette selection tinting can't touch a non-template emoji image.
    /// Appearance and display scale are part of the key: both are baked
    /// into the bitmap at render time.
    @MainActor private static var emojiIconCache: [String: NSImage] = [:]

    @MainActor
    private static func emojiIcon(_ emoji: String, selected: Bool) -> NSImage? {
        let dark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(selected ? "sel" : "plain")-\(dark ? "d" : "l")-\(scale)-\(emoji)"
        if let hit = emojiIconCache[key] { return hit }
        let image = rasterizeMenuIcon(
            Text(emoji)
                .font(.system(size: 15))
                .padding(3)
                .background(
                    selected ? Color.secondary.opacity(0.4) : Color.clear,
                    in: Circle()))
        image.map { emojiIconCache[key] = $0 }
        return image
    }

    private func copyMedia() {
        guard let file = message.file else { return }
        NSPasteboard.general.clearContents()
        // File URL first so URL-preferring targets (Finder, apps that keep
        // GIF animation) get the original blob; the decoded image covers
        // plain image paste.
        var objects: [NSPasteboardWriting] = [URL(fileURLWithPath: file) as NSURL]
        if let image = ImageCache.load(file) {
            objects.append(image)
        }
        NSPasteboard.general.writeObjects(objects)
    }

    private func saveAs() {
        guard let file = message.file else { return }
        let source = URL(fileURLWithPath: file)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = message.fileName ?? source.lastPathComponent
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            let fm = FileManager.default
            do {
                // Never touch the blob itself, and check the source before
                // removing the user's existing file — the overwrite the
                // panel confirmed must not destroy data on a failed copy.
                guard dest.standardizedFileURL != source.standardizedFileURL
                else { return }
                guard fm.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: source, to: dest)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

// MARK: - Image cache

/// Decoded-image cache: every bubble body re-evaluates on view updates
/// (eager VStack) and `NSImage(contentsOfFile:)` hits the disk every time.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(_ path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) {
            return hit
        }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

// MARK: - Reactions

/// Telegram-style reaction pills (issue: telegram-style-reactions): emoji
/// plus overlapping reactor avatars when identities cover everyone, the
/// count otherwise; accent-filled when the user reacted. Lives inside the
/// bubble card, so fills are tuned against both bubble surfaces.
struct ReactionChipsView: View {
    let model: AppModel
    let message: MessageItem

    var body: some View {
        HStack(spacing: 5) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                Button {
                    Task { await model.toggleReaction(message: message, emoji: reaction.emoji) }
                } label: {
                    chip(reaction)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ reaction: ReactionItem) -> some View {
        let avatars = showsAvatars(reaction)
        return HStack(spacing: 5) {
            Text(reaction.emoji)
                .font(.callout)
            if avatars {
                // Overlapping reactor bubbles, first reactor in front; the
                // ring approximates the surface under the pill so the
                // circles read as separate.
                HStack(spacing: -7) {
                    ForEach(Array(reaction.reactors.enumerated()), id: \.offset) {
                        index, reactor in
                        ChatAvatarView(
                            name: reactor.name, colorHex: reactor.color,
                            avatarPath: reactor.avatarPath, size: 18)
                            .overlay(Circle().strokeBorder(
                                ringColor(reaction), lineWidth: 1.5))
                            .zIndex(Double(-index))
                    }
                }
            } else {
                Text("\(reaction.count)")
                    .font(.caption.weight(.semibold))
                    // The outgoing bubble is deep teal in BOTH appearances:
                    // like all in-bubble text, the count must stay white
                    // there (a capped pill has isFromSelf false even on
                    // own messages).
                    .foregroundStyle(
                        reaction.isFromSelf || message.isOutgoing
                            ? Color.white : .primary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, avatars ? 5 : 9)
        .padding(.vertical, 2.5)
        .background(fillColor(reaction), in: Capsule())
    }

    /// Avatars when the carried identities cover every reactor; the bare
    /// count once people outnumber them (dcvm caps identities at 3).
    private func showsAvatars(_ reaction: ReactionItem) -> Bool {
        !reaction.reactors.isEmpty && reaction.reactors.count == Int(reaction.count)
    }

    private func fillColor(_ reaction: ReactionItem) -> Color {
        if reaction.isFromSelf {
            return message.isOutgoing
                ? Color.white.opacity(0.30) : EstuaryTheme.accent
        }
        return message.isOutgoing
            ? Color.white.opacity(0.18) : EstuaryTheme.accent.opacity(0.12)
    }

    private func ringColor(_ reaction: ReactionItem) -> Color {
        if message.isOutgoing {
            // Translucent white fills composite over the teal bubble; a
            // teal ring reads as the gap between circles there.
            return EstuaryTheme.bubble
        }
        return reaction.isFromSelf ? EstuaryTheme.accent : .white
    }
}

// MARK: - Audio playback

/// One shared player: starting a message stops the previous one.
@MainActor
final class AudioPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayerController()
    @Published var playingPath: String?
    private var player: AVAudioPlayer?

    func toggle(path: String) {
        if playingPath == path {
            player?.stop()
            playingPath = nil
            return
        }
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        player?.delegate = self
        player?.play()
        playingPath = player != nil ? path : nil
    }

    /// Natural end of playback: reset the button state (otherwise the pause
    /// icon sticks forever and the next click "stops" a stopped player).
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Only clear state for the player that actually finished — the user
        // may have started another track before the hop lands. Identity via
        // ObjectIdentifier: the player itself is not Sendable.
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.playingPath = nil
            self.player = nil
        }
    }
}

struct AudioMessageView: View {
    let message: MessageItem
    @ObservedObject private var player = AudioPlayerController.shared

    private var isPlaying: Bool { player.playingPath == message.file }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let file = message.file { player.toggle(path: file) }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.kind == .voice ? "Voice message" : (message.fileName ?? "Audio"))
                    .font(.callout.weight(.medium))
                if message.durationMs > 0 {
                    Text(durationLabel(ms: message.durationMs))
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
        }
        .foregroundStyle(message.isOutgoing ? .white : .primary)
    }

    private func durationLabel(ms: UInt32) -> String {
        let seconds = Int(ms) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Delivery ticks for outgoing messages: clock = pending, one tick =
/// delivered, two ticks = read, red mark = failed.
struct DeliveryStateView: View {
    let state: MessageState

    var body: some View {
        switch state {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
        case .delivered:
            Text("✓")
                .font(.caption2.weight(.semibold))
        case .read:
            Text("✓✓")
                .font(.caption2.weight(.semibold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .noState:
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview("Bubbles") {
    let now = Int64(Date().timeIntervalSince1970)
    let model = AppModel(service: MockChatService())
    return ScrollView {
        LazyVStack(spacing: 6) {
            DayMarkerView(label: "Today")
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 1, chatId: 1, text: "You added member Carol.", timestamp: now - 4000,
                    isOutgoing: false, isInfo: true, senderName: "", senderColor: "#999999",
                    state: .noState),
                showAuthor: false)
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 2, chatId: 1, text: "Hey! Did you see the native prototype?",
                    timestamp: now - 3600, isOutgoing: false, isInfo: false,
                    senderName: "Alice", senderColor: "#e56555", state: .noState,
                    reactions: [ReactionItem(
                        emoji: "👍", count: 2, isFromSelf: true,
                        reactors: [
                            ReactionContact(name: "Me", color: "#2f9e44", avatarPath: nil),
                            ReactionContact(name: "Elena", color: "#e56555", avatarPath: nil),
                        ])]),
                showAuthor: true)
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 3, chatId: 1, text: "Yes! SwiftUI over a Rust core.",
                    timestamp: now - 3500, isOutgoing: true, isInfo: false,
                    senderName: "Me", senderColor: "#2f9e44", state: .read,
                    quote: QuoteInfo(
                        text: "Hey! Did you see the native prototype?",
                        senderName: "Alice", senderColor: "#e56555")),
                showAuthor: false)
            MessageBubbleView(
                model: model,
                message: MessageItem(
                    id: 4, chatId: 1, text: "", timestamp: now - 60,
                    isOutgoing: false, isInfo: false,
                    senderName: "Alice", senderColor: "#e56555", state: .noState,
                    kind: .file, file: "/tmp/nonexistent.pdf",
                    fileName: "report.pdf", fileSize: 48_213),
                showAuthor: false)
        }
        .padding(16)
    }
    .frame(width: 420, height: 480)
}
