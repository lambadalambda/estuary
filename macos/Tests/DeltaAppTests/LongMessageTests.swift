import AppKit
import SwiftUI
import Testing

@testable import DeltaApp

/// Row-height measurement primitive regression tests
/// (issue: long-message-height-and-collapse).
@Suite struct LongMessageTests {
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
