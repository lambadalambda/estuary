# Unread badge climbs for the chat currently being viewed

## Summary

An incoming message in the SELECTED chat while the app is active still
increments that chat's sidebar unread badge, and it sticks until the user
switches away and back. Unread should only accumulate for chats not
currently on screen.

Root cause (read from the event path): `incomingMessage` does call
`markSelectedChatNoticed()`, but that guard reads `chat.freshCount > 0`
from the SIDEBAR row — which is refreshed by a debounced (80ms) reload
scheduled by the same event. At call time the cached row still says 0, the
guard bails, the marknoticed RPC never fires; the reload then lands with
the incremented count and nothing re-triggers marking until a selection
change or app re-activation.

## Requirements

- Incoming message in the selected chat + app active → chat is marked
  noticed immediately (fresh-count guard must not consult the stale row on
  this path; the count is definitionally about to rise).
- Incoming in a non-selected chat, or while the app is inactive → badge
  accumulates as today (never mark chats the user isn't looking at).
- Contact requests stay unmarked (existing rule).

## Acceptance Criteria

- Unit tests: incoming-in-selected-chat (active) marks noticed even with a
  stale freshCount of 0; incoming in another chat does not; incoming while
  inactive does not.
- Full Swift suite green.
- User confirms the badge no longer climbs in the open chat.
