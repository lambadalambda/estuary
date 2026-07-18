# AppModel account and stale-result state isolation

## Summary

`AppModel` is MainActor-isolated, but actor reentrancy still permits semantic
races across `await`. Account onboarding/demo transitions do not clear the
previous chat window, several actions update whichever chat/account is current
when they resume, and archive reload validation captures the archive state
after the request. Delta Chat IDs are account-local, so numeric ID collisions
can expose one profile's stale messages under another profile's chat.

## Requirements

- Centralize account transitions and reset all account-scoped UI state before
  loading the new account: chat selection, messages, reply target, pagination,
  filters, archive mode, and transient action state.
- Capture the complete reload identity before the first await. In particular,
  `reloadChats` must snapshot account, query, and archive mode before choosing
  the service call, then reject stale results afterward.
- Revalidate account/chat/action identity before completion-side writes in
  account switching, block/send, create-chat, create-group, and attachment
  actions. A completion from A must never clear or select state in B.
- Keep the selected chat record independent from the filtered sidebar list so
  search does not tear down `ChatDetailView`. Move drafts into testable state
  keyed by account and chat, rather than view-local state.
- Revalidate app activity and selection immediately before `markNoticed`.
- Scope onboarding progress events to the active account/flow generation.
- Make the test service use account-local IDs and enforce account ownership so
  it can reproduce the real core's collision and isolation behavior.

## Acceptance Criteria

- AppModel tests use two accounts with deliberately colliding chat/message IDs
  and prove no messages, reply IDs, drafts, or selections cross profiles.
- A blocked normal-list request cannot overwrite Archive after the user
  toggles modes, and rapid account switches cannot complete out of order.
- Sidebar search that excludes the selected chat leaves its detail view and
  account/chat-keyed draft intact.
- Tests cover switching chats/accounts while send, block, create, and
  mark-noticed calls are suspended.
- `swift test` is green.

## Notes

- The message-window-specific interleaving remains tracked separately in
  `message-window-race-appmodel-tests.md`.
- `MockChatService` currently allocates chat/message IDs globally, searches
  messages across accounts, and mutates some messages without ownership
  checks, masking the production failure mode.
