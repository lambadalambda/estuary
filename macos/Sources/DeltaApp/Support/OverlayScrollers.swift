import AppKit
import SwiftUI

/// Forces macOS overlay scrollers (appear while scrolling, then fade) even
/// when the system preference is "Always show scroll bars" — the persistent
/// track reads as intrusive on the tiled chat surface. SwiftUI offers only
/// show/hide, not the style, hence AppKit.
///
/// apply() sweeps EVERY scroll view under the anchor's window. Targeting
/// "the one nearest scroll view" proved fragile: SwiftUI's platform
/// hierarchy gives no locality guarantees (a List's scroll view is a
/// sibling of a `.background` anchor, not an ancestor), so a mis-timed
/// first-match lookup could style the wrong pane, report success, and never
/// retry. The sweep is idempotent, and a call that races platform-view
/// insertion is harmless — a later trigger from any anchor catches up.
/// Attach near a scroll surface: `.background(OverlayScrollers())`.
struct OverlayScrollers: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Applies when actually inserted into the hierarchy: a one-shot
    /// deferred apply from makeNSView races view insertion (the window's
    /// scroll views may not exist yet) — one of two same-binary instances
    /// showed the legacy bar, the other didn't.
    final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                OverlayScrollers.apply(from: self)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        // Belt and braces alongside viewDidMoveToWindow: AppKit may still
        // stamp the preferred style onto the scroll view during window
        // setup, after our first apply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
            guard let view else { return }
            Self.apply(from: view)
        }
        // AppKit reverts the style when the preferred style changes at
        // runtime (System Settings, plugging in a mouse) — with no SwiftUI
        // update to piggyback on, so listen for it explicitly.
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil, queue: .main
        ) { [weak view] _ in
            DispatchQueue.main.async {
                guard let view else { return }
                Self.apply(from: view)
            }
        }
        return view
    }

    // No re-apply here on purpose: updateNSView runs on every SwiftUI
    // update (every composer keystroke), and the sweep walks the whole
    // window. Insertion, the delayed retry, and the style-change observer
    // already cover every event that can revert the style.
    func updateNSView(_ view: NSView, context: Context) {}

    static func apply(from view: NSView) {
        var root = view
        while let parent = root.superview { root = parent }
        // Window content view when attached; the detached ancestor tree
        // otherwise (unit tests, mid-teardown calls).
        styleScrollViews(under: view.window?.contentView ?? root)
    }

    private static func styleScrollViews(under root: NSView) {
        var queue: [NSView] = [root]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            if let scrollView = current as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
            queue.append(contentsOf: current.subviews)
        }
    }
}
