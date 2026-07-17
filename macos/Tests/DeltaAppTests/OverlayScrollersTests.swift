import AppKit
import Testing
@testable import DeltaApp

// OverlayScrollers must restyle the enclosing scroll view in two hierarchy
// shapes: the anchor living INSIDE the scroll view (ScrollView content
// background, the message list) and the anchor as a SIBLING behind it
// (.background on a List, whose NSScrollView is not an ancestor).

@Suite @MainActor struct OverlayScrollersTests {
    private func legacyScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        return scrollView
    }

    @Test func appliesWhenAnchorIsInsideTheScrollView() {
        let scrollView = legacyScrollView()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scrollView.documentView = document
        let anchor = NSView()
        document.addSubview(anchor)

        OverlayScrollers.apply(from: anchor)

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
    }

    @Test func appliesWhenScrollViewIsASiblingSubtree() {
        // .background(OverlayScrollers()) on a List: container holds the
        // anchor and, next to it, the platform subtree containing the
        // NSScrollView.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let anchor = NSView()
        container.addSubview(anchor)
        let wrapper = NSView(frame: container.bounds)
        let scrollView = legacyScrollView()
        wrapper.addSubview(scrollView)
        container.addSubview(wrapper)

        OverlayScrollers.apply(from: anchor)

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
    }

    @Test func stylesEveryScrollViewInTheTree() {
        // "First match wins" proved fragile (no locality guarantees in
        // SwiftUI's platform hierarchy): apply must sweep ALL scroll views
        // so a mis-timed call can never style the wrong one and stop.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let sidebar = legacyScrollView()
        let detailWrapper = NSView(frame: container.bounds)
        let detail = legacyScrollView()
        detailWrapper.addSubview(detail)
        let anchor = NSView()
        container.addSubview(sidebar)
        container.addSubview(detailWrapper)
        container.addSubview(anchor)

        OverlayScrollers.apply(from: anchor)

        #expect(sidebar.scrollerStyle == .overlay)
        #expect(detail.scrollerStyle == .overlay)
        #expect(sidebar.autohidesScrollers && detail.autohidesScrollers)
    }

    @Test func repinsWhenAppKitRevertsTheStyle() {
        // AppKit re-stamps the preferred (legacy) style when it re-tiles a
        // scroll view (e.g. List selection change). The pin must correct a
        // revert synchronously, before it can draw a legacy bar.
        let scrollView = legacyScrollView()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scrollView.documentView = document
        let anchor = NSView()
        document.addSubview(anchor)
        OverlayScrollers.apply(from: anchor)
        #expect(scrollView.scrollerStyle == .overlay)

        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.autohidesScrollers)
    }

    @Test func doesNothingWithoutAScrollView() {
        let container = NSView()
        let anchor = NSView()
        container.addSubview(anchor)
        // Must not crash or loop; nothing to assert beyond returning.
        OverlayScrollers.apply(from: anchor)
    }
}
