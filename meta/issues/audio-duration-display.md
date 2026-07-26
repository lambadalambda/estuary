# Show duration on audio bubbles that core reports as 0

## Summary

Voice/audio bubbles show a duration only when core knows it (`Chat-Duration`
header on real Voice messages). Plain audio attachments (and locally sent
files) report `durationMs == 0`, so users can't tell a 5-second note from a
5-minute one before pressing play.

## Requirements

- When `durationMs == 0` and a file path exists, probe the duration
  shell-side (AVFoundation metadata load) and display it; cache per path
  like ImageCache. Core-provided durations stay authoritative when nonzero.
- No blocking on the render path: probe async, bubble updates when known.

## Acceptance Criteria

- Swift unit test for the fallback/format logic (probe itself is
  AVFoundation-bound; test the pure parts).
- Mock/real app: an audio attachment without Chat-Duration shows its true
  length after a beat; a real voice message still shows core's value.

## Notes

- Filed from user feedback 2026-07-26. Duration UI (durationLabel) already
  exists in AudioMessageView; only the 0 case is unhandled.
