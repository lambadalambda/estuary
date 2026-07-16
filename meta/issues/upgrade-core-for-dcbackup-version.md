# Second-device join fails against newer iOS: upgrade pinned core

## Summary

Joining as second device from a current iOS Delta Chat fails with "the other device
runs a newer Delta Chat": the phone's DCBACKUP QR uses a backup protocol version newer
than core v2.49.0 supports (`DCBACKUP_VERSION = 4` in src/qr.rs).

## Requirements

- Bump the `deltachat` git tag in dcvm/Cargo.toml to the latest release whose
  `DCBACKUP_VERSION` matches current mobile clients.
- Survive the dependency re-resolution (socket2/netwatch pin history — see DEVLOG) and
  any core API changes in dcvm.
- Regenerate bindings; full offline suite + swift build green; smoke run.

## Acceptance Criteria

- `check_qr` on the phone's QR classifies as Backup (not BackupTooNew) — verified by
  the user completing a real second-device join from iOS.
- All existing offline tests green on the new core.
