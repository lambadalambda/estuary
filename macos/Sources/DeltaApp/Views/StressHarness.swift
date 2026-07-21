import AppKit
import SwiftUI

// List-engine stress harness (issue: message-list-engine-spike).
// Dev/mock-only, behind DCNATIVE_STRESS; renders the SAME entry array and
// real MessageBubbleView rows in a selectable container, runs a scripted
// scroll sweep, and prints cadence stats. Spike-quality by design: the
// table variant here is a minimal probe, not the production port.

enum StressContainer: String {
    case eager, lazy, list, table
}

struct StressConfig {
    let count: Int
    let container: StressContainer

    static func fromEnv() -> StressConfig? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["DCNATIVE_STRESS"], let count = Int(raw), count > 0
        else { return nil }
        let container = env["DCNATIVE_STRESS_CONTAINER"]
            .flatMap(StressContainer.init(rawValue:)) ?? .eager
        return StressConfig(count: count, container: container)
    }
}

/// Deterministic synthetic history: mixed bubble heights, links, sender
/// runs, and multi-day timestamps — identical across runs so container
/// numbers are comparable.
func stressMessages(count: Int) -> [MessageItem] {
    let lorem = "The tide tables said slack water at nine, but the channel "
        + "was still running hard past the pilings when we shoved off, and "
        + "by the time the fog burned through we had drifted well past the "
        + "green can and had to claw back against the ebb the whole way. "
    let senders: [(String, String)] = [
        ("Elena", "#c74440"), ("Marco", "#4477c7"), ("Priya", "#8844c7"),
    ]
    return (1 ... count).map { i in
        let text: String
        switch i % 11 {
        case 0: text = lorem + lorem + "(#\(i))"
        case 3: text = "long one #\(i): " + lorem
        case 7: text = "notes for #\(i): https://example.org/trip/\(i)"
        default: text = "msg #\(i)"
        }
        let outgoing = (i / 4) % 3 == 0
        let sender = senders[i % senders.count]
        return MessageItem(
            id: UInt32(i), chatId: 999, text: text,
            // ~40 minutes apart: several day markers per few hundred msgs.
            timestamp: 1_750_000_000 + Int64(i) * 2400,
            isOutgoing: outgoing, isInfo: false,
            senderName: outgoing ? "Me" : sender.0,
            senderColor: outgoing ? "#123456" : sender.1,
            senderAvatar: nil, state: .delivered)
    }
}

struct SweepStats {
    let samples: Int
    let hitches: Int
    let maxGapMs: Double
    let totalMs: Double
}

/// Gap analysis over scroll-callback timestamps: a gap above the threshold
/// is a hitch (missed-frame territory at ~34ms on a 60Hz display).
func sweepStats(timestamps: [TimeInterval], hitchThresholdMs: Double) -> SweepStats {
    guard let first = timestamps.first, let last = timestamps.last,
          timestamps.count > 1
    else {
        return SweepStats(
            samples: timestamps.count, hitches: 0, maxGapMs: 0, totalMs: 0)
    }
    let gaps = zip(timestamps.dropFirst(), timestamps).map { ($0 - $1) * 1000 }
    return SweepStats(
        samples: timestamps.count,
        hitches: gaps.filter { $0 > hitchThresholdMs }.count,
        maxGapMs: gaps.max() ?? 0,
        totalMs: (last - first) * 1000)
}

/// Collects scroll-callback timestamps during the sweep and prints the
/// verdict line the spike table is built from.
@MainActor
final class SweepCollector {
    private var timestamps: [TimeInterval] = []
    private var sweeping = false

    func record() {
        if sweeping { timestamps.append(ProcessInfo.processInfo.systemUptime) }
    }

    func beginSweep() {
        timestamps.removeAll()
        sweeping = true
    }

    func finish(container: StressContainer, count: Int) {
        sweeping = false
        let stats = sweepStats(timestamps: timestamps, hitchThresholdMs: 34)
        print(
            "[stress] container=\(container.rawValue) n=\(count) "
                + "samples=\(stats.samples) hitches=\(stats.hitches) "
                + "maxGapMs=\(Int(stats.maxGapMs.rounded())) "
                + "sweepMs=\(Int(stats.totalMs.rounded()))")
        exit(0)
    }
}

struct StressHarnessView: View {
    let config: StressConfig
    let model: AppModel
    private let entries: [MessageListEntry]
    private let collector = SweepCollector()

