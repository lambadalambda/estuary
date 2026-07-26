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

/// Milliseconds from an AVFoundation seconds value; NaN/negative/infinite
/// (live streams, corrupt files) mean unknown.
func durationMs(fromSeconds seconds: Double) -> UInt32? {
    guard seconds.isFinite, seconds > 0 else { return nil }
    // Compare in Double before converting: Double → Int64 TRAPS (doesn't
    // clamp) past Int64.max, and corrupt containers can decode there.
    guard seconds < Double(UInt32.max) / 1000 else { return UInt32.max }
    return UInt32(clamping: Int64((seconds * 1000).rounded()))
}

/// Which duration an audio bubble shows: core's value (Chat-Duration header)
/// is authoritative when nonzero; otherwise a shell-side probe fills in.
func effectiveDurationMs(core: UInt32, probed: UInt32?) -> UInt32? {
    if core > 0 { return core }
    if let probed, probed > 0 { return probed }
    return nil
}
