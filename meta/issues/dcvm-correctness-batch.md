# dcvm correctness batch (search window/order + small fixes)

## Summary

Review (2026-07-18) found five small confirmed bugs in dcvm, headline:
`search_messages` selects the wrong 100-hit window and contradicts its
documented order. Core `search_msgs` returns hits newest-first;
`ids.into_iter().rev().take(100).rev()` (dcvm/src/app.rs:442-449) keeps the
100 OLDEST hits (newest matches silently dropped past 100) and presents them
newest-first, while the doc comment says "newest last" and MockChatService
implements newest-last.

## Requirements

- Fix the search window/order to newest 100 hits, newest last
  (`.take(100).rev()`), matching the doc comment and the mock.
- Event-pump overflow path: don't call the foreign `EventListener` while
  holding `accounts.read()` (app.rs:238-240 — the for-loop-head temporary
  keeps the read guard alive across the callback). Bind `let ids = …` first.
- `chat_items`: a chat deleted between list snapshot and per-chat load must
  not fail the whole sidebar (app.rs:127). Pinned core v2.53 has no
  `Chat::load_from_db_optional`; distinguish a genuinely missing row from
  database/decoding failures, or add an upstream optional loader, rather than
  suppressing every load error.
- `set_chat_muted`: clamp huge positive durations (app.rs:676-678) —
  `SystemTime::now() + Duration::from_secs(i64::MAX as u64)` panics
  (contained by `on_rt`, but an ugly reachable panic at the FFI surface).
- Align generic attachment classification with core's conservative mapping.
  In particular, dcvm currently labels WebM/MKV as Video, Opus as Audio, and
  HEIC as Image (mapping.rs:55-64), while core intentionally leaves several of
  these as File for cross-client interoperability.

## Acceptance Criteria

- Regression test pins search window AND order with >100 seeded hits (or a
  deterministic subset proving the window is the newest N); would have failed
  before the fix.
- Test or documented untestability for the remaining fixes (overflow
  listener-under-lock is hard to trigger offline; chat_items deletion race
  may be simulatable by deleting a chat between `try_load` and the row loop
  via a second context).
- `cargo test` green; bindings regenerated and Swift rebuilt per AGENTS.md.

## Notes

- Found by reading core v2.53 (`Context::search_msgs` ORDER BY m.id DESC)
  and tracing the iterator; verified in review.
- Adjacent low-severity smells from the same review, NOT required here:
  `search_chats("")` errors instead of returning empty; `chat_by_id` preview
  ignores drafts; `ConfigSynced` event unmapped; background `EventType::Error`
  and `ErrorSelfNotInGroup` are dropped with no diagnostic path.
