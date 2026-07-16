# deltachat-native

A native, non-webview DeltaChat client. Architecture:

- **`dcvm/`** — a Rust "viewmodel" crate wrapping [`deltachat` core](https://github.com/chatmail/core)
  in-process. Owns all client logic: account management, login, chat list state, message list
  state, composer/send, event handling. Headless and unit-tested; exposed to native shells via
  [UniFFI](https://mozilla.github.io/uniffi-rs/).
- **`macos/`** — a SwiftUI macOS shell (the prototype platform). Intentionally thin: renders
  viewmodel DTOs, forwards user intent. Per-platform shells for Windows/Linux can follow, or the
  viewmodel can be reused from a cross-platform Rust toolkit instead — the boundary keeps that
  decision cheap.

## Prototype scope

Classic email login, chat list, text-message view, send text messages, live updates via core
events. No attachments, reactions, or webxdc yet.

## Building

```sh
# Rust side (crate + Swift bindings)
cd dcvm && cargo build
# macOS shell
cd macos && ./build.sh
```

See `DEVLOG.md` for design notes and findings.
