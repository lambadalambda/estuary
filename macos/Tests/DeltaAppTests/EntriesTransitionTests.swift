import Foundation
import Testing

@testable import DeltaApp

// The AppKit table's update brain (issue: appkit-message-table-port):
// classify how the entry list changed so the table can insert/remove rows
// surgically instead of reloading — and fall back to .reset (reload +
// anchor restore) whenever the shape is anything but clean.

@Suite struct ChatAtBottomTests {
    // Human at-bottom (issue: at-bottom-wiggle-room): follow when the
    // newest row is at least partly visible; never yank when it is fully
    // below the fold. Viewport is 600pt tall over 2000pt of content.

    @Test func exactBottomIsAtBottom() {
        #expect(chatIsAtBottom(
            viewportMaxY: 2000, contentHeight: 2000, lastRowMinY: 1940))
    }

    @Test func fewPointsShyIsAtBottom() {
        // The trackpad-graze case: 40pt up, newest row clipped but visible.
        #expect(chatIsAtBottom(
            viewportMaxY: 1960, contentHeight: 2000, lastRowMinY: 1940))
    }

    @Test func newestRowPeekingCountsAsAtBottom() {
        // Only the top 5pt of the newest row shows.
        #expect(chatIsAtBottom(
            viewportMaxY: 1945, contentHeight: 2000, lastRowMinY: 1940))
    }

    @Test func newestRowBelowTheFoldIsNotAtBottom() {
        #expect(!chatIsAtBottom(
            viewportMaxY: 1935, contentHeight: 2000, lastRowMinY: 1940))
    }

    @Test func scrolledFarUpIsNotAtBottom() {
        #expect(!chatIsAtBottom(
            viewportMaxY: 800, contentHeight: 2000, lastRowMinY: 1940))
    }

    @Test func emptyOrShortContentIsAtBottom() {
        // Content fits the viewport entirely: always at bottom.
        #expect(chatIsAtBottom(
            viewportMaxY: 600, contentHeight: 400, lastRowMinY: 360))
        #expect(chatIsAtBottom(
            viewportMaxY: 600, contentHeight: 0, lastRowMinY: nil))
    }
}

@Suite struct EntriesTransitionTests {
    private func ids(_ range: ClosedRange<Int>) -> [String] {
        range.map { "msg-\($0)" }
    }

    @Test func identicalIdsAreInPlace() {
        #expect(entriesTransition(from: ids(1 ... 5), to: ids(1 ... 5)) == .inPlace)
    }

    @Test func emptyToEmptyIsNone() {
        #expect(entriesTransition(from: [], to: []) == .none)
    }

    @Test func emptyToContentIsInitial() {
        #expect(entriesTransition(from: [], to: ids(1 ... 5)) == .initial)
    }

    @Test func contentToEmptyIsReset() {
        #expect(entriesTransition(from: ids(1 ... 5), to: []) == .reset)
    }

    @Test func appendIsDetected() {
        #expect(
            entriesTransition(from: ids(1 ... 5), to: ids(1 ... 8))
                == .appended(3))
    }

    @Test func prependIsDetected() {
        #expect(
            entriesTransition(from: ids(4 ... 8), to: ids(1 ... 8))
                == .prepended(3))
    }

    @Test func fullWindowSlideIsDetected() {
        // Window slides: 1...5 → 3...7 (drop 2 at top, append 2 at bottom).
        #expect(
            entriesTransition(from: ids(1 ... 5), to: ids(3 ... 7))
                == .slide(droppedTop: 2, appended: 2))
    }

    @Test func dayMarkerBoundaryChangeDegradesToReset() {
        // A prepend that regenerates the old leading day marker: the old
        // list is NOT a suffix of the new one (its first element vanished).
        let old = ["day-2026-07-18"] + ids(10 ... 12)
        let new = ids(5 ... 9) + ids(10 ... 12)
        #expect(entriesTransition(from: old, to: new) == .reset)
    }

    @Test func disjointIdsAreReset() {
        #expect(
            entriesTransition(from: ids(1 ... 5), to: ids(100 ... 104))
                == .reset)
    }
}
