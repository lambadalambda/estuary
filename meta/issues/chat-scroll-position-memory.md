# Remember scroll position per chat

## Summary

Scrolling up in a chat, switching away, and returning lands at the bottom
again. The position should be remembered per chat: jump to the newest
message only when there is no stored position or the stored position was
already at the bottom.

## Requirements

- Session-scoped memento per (account, chat): anchor entry id + offset in
  viewport + loaded window size; at-bottom clears the memento.
- On reopen with a memento: restore the loaded window size, then restore the
  anchor after initial layout. Anchor gone (deleted message) → fall back to
  bottom.
- Coordinator reports positions through the existing
  saveAnchor/syncDerivedState machinery — no new scroll rescue mechanisms
  (see DEVLOG scroll history).

## Acceptance Criteria

- AppModel unit tests: memento recorded/cleared correctly (at-bottom clears,
  scrolled-up stores, window size restored on reselect).
- Real/mock app: scroll up → switch chats → return lands where you left;
  fresh chats and at-bottom chats still open at the newest message.
  (AppKit scroll feel untestable per rules — user-verified.)

## Notes

- User feedback 2026-07-27.
