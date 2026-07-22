# Long plain messages truncate to one line; no proper collapse for huge ones

## Summary

Two stacked problems around long message text (user report, 2026-07-22):

1. **Bug:** any multi-line PLAIN text message renders one line + "…" and
   clicking reflows the text outside the bubble. Root cause: the table's
   row-height primitive `NSHostingView.fittingSize` returns SwiftUI
   `Text`'s ideal (single-line) size, not height-at-width. Link-bearing
   messages are unaffected because `LinkText.sizeThatFits` measures
   correctly — which is why the demo data never showed it.
2. **Feature:** truly huge messages (email-sized) should collapse with an
   explicit "Show more" affordance — not an ellipsis — and expanding must
   resize the bubble AND the table row.

## Requirements

- Row heights measure text-at-width correctly (NSHostingController
  `sizeThatFits(in:)` or equivalent), with a regression test.
- Messages over ~5000 characters display a prefix (cut at a whitespace
  boundary) plus a visible "Show more" control; expanded messages offer
  "Show less". Below the threshold, text is never cut.
- Expansion toggles resize the table row (height cache invalidation +
  noteHeightOfRows); no text painting outside the bubble.
- Collapse/expand decision logic is pure and unit-tested.

## Acceptance Criteria

- A long plain message (no links) wraps fully in the VM.
- A >5k-char message shows "Show more"; clicking expands bubble and row;
  "Show less" collapses back. VM-verified with screenshots.
- Swift tests cover the display helper and the height measurement.

## Notes

- Threshold per user: "VASTLY more [than now], only if it's like more
  than 5k characters or something".
- The user's "clicking expands the text" was `textSelection` reflow into
  the mis-measured row — disappears with the height fix.
