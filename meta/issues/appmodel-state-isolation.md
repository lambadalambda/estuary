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

## Progress (2026-07-18)

- Added the first direct AppModel test harness with controllable suspended
  service calls.
- Account onboarding/demo/switch transitions now share one account-scoped
  reset; a collision test proves old messages and selection do not survive a
  demo transition to an account with the same numeric chat id.
- `reloadChats` snapshots archive mode before awaiting; a deterministic stale
  normal-list test now passes.
- Account removal now uses the same scoped reset as onboarding, demo, and
  explicit switching.
- Selected-chat caching and account/chat-keyed drafts keep the detail and
  composer alive through filtered search. Successful sends clear only an
  unchanged originating draft; failures and edits made during send survive.
- Rapid account switches are latest-intent-wins in both the model and core;
  send/block completion writes revalidate their originating identity.
- Noticed state now requires the app to still be active, and onboarding
  progress events are scoped to the active account. Core events carry no flow
  generation, so delayed progress from a prior flow that reuses the same
  account remains unresolved.
- Pending sends are deduplicated per conversation, account switching is driven
  by one latest-intent reconciliation loop (including 1→2→1 and failure
  recovery), and filtered selected rows refresh through `chatById`.
- Selection generations advance synchronously with `selectedChatId`, guarding
  success and failure writes even before the async selection callback runs.
- Remaining requirements: deterministic create/group/attachment/mark-noticed
  completion tests, same-account onboarding flow generations, and production
  mock account-ownership semantics.
