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
