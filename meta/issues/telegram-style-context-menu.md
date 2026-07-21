# Telegram-style message context menu

## Summary

The message right-click menu is a flat utilitarian list. Adopt Telegram's
menu structure (from the user's reference screenshot) for the features we
actually have: a quick-reaction emoji strip on top, grouped rows with icons
(Reply / Copy Text / Copy Media / Save As…), Forward, an "N Reacted" row
that opens a reactor list with avatars, and red Delete at the bottom.

## Requirements

- Quick-reaction emoji palette rendered horizontally at the top of the
  context menu (ControlGroup `.palette`); the user's current reaction is
  shown selected, and a self-reaction outside the default set still appears.
- Menu rows in Telegram's order and grouping, with SF Symbol icons:
  Reply, Copy Text (text messages), Copy Media (image-like messages),
  Save As… (any file), Quick Look / Open in App (any file) | Forward |
  N Reacted (when reactions exist) | Delete (destructive).
- "N Reacted" is a submenu listing each known reactor with avatar bubble,
  name, and their emoji; a trailing "and N more" line covers reactors past
  the identity cap.
- Menu composition (which entries show for which message) is a pure,
  unit-tested function; the view only renders the descriptor.
- Copy Media puts the image on the pasteboard; Save As… runs an NSSavePanel
  and copies the blob.

## Acceptance Criteria

- Swift tests cover entry composition (text-only, media, file, reactions,
  capped reactions, self-reaction outside defaults).
- VM screenshot shows the new menu on a reacted message: emoji strip,
  grouped rows, reactor submenu with avatars.
- Existing actions (reply, forward, delete, reaction toggle) still work.

## Notes

- Skipped (features we don't have): Translate, Pin (message-level), Select,
  Report.
- Reference: user screenshot of Telegram macOS context menu (2026-07-21).
