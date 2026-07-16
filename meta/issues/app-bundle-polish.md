# App bundle polish

## Summary

`make run-app` builds a minimal ad-hoc-signed DeltaApp.app (needed for camera TCC and
notifications). Grow it into a distributable artifact.

## Requirements

- App icon; release-profile Rust build target (core release build is slow — cache it).
- Proper version/build numbers; consider hardened runtime + notarization when signing
  identity exists.
- Dock badge for total unread count.

## Acceptance Criteria

- `make app-release` produces a self-contained .app that launches on a clean machine.

## Notes

- Bundle-less `swift run` remains the fast dev loop.
