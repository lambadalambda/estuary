import Testing
@testable import DeltaApp

// Regression: selecting or posting in a chat whose loaded window fit the
// viewport flung the view to the top — the history-prepend anchor restore
// ran even while the viewport was pinned at the bottom, where
// .defaultScrollAnchor(.bottom, for: .sizeChanges) already handles growth.

@Suite struct HistoryRestoreTests {
    @Test func noRestoreAnchorWhilePinnedAtBottom() {
        #expect(
            AppModel.historyRestoreAnchor(previousOldest: 42, viewIsAtBottom: true) == nil)
    }

    @Test func restoreAnchorPreservesScrolledUpPosition() {
        #expect(
            AppModel.historyRestoreAnchor(previousOldest: 42, viewIsAtBottom: false) == 42)
    }
}
