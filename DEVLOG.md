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

## 2026-07-16 — Swift/Rust integration: app runs against the real core

**Wiring:**
- `macos/Package.swift` grew the two generated targets per the recipe:
  `.systemLibrary(DeltaCoreFFI)` + `.target(DeltaCore, swiftLanguageMode(.v5))`, with
  linker settings on the executable: `-L dcvm/target/debug`, `.linkedLibrary("dcvm")`,
  `.linkedFramework("SystemConfiguration")` (the only framework the linker demanded —
  needed by netwatch's `system-configuration` crate).
- `CoreChatService` (actor) adapts the generated `DcApp` to the app's `ChatService`
  protocol. `DcApp`'s constructor is async but `ServiceFactory.make()` is sync, so the
  DcApp is created lazily via a stored `Task<DcApp, Error>` (idempotent under concurrent
  first calls). Generated types collide by name with the app's mirror types — qualified
  as `DeltaCore.X` inside the adapter only; the rest of the app never imports DeltaCore.
- Event bridge: the `EventListener` callback (tokio worker thread) just yields into an
  `AsyncStream` continuation — that *is* the thread hop, since the single consumer
  (AppModel's event loop) runs on the MainActor. Listener class is `@unchecked Sendable`.
- `ServiceFactory`: CoreChatService by default (data dir
  `~/Library/Application Support/DeltaChatNative`, `DCNATIVE_DATA_DIR` override);
  `DCNATIVE_MOCK=1` keeps the pure-Swift mock.

**Findings:**
- **Stale `libdcvm.dylib` shadowed the static lib**: the crate-type used to include
  `cdylib`; the leftover dylib in `target/debug` predated `DcApp`, and `ld -ldcvm`
  prefers dylibs over `.a`, so the link failed with missing `uniffi_dcvm_fn_*` symbols
  even though the `.a` had all 136 of them. Deleted the stale dylib (cargo won't
  regenerate it now that crate-type is `["lib","staticlib"]`).
- Swift 6 strict concurrency rejected a closure-based `mapping { ... }` error helper on
  the actor ("sending 'self'-isolated value ... risks data races"); plain
  `do/catch { throw mapError(error) }` per method is boring but clean.
- Benign ld warnings: prebuilt sqlite3/OpenSSL objects in libdcvm.a target macOS 26.5
  vs the package's 14.0 deployment target.
- UI scripting (System Events) can't attach to the bundle-less `swift run` binary in
  this environment, so the demo path got a dev hook instead: `DCNATIVE_AUTODEMO=1`
  auto-triggers `tryDemo()` when bootstrap lands on onboarding.

**Verification:** `cargo test` 8/8 green (unchanged, no exported-API changes so no
binding regen needed). `swift build` green. Smoke tests with a mktemp data dir: plain
launch alive after 8 s, core wrote `accounts.toml`; `DCNATIVE_AUTODEMO=1` launch alive
after 10 s with a demo account on disk — 12 chats / 18 msgs in its `dc.db`, empty stderr.
