# DEVLOG

## 2026-07-16 — Gap closing: media, reactions, chat management (issue: close-ui-gaps)

Built in-session after repeated 529 API overloads killed both delegated build agents
four times each (no work lost — they died during read phases; strict TDD was compressed
to tests-with-implementation under the circumstances).

**dcvm:** MessageKind/QuoteInfo/ReactionItem/ContactItem; MessageItem carries file
metadata + quote + aggregated reactions; ChatItem group/archive/device flags + avatar;
send_message (attachments by extension-guessed viewtype, quoted replies), send_reaction,
delete/forward/mark_seen, accept/block, archive + archived_chats, search (chats +
messages), contacts, create_group, display name/self-avatar, connectivity. 22 offline
tests green (9 unit + 13 integration).

**v2.49 semantics discovered:**
- `Contact::get_all` hides address-contacts unless `DC_GCL_ADDRESS` is passed.
- Encrypted groups reject address-contacts ("Only key-contacts can be added") — the
  group UI warns; proper fix arrives with the QR-invite contact flow issue.
- `prepare_msg_blob` demotes undecodable images to File — tests need a real PNG
  (tests/fixtures/1x1.png).

**macOS UI:** media bubbles (inline images/gif/sticker, audio/voice playback via a
shared AVAudioPlayer, file/video rows opening in Finder apps), quote blocks + reply
composing, reaction chips with own-reaction toggling, context menu (copy/reply/react/
forward-with-chat-picker/delete), paperclip + drag&drop attachments, Accept/Block
replacing the composer for contact requests, mark-seen on visible chats (read receipts
+ cross-device read sync), real avatars, sidebar search, archived-chats view +
archive/unarchive, group creation with member picker, profile settings sheet (name,
avatar, connectivity), incoming-message notifications (bundle builds only).

Webxdc rendering intentionally still out (own issue). Visual pass on the new UI is
pending the user; builds + smoke runs green.

## 2026-07-16 — Camera QR scanning + .app bundle

"Add Second Device" can now scan the QR live off the other device's screen:
AVCaptureSession → per-frame (throttled, queue-confined) CIDetector; first hit
auto-fills the payload and starts the join. No new dependencies.
TCC nuance: camera permission for a bare `swift run` binary gets attributed to the
terminal; `make run-app` builds a minimal ad-hoc-signed DeltaApp.app with
NSCameraUsageDescription so the prompt is properly attributed and persists.
Camera path is build-verified only in the agent session (no TCC interaction possible);
first real scan happens on the user's machine.

## 2026-07-16 — Local relay verified end-to-end; two hard-won findings

The podman chatmail relay works (amd64 image forced via `--platform`, runs under
Rosetta): `/new` POST, IMAP/SMTP with self-signed `_cm.example` certs, and both opt-in
tests green — instant account creation (~2 s) and a full encrypted message round trip
between two accounts (~1.5 s). The app onboards against it via
`DCNATIVE_INSTANCE=DCACCOUNT:_cm.example`.

Debugging the round trip surfaced two product-relevant core behaviors (details in
dev/chatmail/README.md):
1. **filtermail rejects unencrypted outbound** — first contact by bare address cannot
   deliver on chatmail; securejoin QR invites are the real flow (the test now does the
   handshake; the UI will need an invite/QR contact flow eventually).
2. **The first-scan race**: mail arriving during an account's initial post-configure
   inbox scan is classified as pre-existing and silently skipped. This produced a
   perfectly alternating test flake (fast runs beat the scan) — fixed by waiting for
   connectivity Connected (4000) before messaging a fresh account. Conceivably a real
   edge case for instant-onboarding flows, not just tests.
   Red herrings on the way: inotify limits (fine), maybe_network nudging (didn't help —
   the mail was fetched and *deliberately* skipped, not unseen).

Also: exported `maybe_network()` through the FFI; the app calls it when the scene
becomes active (wake from sleep → immediate fetch instead of next poll).

