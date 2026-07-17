# Project rules

Read this before changing anything.

## Process

- **Issue first**: every piece of work starts as an issue in `meta/issues.md`
  (see the repo-issues conventions). Archive with `[x]` only when the
  acceptance criteria are verifiably met.
- **TDD is required**: write the failing test, then the code. Rust tests live
  in `dcvm/src` (unit, pure mappers) and `dcvm/tests/vm.rs` (offline
  integration); Swift tests in `macos/Tests/DeltaAppTests`. If something is
  genuinely untestable (visual scroll feel, TCC prompts), say so explicitly in
  the commit/DEVLOG instead of skipping silently.
- **Code review before every commit**: run a review pass (code-review skill or
  an equivalent subagent) over the pending diff; fix confirmed findings first.
- Small topical commits, conventional messages. Record notable findings and
  decisions in `DEVLOG.md`.

## Architecture invariants

- All client logic lives in `dcvm` (Rust); shells stay thin and idiomatic.
  If a shell grows nontrivial logic, it probably belongs below the FFI.
- The FFI contract (types + `DcApp` methods) changes deliberately: update
  dcvm, run `make bindings`, then update ChatService protocol, mock, and
  CoreChatService together. **After ANY exported-API change or core bump you
  must regenerate bindings and rebuild Swift**, or the app dies at runtime
  with "UniFFI API checksum mismatch".
- MockChatService mirrors real semantics — keep it honest when core behavior
  is discovered (e.g. pagination anchors, mute semantics).

## Rust specifics

- `source "$HOME/.cargo/env"` (rustup install, no system Rust).
- **Never run bare `cargo update`.** The lockfile pins are load-bearing
  (socket2/netwatch history — see DEVLOG). Check `git diff Cargo.lock` after
  any manifest change.
- Dev profile only in the normal loop; a release build of core takes 10+ min.
- Tests are offline: never call `start_io` in tests. Pseudo-configure via
  `Config::ConfiguredAddr` + relax `ForceEncryption` (see `pseudo_configure`).
  Network tests are `#[ignore]` and opt-in via `DCVM_TEST_RELAY`.
- Core sources for the pinned tag are in
  `~/.cargo/git/checkouts/core-*/<rev>/src` — verify semantics there instead
  of guessing.

## Swift specifics

- `swift build/test` may need `--disable-sandbox` inside agent sandboxes
  (nested seatbelt); plain works in a normal terminal.
- Swift 6 strict concurrency in the app target; the generated DeltaCore
  target stays in Swift 5 language mode (UniFFI limitation).
- Watch for stale-await bugs: any `await` in AppModel must re-validate
  selection/account state before writing UI state (see DEVLOG 2026-07-17).

## Local infrastructure

- Local chatmail relay: `dev/chatmail/run.sh up` (podman must be running;
  `_cm.example` must resolve via /etc/hosts). Client 1:1 first-contact on
  chatmail requires securejoin — plain first mails are rejected by filtermail.
