# Nightly DMG crashes on launch on any machine except the build machine

## Summary

The published `Estuary-nightly.dmg` app crashes at first render on any clean
machine (verified in the lume VM, macOS 26.5.2): SIGTRAP in the SwiftPM
generated `resource_bundle_accessor.swift`, reached via `EstuaryTheme.logo` →
`Bundle.module` from `OnboardingView.body`.

The non-Xcode SwiftPM accessor tries exactly two locations:

1. `Bundle.main.bundleURL + "DeltaApp_DeltaApp.bundle"` — the **app root**
   (`Estuary.app/DeltaApp_DeltaApp.bundle`), not `Contents/Resources/` where
   the Makefile `app` target copies the bundle.
2. The absolute build-time scratch path baked in at compile time
   (`/Users/runner/work/estuary/estuary/macos/.build-release/.../release/`).

Neither exists on a user's machine, so the app traps. It "works" on dev
machines only because path 2 (the local `.build`/`.build-release` scratch dir)
exists there and silently rescues the lookup — which is why local `make app`
verification never caught it. `make verify-app`/`verify-dmg` also run on the
build machine, so they can't catch it either.

## Requirements

- The packaged app must load its resource bundle on a machine where neither
  the repo checkout nor the build scratch dir exists.
- Resolution must keep working for `swift run`, `swift test`, and local
  `make app` (where `Bundle.main` is the bare binary / test runner).
- Placing the bundle at the app root is not acceptable if it breaks
  codesigning (top-level items other than `Contents` generally do).

## Acceptance Criteria

- A unit test covers the resolution order of the app's resource-bundle
  helper (candidate-URL logic testable without a real .app layout).
- A packaged release-profile app launches past onboarding on a machine
  without the repo/scratch paths — verified in the lume VM via the
  cua-driver (screenshot of the onboarding screen).
- Fresh nightly DMG built from the fix installs and launches in the VM with
  no `/Users/runner/...` path present (remove the diagnostic symlink first).

## Notes

- Root cause confirmed 2026-07-18 in the VM: creating
  `/Users/runner/.../release/DeltaApp_DeltaApp.bundle` as a symlink to the
  bundle inside `Contents/Resources` makes the same DMG app launch and render
  onboarding correctly. That symlink is a diagnostic hack on the VM only and
  must be deleted when verifying the real fix.
- Likely fix shape: stop calling `Bundle.module` directly from app code; use
  a small helper that tries `Bundle.main.resourceURL +
  "DeltaApp_DeltaApp.bundle"` first and falls back to `Bundle.module` for
  `swift run`/tests. All `Bundle.module` call sites (EstuaryTheme logo, chat
  tiles, mock assets) go through it.
- Crash report: `~/Library/Logs/DiagnosticReports/DeltaApp-2026-07-18-112305.ips`
  in the VM; fatal message names both candidate paths.
