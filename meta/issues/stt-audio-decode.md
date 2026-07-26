# STT: audio decode to 16 kHz mono PCM in dcvm

## Summary

Pure Rust decode step for the transcription pipeline: given a blobdir audio
path (m4a/aac/mp3/ogg-vorbis/wav), produce mono f32 PCM in [-1, 1] at 16 kHz —
the input format transcribe.cpp requires.

## Requirements

- New module `dcvm/src/stt/decode.rs` (or similar): symphonia-based decode,
  channel downmix (mean), resample to 16 kHz (rubato).
- Errors are typed and human-explainable: missing file, unsupported
  container/codec (notably Opus-in-Ogg), corrupt stream.
- No FFI surface yet; internal function only.

## Acceptance Criteria

- Unit/integration tests with small checked-in fixtures (wav generated
  in-test; m4a/mp3 fixtures ~seconds long, created via `afconvert`/ffmpeg once
  and committed) proving: 48 kHz stereo wav → 16 kHz mono of expected length
  and bounded amplitude; m4a decodes; unsupported codec yields the typed error.
- `cargo test` stays offline and green.

## Notes

- Check `git diff Cargo.lock` after adding symphonia/rubato (lockfile pins are
  load-bearing; never bare `cargo update`).
