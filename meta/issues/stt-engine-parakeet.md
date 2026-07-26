# STT: transcribe.cpp engine + model management

## Summary

Integrate the `transcribe-cpp` crate (GGML, Metal) into dcvm behind a small
engine trait, plus download/verify/store the Parakeet TDT 0.6B v3 GGUF model
under `<data_dir>/stt-models/`.

## Requirements

- `trait SttEngine: Send + Sync { fn transcribe(&self, pcm: &[f32]) -> Result<String> }`
  so offline tests can use a fake engine; real impl wraps
  `transcribe_cpp::Model::load(...).session().run(...)`.
- Model manager: knows the pinned HF URL + expected size/checksum for the
  chosen Parakeet v3 GGUF quant; downloads to `<data_dir>/stt-models/` with
  progress reporting (resumable or atomic tmp-rename); loads lazily on first
  transcription and stays loaded for the session.
- Offline test suite never downloads or loads the real model. A real-model
  smoke test is `#[ignore]` and opt-in via `DCVM_TEST_STT=/path/to/model.gguf`
  (mirrors the `DCVM_TEST_RELAY` convention).

## Acceptance Criteria

- `cargo build` compiles the C++ library via the sys crate on this machine
  (cmake 4.4 present); note build-time impact in DEVLOG.
- Offline tests green with the fake engine; ignored real-model test transcribes
  a fixture utterance to plausible text when run manually.
- `git diff Cargo.lock` reviewed after adding the dependency.

## Notes

- Quant choice: Q8_0 unless the ignored smoke test shows problems (~600 MB;
  F16 ~1.2 GB fallback). Record the exact HF repo/file/checksum in code.
- transcribe-cpp is v0.2.x / early; pin the exact version.
