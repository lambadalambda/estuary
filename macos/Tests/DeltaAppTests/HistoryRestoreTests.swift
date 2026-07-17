import Testing
@testable import DeltaApp

// Regressions around prepending history while the viewport is pinned at
// the bottom (huge chats spuriously fire the load-older sentinel during
// initial layout): an unconditional top-anchor restore flung the view to
// the top; merely SKIPPING the restore stranded the viewport in
// unrealized space (blank pane until a manual scroll). The model must
// direct the view: restore a scrolled-up position, or re-pin the bottom.

@Suite struct HistoryRestoreTests {
    @Test func rePinsTheBottomWhenPrependingWhilePinned() {
        #expect(
            AppModel.historyLoadOutcome(previousOldest: 42, viewIsAtBottom: true)
                == .pinBottom)
    }

    @Test func restoresAScrolledUpReadingPosition() {
        #expect(
            AppModel.historyLoadOutcome(previousOldest: 42, viewIsAtBottom: false)
                == .restore(anchor: 42))
    }
}
