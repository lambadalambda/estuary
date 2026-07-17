import AppKit
import SwiftUI

/// Forces macOS overlay scrollers (appear while scrolling, then fade) on the
/// enclosing scroll view, even when the system preference is "Always show
/// scroll bars" — the persistent track reads as intrusive on the tiled chat
/// surface. SwiftUI offers only show/hide, not the style, hence AppKit.
/// Attach inside the ScrollView's content: `.background(OverlayScrollers())`.
struct OverlayScrollers: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Applies when actually inserted into the hierarchy: a one-shot
    /// deferred apply from makeNSView races view insertion (walk finds no
    /// scroll view yet) — one of two same-binary instances showed the
    /// legacy bar, the other didn't.
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

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(from: view) }
    }

    fileprivate static func apply(from view: NSView) {
        var candidate: NSView? = view.superview
        while let current = candidate, !(current is NSScrollView) {
            candidate = current.superview
        }
        guard let scrollView = candidate as? NSScrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }
}
