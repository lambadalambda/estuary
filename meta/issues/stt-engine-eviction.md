# STT: evict the idle ASR engine

## Summary

`SttState.engine` keeps the loaded Parakeet model (~700 MB resident) for the
app's lifetime after the first transcription. Evict it after an idle period
so a single transcribe doesn't permanently cost 700 MB.

## Requirements

- Drop the engine after N minutes without a transcription (timer reset on
  use); next request reloads from disk (~few seconds, acceptable).
- No behavior change for back-to-back transcriptions.

## Acceptance Criteria

- Offline test with a fake clock or short test-tuned idle window proving
  load → use → evict → reload.
- Memory footprint returns to baseline after eviction (manual check noted
  in DEVLOG).

## Notes

- Found in the stage-3 review of [Voice message transcription](voice-message-transcription.md).
