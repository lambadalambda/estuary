# STT: transcription FFI + Swift UI

## Summary

Expose transcription over the FFI and add the Transcribe button, progress, and
transcript display to voice/audio bubbles in the macOS shell.

## Requirements

- FFI: `DcApp::transcribe_message(account_id, msg_id) -> Result<String>`.
  Handles model download on first use; emits progress via a new
  `VmEvent::TranscriptionProgress { message_id, phase, permille }` (phases:
  downloading model, transcribing). Session-level transcript cache in dcvm
  keyed by (account, msg) so repeat calls are instant.
- `make bindings` after the exported-API change; update ChatService protocol,
  CoreChatService, and MockChatService together (checksum-mismatch rule).
- MockChatService: add a voice-message fixture and a mock transcribe (short
  delay, canned text) so `DCNATIVE_MOCK=1` exercises the flow.
- Swift: Transcribe button in `AudioMessageView`; transcript shown under the
  player. Per-message state in AppModel
  (`idle / working(progress) / done(text) / failed(message)`), cleared on chat
  switch like `expandedMessageIds`. Row height re-measured when a transcript
  appears (same invalidation mechanism as expand/collapse).
- Any `await` completion re-validates selection/account before writing UI
  state (stale-await rule).

## Acceptance Criteria

- Rust: offline vm.rs test — transcribe_message with a fake engine on a
  fixture voice message returns text, second call hits the cache, and an
  unsupported-codec blob surfaces a typed, user-explainable error.
- Swift: unit tests for the transcript state reducer + context/height
  invalidation analog; MockShowcase shows a voice bubble with working
  Transcribe flow.
- Real app: button on a received voice message produces a transcript; failure
  cases (no network on first download, ogg-opus blob) show a readable error,
  not a crash.

## Verification status (2026-07-26)

Implemented and mostly verified; kept open for two remaining real-app checks:

- DONE: Rust offline tests (fake engine: transcribe/cache/typed errors/event),
  Swift TranscriptState reducer tests, MockShowcase voice fixture + mock
  transcribe test, 166 Swift tests green.
- DONE (e2e, lume VM `cua-driver-dev-26.5.2`): real app + real core + real
  Parakeet Q8_0 transcribed jfk.wav; transcript rendered in the audio bubble
  (screenshot verified via cua-driver). Model was pre-planted in
  `<data_dir>/stt-models/`.
- CLOSED 2026-07-26: user exercised the full real-account flow — first-use
  model download with visible progress and Transcribe on received voice
  messages — and confirmed it works (and, after the warmup/phase fixes,
  that it is fast).

## Notes

- Review carry-over from stt-engine-parakeet: `ParakeetEngine::load` (~700 MB
  map) and `transcribe()` (native inference holding the model's compute lock)
  are hard-blocking — route through `spawn_blocking` on the dcvm runtime, and
  serialize transcriptions (concurrent calls queue on the crate's internal
  mutex, pinning one blocking thread each).
- Model download progress fires per network chunk — throttle (e.g. ≥1
  permille delta) before crossing the FFI.

- Button visibility: show for kinds Voice and Audio; disable with a tooltip
  when the extension is `.ogg`/`.oga` and decode reports unsupported codec —
  only after the first failed attempt (we can't know the codec without
  opening the container).
