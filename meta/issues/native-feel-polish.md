# Native-feel polish batch

## Summary

Make the app feel like a first-class macOS citizen: composer ergonomics, Quick Look,
menu-bar commands with shortcuts, dock badge, subtle sounds, Liquid Glass accents on
macOS 26.

## Requirements

- Multi-line growing composer (Return sends, Option+Return newline), focus kept after
  send and set on chat switch.
- Quick Look previews for attachments (space-bar-style preview instead of launching apps).
- App menu commands: New Chat (Cmd+N), New Group (Shift+Cmd+N), Profile Settings (Cmd+,),
  toggle Archived (Shift+Cmd+A).
- Dock badge with total unread count.
- Subtle receive sound when a message arrives outside the selected chat while active.
- Liquid Glass composer/banners via `glassEffect` where available (runtime-gated, no
  platform bump).

## Acceptance Criteria

- Builds green, mock + real-core smoke runs alive; user confirms feel.

## Notes

- Deliberately NOT bumping min platform to 26: glass is gated with #available.
- macOS 26's SwiftUI WebView/WebPage is the natural engine for the webxdc issue later.

- Profile a deep-scrolled message window (~10 history pages, now eager
  VStack): per-bubble closures defeat struct-equality skips, so every
  bubble re-evaluates per composer keystroke. If it hitches: hoist the
  per-bubble TimelineView, or cap/trim the grown window when re-pinned at
  the bottom.
