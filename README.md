# deltachat-native

A native, webview-free Delta Chat client. Same protocol engine as the official
apps ([`deltachat-core`](https://github.com/chatmail/core), in-process), new
native shells.

## Architecture

- **`dcvm/`** — Rust "viewmodel" crate over `deltachat-core` (v2.53, git tag),
  exposed to shells via [UniFFI](https://mozilla.github.io/uniffi-rs/). Owns all
  client logic: accounts, onboarding (chatmail instant accounts, second-device
  backup transfer, classic e-mail login), chat/message state, media, reactions,
  search, archive, muting, events. Headless; fully offline-testable.
- **`macos/`** — SwiftUI shell (macOS 15+). Thin by design: renders viewmodel
  DTOs, forwards intent. Windows/Linux shells (or one cross-platform Rust
  toolkit reusing `dcvm`) are a later, deliberately cheap-to-make decision.

## What works

Chatmail-first onboarding (instant profile, "Add Second Device" incl. live
camera QR scanning, e-mail login), synced messaging with media
(images/audio/voice/files), quotes/replies, reactions, message context menus
(copy/reply/react/forward/delete), contact requests (accept/block), groups,
search, archive, muting (timed/forever, synced), profiles (switch/add/remove,
avatar, display name), read-receipt sync, notifications + dock badge, Quick
Look previews, paginated history, live timestamps, menu-bar shortcuts.

Not yet: webxdc mini-apps and HTML mail display (need an embedded webview —
see `meta/issues/`), voice recording, QR-invite contact flow.

## Building & running

```sh
make run-app   # build everything + launch as .app bundle (camera, notifications)
make run       # faster dev loop, bare binary (no notification/camera identity)
make test      # dcvm cargo tests + Swift tests
make check     # tests + full build, non-interactive
```

Requirements: Rust (rustup), Xcode command-line tools (Swift 6+), `cmake`
(pulled in by core's crypto backend). First core build takes ~10 minutes.

Environment switches: `DCNATIVE_MOCK=1` (pure-Swift mock service),
`DCNATIVE_DATA_DIR` (accounts dir override),
`DCNATIVE_INSTANCE=DCACCOUNT:<relay>` (instant-account relay override),
`DCNATIVE_AUTODEMO=1` / `DCNATIVE_AUTOCREATE=1` (dev smoke hooks).

## Local test relay

`dev/chatmail/run.sh up` starts a real chatmail relay in podman (self-signed
`_cm.example` underscore-domain mode). Opt-in network tests:
`DCVM_TEST_RELAY=DCACCOUNT:_cm.example cargo test -- --ignored`. See
`dev/chatmail/README.md`.

## Development

Project rules live in [AGENTS.md](AGENTS.md). Issues are tracked in-repo under
`meta/issues.md`; design notes and findings in `DEVLOG.md`.
