# Local core builds target the host macOS, not the app's minimum

## Summary

Nothing sets `MACOSX_DEPLOYMENT_TARGET` for the Rust build, so core objects
compiled locally — especially the C dependencies built by the `cc` crate
(OpenSSL family) — target the host OS (26.5 on the dev machine) while
`Package.swift` pins macOS 15 and the linked binary claims `minos 15.0`.
The link emits hundreds of "object file was built for newer 'macOS' version
(26.5) than being linked (15.0)" warnings, and a locally built release DMG
carries code that may assume newer-runtime behavior on a real macOS 15
machine. CI artifacts are unaffected only by luck: macos-15 runners cannot
produce 26.5-targeted objects. `make verify-app` cannot catch this — the
final binary's `minos` load command reads 15.0 regardless; only the archive
members reveal the mismatch.

## Requirements

- Rust/C core objects build against the same minimum (15.0) as the Swift
  target, locally and in CI, both profiles.
- A verification step fails when any `libdcvm.a` member targets a newer
  macOS than the app's minimum — red against today's locally built lib,
  green after the fix.
- The gate runs as part of artifact packaging so a bad lib cannot reach a
  DMG.

## Acceptance Criteria

- New check script fails against the pre-fix release lib and passes after
  a rebuild with the pinned deployment target.
- `make app-release` completes with zero "built for newer 'macOS' version"
  linker warnings.
- Full `make check` (Rust + Swift tests) green after the rebuild; the
  re-packaged release app still launches in the lume VM.

## Notes

- Found 2026-07-18 while shipping the locally built release app to the lume
  VM (see the nightly-dmg-bundle-module-crash issue); the ld warnings were
  the tell.
- Single source of truth problem: `Package.swift` (`.macOS(.v15)`),
  `Info.plist` `LSMinimumSystemVersion`, and now the Makefile's deployment
  target must agree; verify-app already ties plist to binary, the new check
  ties the archive to the Makefile pin.

## Outcome (2026-07-19)

`export MACOSX_DEPLOYMENT_TARGET ?= 15.0` in the Makefile;
`dev/release/check-object-minos.sh` scans the archive members' minos and
gates both `app` packaging and `make check`. Red confirmed against the
pre-fix lib (26.5), green after rebuild. Gotcha worth remembering: the env
pin re-fingerprints rustc compiles but NOT cached cc build-script outputs —
blake3's NEON object stayed at 26.5 until `cargo clean -p blake3`; the new
gate is what caught it. Zero "built for newer" ld warnings on
`make app-release`, full `make check` green (Rust + 96 Swift), rebuilt
release app verified launching in the lume VM.
