# Correctness + housekeeping leftovers from the 2026-07-18 review

## Summary

Small confirmed findings from the full-repo review that don't belong to any
single feature issue. Each is a few lines; batch them.

## Requirements

- Makefile: add `bindings` prerequisite to `test` (Makefile:93) — fresh-clone
  `make test` fails to link `-ldcvm` (cargo test doesn't emit libdcvm.a), and
  the dev loop runs Swift tests against stale committed bindings (the UniFFI
  checksum-mismatch footgun).
- Info.plist: `LSMinimumSystemVersion` 14.0 → 15.0 (Info.plist:19-20 vs
  Package.swift `.macOS(.v15)`); the nightly DMG currently advertises
  launchability on 14.0 with a 15.0-minimum binary.
- Read receipts only for actually-rendered messages: `markVisibleMessagesSeen`
  marks every incoming message in the loaded window (AppModel.swift:408-410,
  516-521), including prepended history above the viewport. Drive mark-seen
  from per-bubble visibility instead.
- `createChat` error surface (AppModel.swift:709-718): failure is swallowed
  and the sheet dismisses silently; mirror createGroup's error string.
- Security-scoped URL lifecycle (ChatDetailView.swift:141-150,
  MainView.swift:408-414): access is released by `defer` before the detached
  async task reads the file. Moot while unsandboxed; breaks the day sandboxing
  lands. Move access inside the async operation.
- Preserve composer text/captions until send success. ChatDetailView clears
  them before the async call (ChatDetailView.swift:141-149,234-239), so a
  transient send failure destroys user input.
- Keep the last valid message window on reload failure instead of blanking the
  conversation (AppModel.swift:412-416), matching `reloadChats` policy.
- Restore Rust hygiene checks: apply `cargo fmt`, remove the unnecessary
  `mut` in tests/vm.rs:557, and either reshape or deliberately allow the
  eight-argument demo helper so strict Clippy is green.

## Acceptance Criteria

- `make test` green from a clean state (after `cargo clean`).
- `plutil -p` the built .app's Info.plist shows 15.0.
- Receipts: sender gets MDNs only for bubbles that were on screen (manual
  check against a second device or the local relay).
- A scripted `ChatService.createChat` failure keeps the New Chat sheet open and
  shows its error.
- Failed text/attachment sends leave retryable composer content intact, and a
  transient reload error leaves the last rendered conversation visible.
- `cargo fmt --check` and `cargo clippy --locked --all-targets -- -D warnings`
  are green.

## Notes

- Also from the review, NOT required here (notes for later): no PR-triggered
  CI, no `--locked` on cargo invocations, chatmail relay image tracks
  `:main` (pin a digest), stale "unverified" caveat in dev/chatmail/README.md,
  and `docs/specs/core-api.md` still describes core 2.44/2.49 rather than the
  pinned 2.53 API. CI/release items are tracked in
  `build-ci-reproducibility.md`.

## Progress (2026-07-18)

- Applied rustfmt across dcvm, removed the test warning, and deliberately
  allowed the eight-argument demo fixture builder. `cargo fmt --check` and
  strict Clippy are green.
- Account/chat-keyed drafts now survive send failure and edits made during a
  pending send; unchanged drafts clear only after success.
