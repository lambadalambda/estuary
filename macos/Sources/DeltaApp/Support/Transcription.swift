import Foundation

/// Per-message transcription lifecycle (issue: stt-ffi-ui). Pure state +
/// reducer so the transitions are unit-testable without the service.
enum TranscriptState: Equatable, Sendable {
    case working(phase: TranscriptionPhase, permille: UInt32)
    case done(String)
    case failed(String)

    /// Row-height cache discriminator: states that can render at different
    /// heights must differ; permille ticks must not (same height).
    var heightClass: String {
        switch self {
        case .working: "working"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

/// Whether tapping Transcribe should start a request in this state.
/// (`nil` = never asked; `.failed` = retry.)
func transcriptionCanStart(_ state: TranscriptState?) -> Bool {
    switch state {
    case nil, .failed: true
    case .working, .done: false
    }
}

/// Folds a `.transcriptionProgress` event into existing state. Only an
/// in-flight request moves: an unrequested message (`nil`, e.g. events for
/// a request started from a previous chat visit) stays untouched, and a
/// finished or failed transcript is never downgraded by a late event.
func applyTranscriptionProgress(
    _ state: TranscriptState?, phase: TranscriptionPhase, permille: UInt32
) -> TranscriptState? {
    guard case .working = state else { return state }
    return .working(phase: phase, permille: permille)
}
