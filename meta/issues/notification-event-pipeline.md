# Notification delivery and event-pipeline backpressure

## Summary

The Rust event channel is bounded, but `CoreChatService` immediately forwards
events into an unbounded Swift `AsyncStream`. The MainActor consumer handles
them serially and performs a `chatById` lookup for each incoming message.
Foreground notifications also have no presentation delegate; messages for a
background account can therefore be silent while the app is active.

## Requirements

- Define and implement foreground notification behavior for every account,
  including messages outside the selected account.
- Bound or coalesce the Swift event bridge while preserving an explicit
  overflow/full-refresh recovery path.
- Preserve incoming `msgId` through notification handling so bursts do not
  produce duplicate notifications using only the chat's latest preview.
- Coalesce state-refresh events separately from user-visible incoming-message
  notifications; do not drop the latter accidentally.
- Provide an app-wide unread summary below the Swift shell so the dock badge
  includes background accounts and remains correct under search/archive.

## Acceptance Criteria

- With the app frontmost, an incoming message for a non-selected account has a
  documented, tested user-visible notification or sound.
- A synthetic event burst has bounded queued work and converges to current
  chat/account state after overflow.
- Two rapid messages produce two correctly attributed notification decisions,
  not two copies of the final chat preview.
- Dock unread count covers all configured accounts regardless of sidebar
  filters.

## Notes

- Notification burst coalescing and total unread count were previously noted
  in the whole-app audit and app-bundle/native-feel issues, but had no complete
  event-pipeline acceptance criteria.
- This issue owns the unread-summary implementation. `app-bundle-polish.md`
  depends on this result for its dock-badge requirement.

## Completed (2026-07-18)

- The Swift bridge now has a bounded incoming FIFO plus a separately bounded,
  keyed state queue. Incoming callbacks backpressure rather than evict message
  IDs; state keys coalesce, overflow schedules one explicit full refresh, and
  weighted dequeue prevents recovery starvation. Rust dispatches foreign
  callbacks through Tokio's blocking pool so this backpressure cannot stall the
  async workers needed by AppModel RPCs.
- Notifications load the exact event `msgId`, then check the freshest chat mute
  state. Foreground `.app` builds install a retained notification-center
  delegate that presents banners with sound for every account.
- dcvm exposes the core-backed fresh, unmuted count across all configured
  accounts. AppModel serializes dirty badge refreshes and drives the Dock from
  this global value, independent of selected account, search, or archive.
- Tests cover exact rapid-message attribution, a mute race, background-account
  foreground routing, bounded synthetic bursts and recovery convergence,
  incoming backpressure/close, single-flight refreshes, transient unread
  failures, and multi-account unread state.
- Core's upstream 10,000-event channel can still overflow before the Swift
  bridge. Its existing recovery reconstructs current state, but exact
  notifications for upstream-dropped incoming events would require a durable
  notification watermark/replay API in core.
