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

## 2026-07-16 — Chatmail-first onboarding: instant accounts + second-device join

Modern DeltaChat hides the e-mail: onboarding is now "Create New Profile" (instant
account on a chatmail relay) and "Add as Second Device" (receive the full existing
account — credentials, keys, chats — from another device's DCBACKUP QR over encrypted
iroh P2P). Classic e-mail login demoted to "Other options".

**Core facts (v2.49.0, verified in checkout):**
- `ctx.add_transport_from_qr("DCACCOUNT:<url>")` does everything for instant accounts:
  HTTP POST to the relay (only for `https://` payloads; a bare domain generates random
  credentials locally), configure, IO restart. Progress via `ConfigureProgress`.
- The default relay (`https://nine.testrun.org/new`) is a **client-side** constant —
  core has none. Exported as `default_instance_url()`.
- Second device: `qr::check_qr` → `Qr::Backup2` → `imex::get_backup(ctx, qr)`;
  progress via `ImexProgress` (0=error/cancel, 1000=done); receiver account must be
  fresh/unconfigured (guarded in dcvm with a friendly error); `start_io()` afterwards.
  Cancel = `ctx.stop_ongoing()`.

**dcvm additions:** `VmEvent::ImexProgress`, `QrKind` classification (`map_qr`, TDD),
`check_qr` / `create_instant_account` / `join_second_device` / `cancel_ongoing` on
DcApp. Offline tests cover QR classification and join_second_device rejection paths
(wrong QR kind, garbage input, already-configured account).

**macOS:** QR arrives via clipboard (image *or* text) or an image file — decoded with
CoreImage's built-in `CIDetector` QR support, no new dependency; no camera flow yet.
Second-device UI is a sheet with paste/file pickers and imex progress.

**Verification:** cargo test 14/14 green (6 unit + 8 integration); swift build green; mock smoke run alive.
**Live test (network):** `DCNATIVE_AUTOCREATE=1` dev hook exercised the real flow —
created and configured `a7ghrcg2d@nine.testrun.org` on the default relay from the app,
landing on the main screen. Second-device join needs a second real device, so only its
error paths are machine-tested; the happy path awaits a manual run.

## 2026-07-16 — Code-review fixes: event-loss recovery, stale sidebar, retryable DcApp init

Applied five confirmed review findings (all verified against the actual v2.49.0
checkout in `~/.cargo/git/checkouts/core-eddc226e816ba9ee/dab7ca1`):

- **`EventChannelOverflow` no longer swallowed** (`dcvm/src/app.rs`): core's broadcast
  channel (capacity 10_000, drop-oldest) reports lost events as a single overflow event
  with `id: 0` (verified in events.rs `recv()`), which `map_event` mapped to `None`. The
  pump now synthesizes a full-refresh hint: `AccountsChanged` (manager-level) plus
  `ChatlistChanged` per account. Tested deterministically by stalling the pump with a
  gated listener and flooding 10_100 `Info` events through `ctx.emit_event`.
- **`MsgsChanged { chat_id: 0 }` sentinel** (`dcvm/src/mapping.rs`): core's
  `emit_msgs_changed_without_ids()` uses chat_id 0 as "no specific chat"; forwarding it
  as `ChatChanged { chat_id: 0 }` was a phantom id outside the FFI contract. Now maps
  (whole msg-event group, via `ChatId::is_unset()`) to `ChatlistChanged`.
- **Stale sidebar with the real core** (`AppModel.swift`): `marknoticed_chat` emits only
  `MsgsNoticed` + `ChatlistItemChanged` and `send_msg` only `MsgsChanged` — all mapping
  to `chatChanged`, which only reloaded the open chat's messages, never the chat list;
  badges/previews stayed stale forever (invisible in mock mode, which emits
  `.chatlistChanged`). `chatChanged`/`incomingMessage` now also `reloadChats()`.
- **Poisoned lazy DcApp task** (`CoreChatService.swift`): a transient `DcApp::new`
  failure was cached in `appTask` until relaunch. Failures now clear the cached task,
  generation-guarded so a concurrent retry's fresh task is never clobbered;
  `selectedAccount()` logs instead of silently `try?`-ing the error away.
- **Makefile had no non-interactive Swift check**: added `swift-build` (build-only) and
  `check` (= `test` + `swift-build`). Finding confirmed live: SPM's manifest sandbox
  (`sandbox-exec`) cannot nest inside this restricted dev shell when swift runs under
  make — `SWIFT_FLAGS ?= --disable-sandbox` (overridable) fixes both `swift-build` and
  `run`. Curiously, `swift build` invoked directly (not under make) worked either way.

**Verification:** `cargo test` 9/9 green (4 unit + 5 integration, incl. the new overflow
test). `make check` green end-to-end (cargo test → bindings regen → `swift build`);
bindings regen produced zero diff, confirming no exported-API change.
