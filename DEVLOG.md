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

## 2026-07-16 — dcvm implemented + Swift bindings generated

**Design:**
- Pure mapping layer (`src/mapping.rs`): core `EventType`/`MessageState`/`SummaryPrefix`/u32
  color → FFI types, all side-effect-free and unit-tested first (true red→green TDD). The async
  glue in `src/app.rs` only composes these. `DcApp` integration work used compile-fail as the red
  phase (tests written and run before `app.rs` existed).
- `DcApp` holds `Arc<tokio::sync::RwLock<Accounts>>` (rpc-server pattern). All core work — the
  event pump AND every method body — is bridged onto one global `LazyLock<Runtime>` via
  `RT.spawn(...)`, so core-internal `tokio::spawn`s land on the same long-lived runtime whether
  a call comes from Swift (UniFFI/async-compat) or a Rust test runtime.
- `selected_account()` must be sync per contract; a `std::sync::Mutex<Option<u32>>` cache
  (refreshed from `get_selected_account_id()` after every mutation) avoids blocking on the
  tokio RwLock from sync context.
- Event pump: one `EventEmitter` from the accounts manager; `map_event` drops noise (Info/
  Warning/etc.), listener errors are ignored, pump exits when the channel closes.
  `MsgsChanged`/`MsgDelivered`/`MsgRead`/`MsgFailed`/`MsgsNoticed`/`ChatlistItemChanged(Some)`
  all collapse to `ChatChanged { chat_id }` — the UI reloads the visible chat either way.

**Surprises / deviations from the specs:**
- **v2.49.0 gates `receive_imf` behind the `internals` feature** (2.44 spec said plain public).
  `internals = []` is cfg-only (no extra deps), so it's enabled unconditionally.
- **Adding uniffi to Cargo.toml silently re-resolved three lock edges**: hyper-util/quinn/
  quinn-udp flipped their socket2 dep 0.5.10 → 0.6.1. That dropped the `all` feature previously
  unified onto socket2 0.5.10, breaking netwatch's bsd.rs (E0599 `Type::RAW`). Fix: hand-flip
  those three edges back in `Cargo.lock`, verify with `cargo build --locked`. Moral: even
  "additive" manifest changes can re-resolve shared deps; check `git diff Cargo.lock`.
- `uniffi-bindgen-swift --modulemap` names the module after the *crate* (`dcvm`), ignoring
  `module_name` in uniffi.toml — pass `--module-name DeltaCoreFFI` explicitly (baked into the
  Makefile `bindings` target).
- Demo account (`add_demo_account`): pseudo-configure via `Config::ConfiguredAddr`, contacts
  created first so `receive_imf` messages land in normal chats (not contact requests), last
  incoming message per chat left unseen for unread badges, plus a "Saved Messages" note.

**State:** `cargo test` green (4 unit + 4 integration, all offline, no `start_io`). Bindings in
`macos/Sources/DeltaCore` + `DeltaCoreFFI` typecheck with `swiftc -swift-version 5`. Root
Makefile targets: `rust`, `bindings`, `run`, `test` (dev profile everywhere).
