import AppKit
import SwiftUI
import Testing

@testable import DeltaApp

/// Long-message display rules + the row-height measurement primitive
/// (issue: long-message-height-and-collapse).
@Suite struct LongMessageTests {
    @Test func shortTextIsNeverCut() {
        let display = longMessageDisplay("hello world", expanded: false)
        #expect(display == LongMessageDisplay(
            shown: "hello world", isExpandable: false, isTruncated: false))
    }

    @Test func textAtThresholdIsNotCut() {
        let text = String(repeating: "a", count: longMessageThreshold)
        let display = longMessageDisplay(text, expanded: false)
        #expect(!display.isExpandable)
        #expect(display.shown == text)
    }

    @Test func hugeTextCollapsesWithEllipsisAndFlag() {
        let text = String(repeating: "word ", count: 2000)  // 10k chars
        let display = longMessageDisplay(text, expanded: false)
        #expect(display.isExpandable)
        #expect(display.isTruncated)
        #expect(display.shown.count < longMessageThreshold + 2)
        #expect(display.shown.hasSuffix("…"))
    }

    @Test func collapseCutsAtWhitespaceBoundary() {
        // No mid-word cut: the character before the ellipsis must not be
        // part of a broken word when a boundary exists nearby.
        let text = String(repeating: "word ", count: 2000)
        let display = longMessageDisplay(text, expanded: false)
        let beforeEllipsis = display.shown.dropLast(1).last
        #expect(beforeEllipsis == "d")  // full "word", trailing space trimmed
    }

    @Test func expandedHugeTextShowsEverythingWithShowLess() {
        let text = String(repeating: "word ", count: 2000)
        let display = longMessageDisplay(text, expanded: true)
        #expect(display.shown == text)
        #expect(display.isExpandable)
        #expect(!display.isTruncated)
    }

    @Test func hardCutWhenNoWhitespaceNearBoundary() {
        let text = String(repeating: "x", count: longMessageThreshold + 500)
        let display = longMessageDisplay(text, expanded: false)
        #expect(display.isTruncated)
        #expect(display.shown.count == longMessageThreshold + 1)  // + ellipsis
    }

    @Test func hardCutInsideUrlDropsThePartialLink() {
        // A URL longer than the boundary window straddling the threshold:
        // the collapsed view must not offer a clickable truncated URL.
        let text = String(repeating: "word ", count: 980)
            + "https://example.com/" + String(repeating: "x", count: 1000)
        let display = longMessageDisplay(text, expanded: false)
        #expect(display.isTruncated)
        #expect(!display.shown.contains("https://"))
    }

    @Test func multiByteTextBelowThresholdIsNotCut() {
        // 3000 emoji: 12k utf8 bytes but only 3000 characters — the utf8
        // fast path must not misclassify it as expandable.
        let text = String(repeating: "😀", count: 3000)
        let display = longMessageDisplay(text, expanded: false)
        #expect(!display.isExpandable)
        #expect(display.shown == text)
    }

    /// Regression for the one-line bubble bug: the sizing primitive must
    /// return height-at-width for wrapping Text, not its single-line
    /// ideal size (NSHostingView.fittingSize did the latter).
    @MainActor @Test func plainTextMeasuresMultiLineHeight() {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let long = String(repeating: "wrap this text nicely ", count: 20)
        let single = host.fittingHeight(of: Text("one line"), forWidth: 240)
        let tall = host.fittingHeight(of: Text(long), forWidth: 240)
        #expect(single > 0)
        #expect(tall > single * 3)
    }

    /// Regression for the giant-bubble bug the first fix introduced:
    /// greedy views (the quote accent bar) expand to any proposed height,
    /// so the measurement must pin content to its ideal height at the
    /// width — not propose unbounded space.
    @MainActor @Test func greedyDecorationsDoNotInflateMeasuredHeight() {
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let quoteLike = HStack {
            RoundedRectangle(cornerRadius: 1.5).frame(width: 3)
            Text("quoted line")
        }
        let height = host.fittingHeight(of: quoteLike, forWidth: 240)
        #expect(height > 0)
        #expect(height < 100)
    }
}
