# Link hover cursor + scroll-on-send in large chats

## Summary

1. pointerStyle(.link) doesn't render the hand cursor over links (SwiftUI's
   textSelection pointer wins). Needs an AppKit-backed text view for link-bearing
   messages: native link cursor, click handling, selection.
2. Sending in a 100+-message chat sometimes lands mid-chat: reloadMessages' window
   growth misfires on every send (newest-window slides one, previous oldest drops
   off, misread as "preserve scrolled-up history"), prepending a full page and
   destabilizing lazy layout.

## Requirements

- Hand cursor over links (only links), I-beam elsewhere, links clickable, text
  still selectable.
- Window growth only when the user is actually scrolled up (view reports
  at-bottom state); at bottom, plain newest-window reload with no prepend.
- Pure decision logic extracted and unit-tested (TDD).

## Acceptance Criteria

- Swift tests for the growth decision + link attribution; user confirms cursor and
  send-scroll behavior on a stamped build.

## Outcome (2026-07-17)

Both fixed and user-confirmed on stamped build 625719b: NSTextView-backed LinkText
for per-range hand cursor; window growth gated on view-reported at-bottom state
(pure windowNeedsGrowth, TDD'd).
