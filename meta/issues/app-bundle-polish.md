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

## Progress (2026-07-18)

Release-profile packaging: `make app-release` (PROFILE parameterizes cargo
--release, uniffi lib path, SPM lib dir via DCVM_PROFILE env in
Package.swift, and .app assembly; separate SPM scratch dir per profile
because the cached manifest bakes in the lib dir). Nightly CI builds
release throughout — single Rust profile (cargo test --release) so the
cache carries one core build; Swift tests link the release lib. Icon was
done earlier. Remaining: hardened runtime + notarization (needs an Apple
Developer identity — user decision), dock unread badge, proper
CFBundleShortVersionString.
