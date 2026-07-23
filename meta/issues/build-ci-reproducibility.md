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
- Checkout and rust-cache actions now use commit SHAs, nightly selects Xcode
  16.4 explicitly, and the local relay defaults to the verified image digest.
  The relay README no longer carries the obsolete unverified-Podman caveat.
- App/DMG verification checks plist/binary minimum-OS agreement, exact numeric
  build and commit stamps, host architecture, strict deep signing, mounted-DMG
  integrity/layout, and a three-second mock launch. The app checks pass locally;
  the restricted agent cannot create or attach images because `hdiutil` cannot
  start sandboxed `hdiejectd`, so the real DMG path awaits GitHub CI or a normal
  terminal.
- Nightly uploads a SHA-named asset without clobbering, downloads and verifies
  its SHA-256 before updating the release page, retains prior assets, and refuses
  to move its pointer to a commit older than or unrelated to the published one.
  Publication is main-only, rejects checkout/event SHA mismatches, and recovers
  after an interrupted upload by verifying the existing remote image rather
  than requiring a regenerated DMG to be byte-identical. A fake-CLI state test
  covers those paths and API failure. Write credentials are only exposed to the
  publication step. Branch protection is documented in
  `.github/BRANCH_PROTECTION.md`.
- Still open: observe the new nightly workflow complete successfully and apply
  the documented branch-protection rule in repository settings.

## Resolution (2026-07-23)

Both residuals settled. The reworked nightly has been observed green
across every push since 2026-07-18 (including the 2026-07-23 group
invite build, 11m39s, published transactionally); its failure machinery
was also exercised for real during the deployment-target incident.
Branch protection: deliberately NOT applied — the project works by
direct pushes to main (no PR flow), and strict required checks would
block them. `.github/BRANCH_PROTECTION.md` stays as the recipe for the
day a PR flow exists.