## 2026-07-16 — Local test infrastructure: offline second-device test + podman chatmail relay

**Second-device transfers need no server.** The DCBACKUP transfer is a direct iroh/QUIC
connection with `RelayMode::Disabled` — core's own tests run provider→joiner in one
process. `dcvm/tests/vm.rs` now covers the full happy path (demo account provides,
fresh account joins, chats + ImexProgress verified) in ~1.5 s offline. Gotcha: iroh QRs
advertise only LAN/VPN direct addresses, never loopback, and self-connect via the LAN IP
is blocked in the agent sandbox — the test rewrites `direct_addresses` to `127.0.0.1`,
which also makes it hermetic on any network.

**Local chatmail relay (dev/chatmail/):** official `ghcr.io/chatmail/docker:main` image
with `MAIL_DOMAIN=_cm.example`. Underscore domains are the officially anticipated local
mode: the server self-signs certs and skips DNS checks, and core v2.49 skips TLS
verification for `_`-hosts (src/net/tls.rs) — including the DCACCOUNT HTTPS POST, which
otherwise only trusts compiled-in webpki roots. `DCACCOUNT:<bare-domain>` skips HTTP
entirely (credentials invented locally, mailbox created on first login — what core's own
CI does against `CHATMAIL_DOMAIN`). Wired up: `DCNATIVE_INSTANCE` env in the app,
`DCVM_TEST_RELAY` + `#[ignore]`d `instant_account_against_local_relay` test.
**Unverified end-to-end:** the podman VM cannot boot in the agent session
(Virtualization.framework "Internal Virtualization error" regardless of memory/EFI
reset — environment restriction; UDP loopback works, VZ doesn't). Needs
`podman machine start` from a normal terminal, plus one-time
`127.0.0.1 _cm.example` in /etc/hosts (sudo). Image is amd64 → Rosetta on this host.

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

## 2026-07-17 — Core upgrade v2.49.0 → v2.53.0 (second-device vs newer iOS)

A real iOS phone's "Add Second Device" QR was rejected as BackupTooNew: current mobile
clients emit DCBACKUP **5**, v2.49 supports ≤4. v2.53 supports 5.

API fallout fixed in dcvm:
- `EnteredServerLoginParam` split into `EnteredImapLoginParam`/`EnteredSmtpLoginParam`.
- `MessageState::OutPreparing` removed.
- Reactions: one emoji per contact, `Reaction::as_str()` (no more `emojis()` vec).
- **`ForceEncryption` now defaults ON**: unencrypted sends fail and unencrypted
  incoming mail is not processed. Correct for real accounts; the offline demo account
  and test fixtures relax it (`set_config_bool(ForceEncryption, false)`, same as
  core's own test_utils), since keyless pseudo-configured accounts can't encrypt and
  inject plaintext mail by design.
- Dependency tree grew aws-lc-rs/aws-lc-sys (needs `cmake` at build time — present via
  homebrew here). socket2/netwatch pins survived re-resolution.

Verified: 22 offline tests + both relay tests green on v2.53; swift build clean;
demo smoke run alive; bundle rebuilt. Real iOS join pending user retry.

## 2026-07-17 — Scroll/pagination polish (issue: chat-list-width-and-scroll-behavior)

First real-account feedback fixes:
- Sidebar: min 300 / ideal 360 (was 240/300) — names and previews no longer truncate.
- Message pagination: `messages(limit, before_msg_id)` in the FFI (limit 0 = all, used
  by tests). The app loads the newest 100 and fetches another page when a top sentinel
  becomes visible, restoring the scroll anchor ("msg-<id>") after prepending. Event
  reloads refresh exactly the loaded window, so reactions/state updates on visible
  history still appear without loading everything.
- Bottom-follow only when already at bottom (tracked by a bottom-sentinel
  appear/disappear); otherwise incoming messages leave the viewport alone.
- Chat switch snaps to the newest message without animation (the animated scroll only
  runs for new-message-while-at-bottom).

## 2026-07-17 — Scroll follow-up: layout-aware anchoring + stable image sizes

The manual scroll bookkeeping raced layout: snapping to bottom before lazy cells and
images had their real sizes landed mid-chat, and a blob finishing its download grew the
bubble after the last scroll. Replaced with the purpose-built API (needs macOS 15,
platform bumped): `.defaultScrollAnchor(.bottom)` for layout-aware initial position
(+ `.id(chat.id)` so each chat starts fresh = snap semantics) and
`.defaultScrollAnchor(.bottom, for: .sizeChanges)` to stay pinned through content
growth only while actually at the bottom. Deleted isAtBottom/lastNewest tracking;
prepend anchor-restore stays.

Image bubbles now size themselves from core's stored pixel dimensions BEFORE the blob
exists (placeholder at final size while downloading), so arrival changes pixels, not
layout. Plus an NSCache for decoded images (LazyVStack re-renders hit disk otherwise).

## 2026-07-17 — Native-feel polish (issue: native-feel-polish)

- Multi-line growing composer (TextField axis .vertical, 1–5 lines; Return sends,
  Option+Return newline), focus kept after send and set on chat switch.
- Quick Look previews for attachments (tap or context menu); "Open in App" separate.
- Menu-bar commands: New Chat ⌘N, New Group ⇧⌘N, Profile Settings ⌘, (replacing the
  stock settings item), Show Archived ⇧⌘A — sheet state moved into AppModel so both
  toolbar and menu drive the same sheets.
- Dock badge: total unread across unmuted chats, updated with the (unfiltered) list.
- Subtle "Pop" for messages landing in other chats while active (notifications cover
  the inactive case).
- Liquid Glass composer bar on macOS 26 via #available (min platform stays 15).

## 2026-07-17 — Links, in-chat avatars, live timestamps, full muting

- URLs in bubbles are tappable (NSDataDetector -> AttributedString links; white
  underline on outgoing accent bubbles, accent on incoming).
- Group chats show the sender avatar beside the first bubble of each run
  (MessageItem.sender_avatar over the FFI); later bubbles keep the indent.
- Chat-list timestamps were already relative but never refreshed — now wrapped in
  TimelineView(.everyMinute) so "now"/"5 min" stay honest.
- Muting: set_chat_muted over the FFI (MuteDuration::Forever/NotMuted, synced),
  mute/unmute in the row context menu, gray unread badge, no sound, no notification
  for muted chats. Offline mute round-trip test (24 dcvm tests total).

## 2026-07-17 — Whole-app audit: 3 parallel reviewers, ~25 findings, fix pass

Three independent audit agents (Rust/FFI, Swift concurrency/bridge, app state/UX)
converged on the same core bug families. Fixed in this pass:

**Rust:** event pump held a strong Arc cycle keeping Accounts (and the accounts.lock)
alive after DcApp drop — now Weak with upgrade-or-exit; demo conversation order was
scrambled after its hardcoded dates passed (send_text_msg sorts at "now") — both
directions now injected via receive_imf with relative dates (regression-tested);
add_demo_account error path rolls back the auto-selected half-seeded account;
messages(before: deleted-anchor) returned the NEWEST page (duplicate prepends) — now
empty (tested); ContactsChanged/SelfavatarChanged were unmapped (no refresh signal);
new chat_by_id point lookup (TDD) so notification decisions never scan stale lists.

**Swift:** the stale-await family — reloadChats/reloadMessages/loadOlderMessages all
re-validate account/chat/filter state after every await (chat A's slow fetch can no
longer render inside chat B, nor corrupt its pagination window); read receipts and
mark-noticed no longer fire while the app is inactive (they run on activation
instead); notifications now work for ALL accounts, use a fresh chat_by_id lookup
(fixes muted-chat bypass under search/archive and one-event-stale previews), and
queue while the permission prompt is unanswered; event bursts are coalesced (80 ms)
instead of one full reload per event; onboarding flows can't brick isConfiguring or
clobber each other; search keystrokes no longer destroy the open chat's draft;
archive toggle clears search; account switch/remove resets filters and dock badge;
deleted messages clear a dangling reply banner; forward sheet lists all chats, not
the filtered sidebar; audio player resets when playback finishes (with stale-player
identity guard); camera scanner can't fire after stop (lock, not queue-async flag);
main-screen errors surface as an alert instead of leaking into onboarding.

**Deferred (accepted for now, in the audit issue):** distinct EventsDropped signal
instead of overloading ChatlistChanged; per-account notification coalescing during
initial-sync storms of background accounts; live connectivity outside the settings
sheet. showAuthor/avatar per-run rules and Color-hex validation got Swift unit tests
(new test target, macos/Tests/DeltaAppTests).

## 2026-07-17 — Link cursor (AppKit) + send-scroll window fix

- pointerStyle(.link) never rendered: SwiftUI's text-selection pointer wins. Link-
  bearing messages now render via an NSTextView-backed `LinkText` (per-range hand
  cursor through the `.cursor` attribute, native link clicks, selection); plain
  messages keep SwiftUI Text. `nsLinkified` (AppKit-scope attributes) is unit-tested.
- "Send lands mid-chat in 100+ chats": the reload window-growth heuristic fired on
  every send (window slides one, previous oldest drops off, misread as lost reading
  position) and prepended a full page — destabilizing lazy layout. Growth is now
  gated on the view's actual at-bottom state (bottom sentinel reports to the model);
  decision extracted as pure `windowNeedsGrowth` and TDD'd (4 cases).

## 2026-07-17 — Estuary rebrand, first slice (issue: estuary-rebrand)

The app has a name: **Estuary** ("where conversations converge" — delta and
estuary are both river mouths; Delta Chat compatible, not a fork). User
approved a brand sheet: teal/coral palette, wave-into-speech-bubble icon.

- `EstuaryTheme` (TDD'd: hex validity — a typo'd hex silently falls back to
  gray — role distinctness, adaptive accent): deep teal `#0F3D3E` accent in
  light mode, sea glass `#7FBDB4` in dark (deep teal reads near-black there),
  via an NSColor dynamic provider so appearance switches re-resolve. Outgoing
  bubbles stay deep teal in BOTH modes: they carry white text, and sea glass
  would wash it out. Unread badges are coral `#FF6F61` (muted stays gray).
- Renames: Info.plist name/display "Estuary", bundle output `Estuary.app`,
  window title, onboarding title + tagline. Deliberately UNCHANGED: bundle id
  (TCC camera + notification grants are keyed to it), data dir
  `DeltaChatNative` (existing accounts), internal target names (churn).
- Visual result (accent rendering in both appearances) is eyeball-verified,
  not unit-testable; constants and adaptive selection logic are.
- Icon asset pending → app-bundle-polish issue. Mockup features out of scope:
  calls/presence (no core support), list filter tabs, accent picker.
- Review pass caught: coral badge with white numerals is ~2.7:1 → badge text
  is midnight blue now (muted gray badges keep white); badge theme test
  tightened to guard the actual `badge`/`badgeText` colors, not hex literals.
  Flagged-plausible, accepted: dark-mode sea-glass tint behind prominent
  buttons — macOS auto-contrasts control labels for light accents (same
  mechanism as the system yellow accent), needs a dark-mode eyeball.

## 2026-07-17 — App icon + onboarding logo (issue: app-bundle-polish, icon slice)

User delivered the wave-into-speech-bubble logo — as an AI export with the
transparency checkerboard BAKED INTO the pixels (hasAlpha: no). Recovery
pipeline in `dev/icon/gen-icon.swift` (make icon):

- Border-seeded flood fill over the two sampled checker colors recovers real
  alpha; the interior white wave is safe because the fill only spreads
  through checker-colored pixels. 1px anti-aliasing rim gets half alpha.
- Premultiplied-alpha gotcha: zeroing ONLY the alpha byte leaves RGB
  contributing on composite (src-over adds premultiplied RGB regardless) —
  the icon rendered a white box behind the logo until RGB was zeroed too.
- Composite follows Apple's icon grid (824px rounded square, r=185, on a
  1024 canvas), warm-ivory fill like the brand sheet's header lockup;
  `iconutil` packs the ten-size iconset into assets/brand/Estuary.icns.
- Onboarding shows the real logo (bundled via SPM resources, loaded through
  `Bundle.module`, SF-symbol fallback). Resource presence is TDD'd — and the
  Makefile now copies DeltaApp_DeltaApp.bundle into Contents/Resources,
  because Bundle.module TRAPS at runtime if the bundle is missing from the
  .app. Icon rendering itself is eyeball-verified (build artifact).

## 2026-07-17 — Going public (issue: publish-github-nightly-site)

Repo published as github.com/lambadalambda/estuary. Pieces:

- **License**: the Unlicense (public-domain dedication) for our code; core
  stays MPL-2.0 (noted in README, deliberately NOT inside LICENSE — extra
  text there breaks GitHub's licensee similarity matching). Review caught
  dcvm/Cargo.toml still claiming MPL-2.0 from the prototype scaffold.
- **README**: rewritten around the brand (logo header, website + nightly
  links, honest Gatekeeper note for ad-hoc-signed builds).
- **CI nightly** (.github/workflows/nightly.yml): macos-15 runner, rust-cache,
  cargo test → make app → swift test → drag-install DMG (hdiutil UDZO) →
  delete+recreate the `nightly` prerelease so the asset URL stays stable.
  Concurrency queues rather than cancels: a cancel between release delete
  and create would 404 the download link (review catch). Dev-profile build,
  same as `make app` — honest nightly; release packaging = app-bundle-polish.
- **Website**: docs/index.html (single file, palette + Sora, light/dark),
  served by GitHub Pages from main:/docs. Review catch: the features card
  claimed "voice messages" while recording is still on the not-yet list —
  now says playback.
- CI YAML/HTML aren't unit-testable; verification = the live workflow run
  and the served page.

## 2026-07-17 — Review follow-ups: link cursor, message timestamps, timed mutes

- Hand cursor over link-bearing bubble text (pointerStyle(.link); SwiftUI has no
  per-range pointer — link-free text inherits the normal cursor, caught in the new
  pre-commit review).
- Message footers now use the same fresh-relative format as the chat list ("now",
  "5 min", then clock time), refreshing every minute.
- Mute durations: FFI takes seconds (0 unmute / negative forever / positive timed via
  MuteDuration::Until); menu offers 1 h / 8 h / 1 week / forever.
- Process: a code-review pass now precedes every commit.

## 2026-07-17 — Rebrand slice 2: calm ivory surfaces (issue: estuary-rebrand)

User verdict: keep teal/coral, add the warm ivory background, "calmer
overall". Chat surface is now adaptive ivory/midnight; incoming bubbles are
flat white cards (card navy in dark), delineated by a faint shadow — the
fills sit deliberately close to the surface, which is the calm. Review pass
flagged the near-invisible card edges (mockup-accurate but risky) → shadow;
and a theme test overclaiming "contrast" when it only guards same-color
pairs → renamed honestly. Dynamic-color creation extracted into one
`adaptive(_:)` helper now that three colors use it.

## 2026-07-17 — Quote contrast fix, tiling chat background, showcase mock

- User-found bug: quote blocks in OUTGOING bubbles used `.primary`/contact
  colors → black-on-deep-teal. Everything inside an outgoing bubble must be
  white; quote bar/name/text now switch on `isOutgoing`.
- Tiling chat background from the user's CC0 pattern (make tiles →
  dev/icon/gen-tiles.swift): light = pattern MULTIPLIED onto warm ivory;
  dark = DIFFERENCE-inverted, then SCREENED onto midnight at 0.5 alpha so
  only the strokes lift the background. 512px bitmaps declared at 256pt for
  @2x retina density. `ChatBackdrop` (surface + tile, per-appearance via
  colorScheme) replaces the flat surface. Tile visuals are eyeball-verified
  (both variants inspected); resource presence is theme-tested.
- Mock seed reworked into the website showcase (Elena/Marco/Priya/Sam,
  Weekend Hikers group with isGroup flag, real bundled CC0 sunset photo,
  previews/timestamps synced for manual appends) — pinned Saved Messages
  would have hijacked chats.first for the AUTOSELECT hook, so it's unpinned.
  Showcase shape is pinned by MockShowcaseTests. Screenshot env recipe:
  DCNATIVE_MOCK=1 DCNATIVE_AUTODEMO=1 DCNATIVE_AUTOSELECT=1
  DCNATIVE_APPEARANCE=light|dark.

## 2026-07-17 — Hugging bubbles + website screenshots

- User request (with official-DC reference shot): bubbles must hug their
  content, anchored to their side, instead of stretching the full row. The
  stretch came from the timestamp footer's `.frame(maxWidth: .infinity)`
  inside the bubble VStack — any greedy child makes the whole bubble
  greedy. Now: content VStack + timestamp as a ZStack(.bottomTrailing)
  overlay (reserved bottom padding so it never covers text) + a 560pt
  readability cap on wide windows. Pure layout, eyeball-verified via the
  screenshot loop.
- Screenshot pipeline in practice: mock showcase + AUTOSELECT/APPEARANCE
  hooks, user captures the windows (⇧⌘4+Space; agent shell has no window-
  server access — CGWindowList returns zero bounds, screencapture blank).
  Both variants on the site via <picture> prefers-color-scheme.

## 2026-07-17 — Overlay scrollers in the chat (user: intrusive scrollbar)

The persistent scroll track (system "Always show scroll bars") reads as
intrusive on the tiled surface. `OverlayScrollers` NSViewRepresentable walks
up to the backing NSScrollView and forces scrollerStyle = .overlay (fade
after scrolling). Review catch: AppKit reverts the style on
preferredScrollerStyleDidChange (pref flip, mouse plug) with no SwiftUI
update to piggyback on → explicit NotificationCenter observer re-applies.
AppKit view-walking is untestable in unit tests (no window hierarchy) —
eyeball-verified.

## 2026-07-17 — Chat chrome polish (sidebar scroller, composer card)

- Correction of the entry above: AppKit view-walking IS unit-testable —
  NSScrollView hierarchies build fine headless, no window needed
  (OverlayScrollersTests). Only the live-window timing/insertion races stay
  eyeball-only.
- OverlayScrollers redesigned after the sidebar needed it too: a List's
  NSScrollView is a *sibling* of a `.background` anchor, not an ancestor,
  and review showed any "style the first match" lookup fails open (styles
  the wrong pane's scroller, reports success, never retries — SwiftUI gives
  no locality guarantees in its platform hierarchy). apply() now sweeps the
  whole window and styles EVERY scroll view — idempotent, race-tolerant.
  Also dropped the updateNSView re-apply: it ran on every composer
  keystroke; insertion + 0.4s retry + style-change observer cover all real
  reversion events.
- Composer is now a floating rounded card (incoming-bubble surface) over the
  tiled backdrop instead of a square bar — resolves the shape clash with the
  rounded sidebar. Bubble + composer share one `cardSurface` recipe so they
  can't drift apart. The Liquid Glass `barBackground` helper (and its
  `#if compiler(>=6.2)` CI guard) is gone with the bar.
- Backdrop ownership moved up to MainView's detail column so the
  "No Chat Selected" state sits on the same tiled surface (no flash on
  selection changes).
- Composer icon alignment: `.lastTextBaseline` instead of hand-tuned bottom
  paddings. Untestable visuals (baseline alignment incl. multi-line drafts,
  card look, scroller fade) are eyeball-verified per project rules.
