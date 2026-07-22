# Reaction pills need hover affordance

## Summary

The in-bubble reaction pills are clickable (toggle your reaction) but
nothing signals it: no hover highlight, no cursor change. User report
2026-07-22: "it's hard to see that you can actually do anything".

## Requirements

- Pointing-hand cursor while hovering a reaction pill.
- Visible hover highlight on the pill, working on both bubble surfaces
  (white incoming, teal outgoing) and both appearances.

## Acceptance Criteria

- Hovering a pill shows the hand cursor and a highlight; clicking still
  toggles. Verified by the user (hover state is not driver-capturable in
  the VM QA loop — the agent cursor is an overlay, not the real pointer).

## Notes

- Pure hover visuals: no unit-testable logic (declared per TDD rule).
