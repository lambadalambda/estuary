# Windows/Linux shell decision

## Summary

The architecture keeps two paths viable: per-platform native shells (WinUI/Qt/GTK) or one
cross-platform Rust toolkit (Slint/Iced) reusing dcvm. Decide with data once the macOS
shell stabilizes.

## Requirements

- Measure the macOS shell: LoC, share of logic that leaked out of dcvm, maintenance feel.
- Prototype the thinnest candidate on one other platform against unchanged dcvm.

## Acceptance Criteria

- A written decision in DEVLOG.md with the measured evidence.

## Notes

- Original analysis: Qt/QML most mature for text-heavy chat; Slint strongest pure-Rust
  option (a11y caveats); per-platform native is best product but highest maintenance.
