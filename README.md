<p align="center">
  <img src="assets/brand/logo.png" alt="Estuary logo" width="220">
</p>

<h1 align="center">Estuary</h1>

<p align="center"><em>Where conversations converge.</em></p>

<p align="center">
  A native, webview-free <a href="https://delta.chat">Delta Chat</a> client
  for macOS — same protocol engine as the official apps, none of the Electron.
</p>

<p align="center">
  <a href="https://lambadalambda.github.io/estuary/">Website</a> ·
  <a href="https://github.com/lambadalambda/estuary/releases/tag/nightly">Nightly download</a> ·
  <a href="#building--running">Build it yourself</a>
</p>

---

Estuary embeds [`deltachat-core`](https://github.com/chatmail/core) — the
Rust engine behind every official Delta Chat app — in-process, and renders it
with SwiftUI. Your account is a regular chatmail/e-mail account: end-to-end
encrypted, decentralized, no phone number, interoperable with every other
Delta Chat client. A delta and an estuary are both places where a river meets
the sea; this one just runs native.

## Features

- **Chatmail-first onboarding** — instant encrypted profile (no visible
  e-mail), "Add Second Device" from your phone with live camera QR scanning,
  or classic e-mail login.
- **Full messaging** — media (images/audio/voice/files), quotes & replies,
  reactions, forwarding, message context menus, Quick Look previews.
- **Chat management** — groups, contact requests (accept/block), search,
  archive, muting (timed/forever, synced), multi-profile.
- **Native macOS feel** — notifications + dock badge, menu-bar shortcuts,
  paginated history, live timestamps, read-receipt sync.

Not yet: webxdc mini-apps, HTML mail display, voice recording, QR-invite
contact flow (tracked in `meta/issues.md`).

## Architecture

- **`dcvm/`** — Rust "viewmodel" crate over `deltachat-core` (v2.53),
  exposed via [UniFFI](https://mozilla.github.io/uniffi-rs/). Owns all
  client logic; headless and fully offline-testable.
- **`macos/`** — SwiftUI shell (macOS 15+). Thin by design: renders
  viewmodel DTOs, forwards intent. Windows/Linux shells (or one
  cross-platform Rust toolkit reusing `dcvm`) are a later,
  deliberately cheap-to-make decision.

## Download

Every push to `main` rebuilds the
[**nightly DMG**](https://github.com/lambadalambda/estuary/releases/tag/nightly).
It is ad-hoc signed (no Apple developer certificate), so the first launch
needs a right-click → **Open**, or:

```sh
xattr -dr com.apple.quarantine /Applications/Estuary.app
```

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
`DCVM_TEST_RELAY=DCACCOUNT:_cm.example cargo test --locked -- --ignored`. See
`dev/chatmail/README.md`.

## Development

Project rules live in [AGENTS.md](AGENTS.md). Issues are tracked in-repo
under `meta/issues.md`; design notes and findings in `DEVLOG.md`.

## License

Estuary's own code is public domain under [the Unlicense](LICENSE). The
bundled `deltachat-core` is MPL-2.0, so compiled binaries are also subject
to its terms. Estuary is an independent project, not affiliated with the
Delta Chat team — just gratefully compatible.
