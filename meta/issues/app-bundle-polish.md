# App bundle polish

## Summary

`make run-app` builds a minimal ad-hoc-signed DeltaApp.app (needed for camera TCC and
notifications). Grow it into a distributable artifact.

## Requirements

- App icon; release-profile Rust build target (core release build is slow — cache it).
- Proper version/build numbers; consider hardened runtime + notarization when signing
  identity exists.
- Dock badge for total unread count (implementation owned by and dependent on
  `notification-event-pipeline.md`).

## Acceptance Criteria

- `make app-release` produces a self-contained .app that launches on a clean machine.
- `CFBundleShortVersionString` is a valid release version and
  `CFBundleVersion` is a monotonic one-to-three-component integer.
- The dock badge reflects the app-wide unread summary across all configured
  accounts and remains correct while the sidebar is filtered or archived.
- Hardened runtime/notarization remains explicitly blocked until a signing
  identity is available; do not archive this issue while that requirement is
  still intended but unverified.

## Notes

- Bundle-less `swift run` remains the fast dev loop.

## Progress (2026-07-18)

Release-profile packaging: `make app-release` (PROFILE parameterizes cargo
--release, uniffi lib path, SPM lib dir via DCVM_PROFILE env in
Package.swift, and .app assembly; separate SPM scratch dir per profile
because the cached manifest bakes in the lib dir). Nightly CI builds
release Rust throughout — single Rust profile (cargo test --release) so the
cache carries one core build; Swift tests link the release lib. Icon was
done earlier. Remaining: hardened runtime + notarization (needs an Apple
Developer identity — user decision), dock unread badge, proper
CFBundleShortVersionString, and a numeric monotonic CFBundleVersion (the
current git SHA does not match Apple's one-to-three-integer build-number
format).

Numeric `CFBundleVersion` now uses the git commit count and the short SHA is
stored separately as `EstuaryGitCommit`. A built app reports minimum macOS 15
and passes `codesign --verify --deep --strict`. Nightly fetches full history,
but a history rewrite or old workflow rerun can still republish a lower count,
so the monotonic-build criterion remains open alongside dock-wide unread count
and signing/notarization.
