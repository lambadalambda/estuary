# STT: transcription latency — measure and fix

## Summary

User reports transcription "takes quite some time" in real use, while Handy
(same transcribe.cpp engine) is near-realtime. Find where the time goes and
close the gap. Suspects: first-use engine load (~700 MB + Metal warmup)
being perceived as transcription time, silent CPU fallback, Q8_0 vs smaller
quants, session-per-call overhead, debug-profile C++ compilation.

## Requirements

- Bench harness printing: resolved backend ("metal" vs "cpu"), model load
  time, per-run inference time and real-time factor on a known sample, for
  Q8_0 and Q4_K_M.
- Fix what the numbers implicate (e.g. force/verify Metal, switch quant,
  preload the engine when a chat with voice messages opens, reuse sessions).
- Surface the load-vs-transcribe distinction in the UI if load dominates
  (the "Transcribing…" spinner currently covers engine load too).

## Acceptance Criteria

- Numbers in DEVLOG: backend, load time, RTF per quant on this machine.
- Perceived per-message latency after the first use is clearly sub-audio
  (RTF well below 1) and the first-use cost is explained in the UI or
  amortized (preload).

## Notes

- Filed from user feedback 2026-07-26 after real-world use.
- `Model::backend()` exists to detect CPU fallback; `Backend::Auto` is the
  crate default and should resolve to Metal on Apple Silicon.
