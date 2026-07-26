# Voice message transcription (on-demand)

## Summary

Add a "Transcribe" affordance to voice/audio message bubbles that produces an
on-device transcript of the recording. Engine: transcribe.cpp (GGML, Metal)
running NVIDIA Parakeet TDT 0.6B v3 (25 European languages, auto language
detection). All logic lives in dcvm below the FFI; the Swift shell only renders
the button, progress, and transcript.

## Decision record

Two candidate engines were evaluated (2026-07-26):

- **macOS 26 `SpeechAnalyzer`/`SpeechTranscriber`** — zero app bloat (OS-managed
  models), but macOS 26+ only, narrower locale coverage, and the engine would
  live shell-side.
- **transcribe.cpp + Parakeet v3** (chosen) — MIT, official Rust bindings on
  crates.io (`transcribe-cpp` 0.2.0, builds C++ via CMake in build.rs, Metal
  default on Apple). 25 European languages with auto-detect, leaderboard-best
  WER. Costs we accept: dcvm owns a ~600 MB GGUF model download and audio
  decoding to 16 kHz mono f32 PCM.

Chosen for language coverage and to keep client logic below the FFI
(reusable by future non-mac shells).

## Subissues

- [Audio decode to 16 kHz mono PCM in dcvm](stt-audio-decode.md)
- [transcribe.cpp engine + model management](stt-engine-parakeet.md)
- [Transcription FFI + Swift UI](stt-ffi-ui.md)

## Acceptance Criteria

- All three subissues archived.
- End to end on a real account: tapping Transcribe on a received voice message
  downloads the model (with visible progress) on first use, then shows a
  transcript under the audio player; subsequent transcriptions are fast and
  offline.

## Notes

- Transcripts are session-cached only in v1 (no persistence), mirroring the
  expand/collapse per-visit state pattern in AppModel.
- `.ogg`/`.oga` may contain Opus, which symphonia cannot decode; those get a
  clear "unsupported audio codec" error rather than silent failure. Core never
  classifies `.opus` files as Voice/Audio (they become File), so the realistic
  voice payloads are m4a/aac/mp3/wav.
