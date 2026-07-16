# Prototype: dcvm viewmodel + SwiftUI macOS shell

## Summary
Initial working client: headless Rust viewmodel (`dcvm`) over deltachat-core v2.49.0
(in-process, UniFFI), thin SwiftUI shell — chat list, text messages, composer, live
event-driven updates, offline demo account.

## Outcome
Done 2026-07-16. TDD offline test suite (pseudo-configure + receive_imf); five
review findings fixed. See DEVLOG entries of 2026-07-16.
