# DEVLOG

## 2026-07-16 — Project start

**Decision: shared Rust viewmodel + per-platform native shells, macOS first.**
Rationale: `deltachat-core-rust` already does all protocol/crypto/storage work, so a client is
~just a view layer. We put everything below the pixels into a Rust crate (`dcvm`) exposed via
UniFFI, and keep native shells thin and idiomatic. If per-platform maintenance proves too heavy,
the same crate serves a cross-platform Rust toolkit (Slint/Iced) instead — the architecture keeps
that reversal cheap.

**Decisions:**
- Depend on `deltachat` core crate directly (git tag `v2.49.0`, same as deltachat-desktop's Tauri
  target) — in-process, no JSON-RPC/IPC.
- UniFFI proc-macro style for Swift bindings.
- Prototype scope: classic email login, chat list, message list (text only), send text, live
  event-driven updates.
- Local core source for reference reading: the submodule checkout at
  `deltachat-ios/deltachat-ios/libraries/deltachat-core-rust`.

**Finding: fresh lockfile breaks the build.** With a fresh `Cargo.lock`, cargo resolves
`socket2 0.6.5`, which no longer compiles with the `netwatch 0.5.0` pinned by core v2.49.0
(E0277/E0599). Fix: mirror deltachat-desktop's known-good lock — `cargo update tokio@… --precise
1.48.0` then `socket2@… --precise 0.6.1` (newer tokio requires socket2 ^0.6.3, so tokio must be
downgraded first). `Cargo.lock` is committed for reproducibility.

**Environment notes:**
- No system Rust; installed rustup (Rust 1.97) into `~/.cargo` / `~/.rustup`.
- Swift 6.3.3 / xcodebuild on macOS 26, arm64.
