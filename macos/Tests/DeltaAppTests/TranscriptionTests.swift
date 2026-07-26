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

    @Test func heightClassSeparatesHeightsNotTicks() {
        let a = TranscriptState.working(phase: .downloadingModel, permille: 1)
        let b = TranscriptState.working(phase: .transcribing, permille: 999)
        #expect(a.heightClass == b.heightClass)
        #expect(TranscriptState.done("x").heightClass != a.heightClass)
        #expect(TranscriptState.failed("x").heightClass != TranscriptState.done("x").heightClass)
    }
}