    init(config: StressConfig, model: AppModel) {
        self.config = config
        self.model = model
        self.entries = buildMessageListEntries(
            stressMessages(count: config.count), inGroup: true)
    }

    var body: some View {
        Group {
            switch config.container {
            case .eager:
                sweptScrollView { VStack(spacing: 6) { rows } }
            case .lazy:
                sweptScrollView { LazyVStack(spacing: 6) { rows } }
            case .list:
                ScrollViewReader { proxy in
                    List(entries) { entry in
                        row(entry)
                            .listRowSeparator(.hidden)
                            .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onScrollGeometryChange(for: CGFloat.self) {
                        $0.contentOffset.y
                    } action: { _, _ in collector.record() }
                    .task { await sweep(proxy) }
                }
            case .table:
                StressTableView(entries: entries, model: model, collector: collector) {
                    collector.finish(container: config.container, count: config.count)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 600)
    }

    private func sweptScrollView<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
                    .padding(.horizontal, 16)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: CGFloat.self) {
                $0.contentOffset.y
            } action: { _, _ in collector.record() }
            .task { await sweep(proxy) }
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(entries) { entry in
            row(entry).id(entry.id)
        }
    }

    @ViewBuilder private func row(_ entry: MessageListEntry) -> some View {
        switch entry {
        case .dayMarker(_, let label):
            DayMarkerView(label: label)
        case .message(let message, let showAuthor):
            MessageBubbleView(
                model: model, message: message, showAuthor: showAuthor,
                inGroup: true)
        }
    }

    /// Bottom → top → bottom in fixed strides; identical for every SwiftUI
    /// container. Step pacing is constant, so slower containers show up as
    /// hitches and a longer wall-clock sweep, not fewer steps.
    private func sweep(_ proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .seconds(3))
        collector.beginSweep()
        let ids = entries.map(\.id)
        let stride = 8
        for index in Swift.stride(from: ids.count - 1, through: 0, by: -stride) {
            withAnimation(.linear(duration: 0.08)) {
                proxy.scrollTo(ids[index], anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for index in Swift.stride(from: 0, to: ids.count, by: stride) {
            withAnimation(.linear(duration: 0.08)) {
                proxy.scrollTo(ids[index], anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        collector.finish(container: config.container, count: config.count)
    }
}

// MARK: - Minimal NSTableView candidate

/// Spike probe: NSTableView with recycled NSHostingView rows, automatic
/// row heights, bottom-anchored on load, swept via scrollRowToVisible.
private struct StressTableView: NSViewRepresentable {
    let entries: [MessageListEntry]
    let model: AppModel
    let collector: SweepCollector
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(entries: entries, model: model, collector: collector, onDone: onDone)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.usesAutomaticRowHeights = true
        let column = NSTableColumn(identifier: .init("bubble"))
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main
        ) { [collector] _ in
            MainActor.assumeIsolated { collector.record() }
        }
        context.coordinator.startSweep(table: table)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let entries: [MessageListEntry]
        let model: AppModel
        let collector: SweepCollector
        let onDone: () -> Void

        init(
            entries: [MessageListEntry], model: AppModel,
            collector: SweepCollector, onDone: @escaping () -> Void
        ) {
            self.entries = entries
            self.model = model
            self.collector = collector
            self.onDone = onDone
        }

        nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
            MainActor.assumeIsolated { entries.count }
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("bubble-cell")
            let entry = entries[row]
            let content = AnyView(rowView(entry))
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? NSHostingView<AnyView> {
                reused.rootView = content
                return reused
            }
            let hosting = NSHostingView(rootView: content)
            hosting.identifier = identifier
            return hosting
        }

        @ViewBuilder private func rowView(_ entry: MessageListEntry) -> some View {
            switch entry {
            case .dayMarker(_, let label):
                DayMarkerView(label: label).frame(maxWidth: .infinity)
            case .message(let message, let showAuthor):
                MessageBubbleView(
                    model: model, message: message, showAuthor: showAuthor,
                    inGroup: true)
                .padding(.horizontal, 16)
            }
        }

        func startSweep(table: NSTableView) {
            let count = entries.count
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                table.scrollRowToVisible(count - 1)
                collector.beginSweep()
                let stride = 8
                for row in Swift.stride(from: count - 1, through: 0, by: -stride) {
                    table.scrollRowToVisible(row)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                for row in Swift.stride(from: 0, to: count, by: stride) {
                    table.scrollRowToVisible(row)
                    try? await Task.sleep(for: .milliseconds(100))
                }
                onDone()
            }
        }
    }
}
