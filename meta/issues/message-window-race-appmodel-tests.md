# Message-window mutation race + first AppModel tests

## Summary

`reloadMessages` and `loadOlderMessages` (AppModel.swift:373-463) both mutate
`messages`/`loadedLimit` after awaits but re-validate only account/chat, not
window state. Interleaving: loadOlder captures the oldest id and suspends →
event-scheduled reload fetches the newest page → loadOlder resumes and
prepends (loadedLimit grows) → reload resumes, guard passes, and
`messages = page` clobbers the grown window; `hasMoreMessages` computes
`page.count >= loadedLimit` → false, wedging "load older" shut until the next
event heals it. In a quiet chat it stays broken: scrolled-up history vanishes
mid-read. This is the remaining hole in the stale-await family fixed on
2026-07-17.

Root enabler: AppModel has zero direct tests — the ChatService protocol +
mock exist precisely to enable them and are unused for it.

## Requirements

- Serialize window mutations (single mutation queue or a window-generation
  counter both methods check after awaiting).
- Start AppModel tests with a scripted fake ChatService: reproduce the race
  above as a failing test first (TDD), then fix.
- Cover the existing stale-await guards (chat switch during reload /
  loadOlder) while the harness is fresh.

## Acceptance Criteria

- The interleaving test fails on main, passes after the fix.
- AppModel test suite exists in macos/Tests/DeltaAppTests and runs in
  `make test`.
- `swift test` green; no behavior change otherwise.

## Notes

- Also consider (not required): `reloadMessages` error path blanks the open
  conversation (AppModel.swift:412-416) while `reloadChats` deliberately
  keeps the stale list — inconsistent policies.
- Mock fidelity gaps that limit what these tests can catch, fix opportunisti-
  cally or defer: timed mutes never expire (MockChatService.swift:395-397),
  searchChats returns insertion order instead of last-activity-DESC,
  addAccount doesn't auto-select.
