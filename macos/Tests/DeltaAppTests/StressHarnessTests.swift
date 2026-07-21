import Foundation
import Testing

@testable import DeltaApp

// Pure parts of the list-engine stress harness (issue:
// message-list-engine-spike): the synthetic corpus must be deterministic
// (comparable runs across containers) and varied (realistic bubble
// heights); the sweep statistics must count hitches correctly.

@Suite struct StressHarnessTests {
    @Test func corpusIsDeterministicAndVaried() {
        let a = stressMessages(count: 300)
        let b = stressMessages(count: 300)
        #expect(a == b, "same corpus every run — containers must see identical input")
        #expect(a.count == 300)
        #expect(a.map(\.id) == a.map(\.id).sorted(), "ids ascend like history")

        let texts = a.map(\.text)
        #expect(texts.contains { $0.count > 200 }, "long bubbles present")
        #expect(texts.contains { $0.count < 30 }, "short bubbles present")
        #expect(texts.contains { $0.contains("https://") }, "link bubbles present")
        #expect(a.contains { $0.isOutgoing } && a.contains { !$0.isOutgoing })
        // Timestamps spread far enough that day markers appear in entries.
        let entries = buildMessageListEntries(a, inGroup: true)
        #expect(entries.contains {
            if case .dayMarker = $0 { return true } else { return false }
        })
    }

    @Test func sweepStatsCountsHitches() {
        // Gaps: 10ms, 40ms, 12ms, 138ms → two above a 34ms threshold.
        let stats = sweepStats(
            timestamps: [0, 0.010, 0.050, 0.062, 0.200], hitchThresholdMs: 34)
        #expect(stats.samples == 5)
        #expect(stats.hitches == 2)
        #expect(Int(stats.maxGapMs.rounded()) == 138)
        #expect(Int(stats.totalMs.rounded()) == 200)
    }

    @Test func sweepStatsHandlesDegenerateInput() {
        #expect(sweepStats(timestamps: [], hitchThresholdMs: 34).samples == 0)
        #expect(sweepStats(timestamps: [1.0], hitchThresholdMs: 34).hitches == 0)
    }
}
