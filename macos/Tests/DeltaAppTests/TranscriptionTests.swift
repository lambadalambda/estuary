import Testing

@testable import DeltaApp

/// Transcript state machine for the voice-message Transcribe flow
/// (issue: stt-ffi-ui).
@Suite struct TranscriptionTests {
    @Test func unrequestedAndFinishedStatesAllowOrBlockStart() {
        #expect(transcriptionCanStart(nil))
        #expect(transcriptionCanStart(.failed("boom")))
        #expect(!transcriptionCanStart(.working(phase: .transcribing, permille: 0)))
        #expect(!transcriptionCanStart(.done("text")))
    }

    @Test func progressAdvancesOnlyInFlightRequests() {
        // In flight: phase/permille move.
        let moved = applyTranscriptionProgress(
            .working(phase: .downloadingModel, permille: 10),
            phase: .downloadingModel, permille: 500)
        #expect(moved == .working(phase: .downloadingModel, permille: 500))

        // Phase transition download -> transcribe.
        let phased = applyTranscriptionProgress(
            .working(phase: .downloadingModel, permille: 1000),
            phase: .transcribing, permille: 0)
        #expect(phased == .working(phase: .transcribing, permille: 0))
    }

    @Test func lateEventsNeverDowngradeOrResurrect() {
        // Never requested in this visit: event ignored.
        #expect(applyTranscriptionProgress(nil, phase: .transcribing, permille: 0) == nil)
        // Finished: a stale event must not clobber the transcript.
        let done = TranscriptState.done("hello")
        #expect(applyTranscriptionProgress(done, phase: .transcribing, permille: 0) == done)
        // Failed: no run is in flight; progress would lie.
        let failed = TranscriptState.failed("no network")
        #expect(applyTranscriptionProgress(failed, phase: .downloadingModel, permille: 5) == failed)
    }

    @Test func loadingModelPhaseFlowsThroughWorkingState() {
        let moved = applyTranscriptionProgress(
            .working(phase: .downloadingModel, permille: 1000),
            phase: .loadingModel, permille: 0)
        #expect(moved == .working(phase: .loadingModel, permille: 0))
    }

    @Test func probedDurationsRejectGarbageAndClamp() {
        #expect(durationMs(fromSeconds: 1.234) == 1234)
        #expect(durationMs(fromSeconds: 0) == nil)
        #expect(durationMs(fromSeconds: -3) == nil)
        #expect(durationMs(fromSeconds: .nan) == nil)
        #expect(durationMs(fromSeconds: .infinity) == nil)
        #expect(durationMs(fromSeconds: 1e12) == UInt32.max)
        // A corrupt container can decode to CMTime seconds near 9.2e18;
        // conversion must clamp, not trap, while merely rendering a bubble.
        #expect(durationMs(fromSeconds: 9.2e18) == UInt32.max)
    }

    @Test func coreDurationStaysAuthoritative() {
        #expect(effectiveDurationMs(core: 5000, probed: 9000) == 5000)
        #expect(effectiveDurationMs(core: 0, probed: 9000) == 9000)
        #expect(effectiveDurationMs(core: 0, probed: 0) == nil)
        #expect(effectiveDurationMs(core: 0, probed: nil) == nil)
    }

    @Test func heightClassSeparatesHeightsNotTicks() {
        let a = TranscriptState.working(phase: .downloadingModel, permille: 1)
        let b = TranscriptState.working(phase: .transcribing, permille: 999)
        #expect(a.heightClass == b.heightClass)
        #expect(TranscriptState.done("x").heightClass != a.heightClass)
        #expect(TranscriptState.failed("x").heightClass != TranscriptState.done("x").heightClass)
    }
}
