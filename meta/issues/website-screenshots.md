# Website screenshots with demo data

## Summary

The landing page has no visual of the actual app. Produce real screenshots
(light + dark if cheap) from a demo-seeded instance and feature them on the
GitHub Pages site.

## Requirements

- Richer demo seed in dcvm (offline, receive_imf): a group chat with ≥3
  distinct senders (shows author names/colors), 2 extra 1:1 chats for a
  fuller sidebar, a reaction chip, unread badges; group must sort newest so
  it is the auto-opened chat.
- `DCNATIVE_AUTOSELECT=1` dev hook: open the first chat after bootstrap
  (screenshot needs a conversation on screen, no UI scripting).
- Capture the real window (fresh DCNATIVE_DATA_DIR, AUTODEMO+AUTOSELECT,
  `screencapture -l <windowid>`); may need the user to grant Screen
  Recording to the terminal once.
- Website: screenshot section on docs/index.html, compressed asset(s).

## Acceptance Criteria

- Rust test proves the enriched seed (group with ≥3 senders, newest-first).
- Screenshot(s) live on the deployed site and look presentable (user
  verdict).

## Notes

- The AUTOSELECT hook body is one guarded call; the ProcessInfo read makes
  the hook itself untestable without env injection — noted explicitly.
- Screenshot capture and page layout are eyeball-verified.

## Outcome (2026-07-17)

Live and user-confirmed ("yup, looks good"): light/dark showcase captures
(mock seed, hugging bubbles, tiled background) served on the landing page
via prefers-color-scheme. Capture flow needed the user's hands — the agent
shell has no window-server access.
