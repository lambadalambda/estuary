# Transcribe button: pointer cursor on hover

## Summary

Hovering the Transcribe (and Retry) button on audio bubbles keeps the arrow
cursor; interactive elements should show the pointing hand like the
reaction pills do.

## Acceptance Criteria

- Hovering Transcribe/Retry shows NSCursor.pointingHand, and the cursor
  restores on exit (house pattern from ReactionChipsView, including its
  vanish-mid-hover caveat if applicable).

## Notes

- User feedback 2026-07-27. Visual behavior; untestable per project rules —
  user-verified.
