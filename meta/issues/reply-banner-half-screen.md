# Reply banner fills half the screen

## Summary

Starting a reply makes the replied-to preview above the compose field
balloon to roughly half the window (user report 2026-07-22). Mechanism:
the banner's accent bar (greedy RoundedRectangle) lets the banner accept
any proposed height, so the chat VStack splits the window between the
(greedy) message table and the (now-greedy) composer.

## Requirements

- The reply banner hugs its content: one preview line + sender name.
- The accent bar spans exactly the banner's content height.

## Acceptance Criteria

- Replying shows a compact banner in the VM; composer height unchanged
  apart from the added banner row.

## Notes

- Same greedy-decoration family as the quote-bar measurement bug fixed
  in d772d48; fix is pinning the banner to its ideal height. Pure layout,
  not unit-testable — VM-verified instead (declared per TDD rule).
