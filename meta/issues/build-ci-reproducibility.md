# Build, CI, and release reproducibility

## Summary

The current nightly builds a usable artifact, but verification starts only
after changes reach `main`, Cargo commands can update the load-bearing lockfile,
and release recreation deletes the stable download before uploading its
replacement. Toolchain and relay inputs are also mutable.

## Requirements

- Add pull-request CI for locked Rust tests, binding regeneration, Swift tests,
  and a non-interactive Swift build.
- Use `--locked` for every Cargo build/test/bindgen invocation and declare the
  supported Rust toolchain. Pin CI Xcode selection deliberately.
- After binding generation, fail CI if tracked DeltaCore/DeltaCoreFFI output is
  dirty.
- Upload an immutable, commit-addressed asset before changing the public
  nightly pointer. Keep the release/tag and previous public target intact
  until the new asset is verified; do not rely on non-transactional
  `gh release upload --clobber` for rollback safety.
- Pin third-party actions and the local relay image to immutable revisions or
  digests.
- Make `PROFILE=release run` use the release Swift configuration and
  profile-specific scratch directory, like `swift-build`.
- Add bundle checks for plist/binary minimum OS agreement, numeric build
  version, code-sign verification, DMG verification, architecture, and a short
  mock-mode launch smoke test.

## Acceptance Criteria

- PR CI reports failure for stale bindings, lockfile drift, failing Rust/Swift
  tests, or a Swift link/build failure. Document the checks that should be
  required by repository branch protection.
- A failed nightly build or immutable-asset upload leaves the release page and
  previous public download target available.
- Re-running CI for the same commit uses the same Rust, Xcode, actions, Cargo
  graph, and relay image inputs.
- `make PROFILE=release run` links release Rust and builds/runs release Swift.

## Notes

- Fresh-clone `make test` and the plist minimum-version mismatch remain in
  `review-leftovers-batch.md` because they are immediate local correctness
  fixes.

## Progress (2026-07-18)

- Cargo build/test/bindgen commands now use `--locked`; Rust 1.97 with rustfmt
  and Clippy is declared in `rust-toolchain.toml`.
- Pull-request CI runs `make check`, verifies regenerated bindings are clean,
  and enforces Rust formatting/strict Clippy.
- `make test` now depends on Rust build + binding generation, and a full run
  passed 30 Rust tests (2 relay tests ignored) plus 56 Swift tests.
- Release-profile `run` uses the profile-aware Swift flags/scratch directory.
- Bundle build numbers are numeric git commit counts with the SHA stored in a
  separate plist key; the assembled app advertises macOS 15 and passes strict
  code-sign verification. Nightly checks out full history so the count is
  accurate for normal `main` descendants; rewrite/rerun-safe monotonic
  publication is still open.
- Still open: immutable nightly publication, pinned action/Xcode/relay image
  revisions, DMG/architecture/smoke checks, and branch-protection setup.
