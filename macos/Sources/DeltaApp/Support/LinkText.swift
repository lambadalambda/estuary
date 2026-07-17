import AppKit
import SwiftUI

/// AppKit-backed text for link-bearing messages: native pointing-hand cursor
/// over link ranges (SwiftUI's `pointerStyle` loses to the text-selection
/// pointer), native link clicks, and text selection. Plain messages keep
/// using SwiftUI `Text` — this exists only where links demand it.
struct LinkText: NSViewRepresentable {
    let text: String
    let textColor: NSColor
    let linkColor: NSColor

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        // Attribute-level styling wins; keep NSTextView's own link styling
        // from overriding the colors we set per-range.
        view.linkTextAttributes = [:]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        view.textStorage?.setAttributedString(nsLinkified(
            text,
            font: .preferredFont(forTextStyle: .body),
            textColor: textColor,
            linkColor: linkColor))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSTextView, context: Context
    ) -> CGSize? {
        guard let container = nsView.textContainer,
              let manager = nsView.layoutManager
        else { return nil }
        let width = proposal.width ?? 480
        container.containerSize = NSSize(
            width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        // Hug short lines (bubble width follows the text) but never exceed
        // the proposal.
        return CGSize(
            width: min(used.width.rounded(.up) + 1, width),
            height: used.height.rounded(.up))
    }
}
