# Chat switching flashes an empty timeline

## Summary

Switching chats renders a visible empty-chat frame before messages arrive:
selection synchronously clears the message window (the anti-bleed guard),
then awaits the FFI fetch, which core serves by scanning the full chat
history. Telegram-macOS never shows this state — its navigation gates the
swap on a readiness promise and its Postbox serves the initial window from
an indexed store near-instantly (fetch-then-swap; see DEVLOG 2026-07-20).

## Approach

Per-conversation window cache in AppModel (sibling of the drafts dict):
on selection, after the reset, restore the last-loaded window for the new
(account, chat) key synchronously — correct chat, possibly stale — and let
the existing generation-guarded reload refresh and re-cache it. First-ever
opens still fetch (helped later by dcvm indexed pagination, tracked in
dcvm-data-access-performance). The Telegram-style hold-old-until-ready swap
was considered and rejected: it fights NavigationSplitView's instant swap
and reintroduces the cross-chat timing risks our guards exist to kill.

## Requirements

- Revisiting a chat renders its last window synchronously (no empty frame),
  keyed by account + chat — no cross-account or cross-chat bleed.
- The async refresh still lands, updates the cache, and follows the bottom
  when new messages arrived (existing followBottomGeneration semantics —
  a cache restore itself must NOT fire the follow).
- Cache is bounded (LRU) and cleared on account-scoped resets.

## Acceptance Criteria

- Unit tests: cache hit on revisit while the reload is still in flight
  (scripted suspended fetch); account+chat keying under colliding ids;
  account transition clears the cache; restore does not bump
  followBottomGeneration.
- Full Swift suite green; AUTOSEND scroll probe unchanged (open at bottom,
  follows on append).
- User confirms chat switching no longer flashes on a real account.
