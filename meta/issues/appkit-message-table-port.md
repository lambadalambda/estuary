# Port the message list to an AppKit NSTableView representable

## Summary

Spike verdict (message-list-engine-spike, data in that issue): the eager
VStack obeys scroll commands but collapses on size; SwiftUI List scrolls
near-perfectly but silently drops programmatic scroll commands against
row virtualization; only NSTableView showed both nominal-time scrolling
and deterministic control. User approved the port (2026-07-21): "if
telegram learned that they need it, we do too."

## Architecture

- `ChatTableView: NSViewRepresentable` (production-quality, replacing the
  spike probe): NSScrollView + NSTableView, single column, SwiftUI
  bubbles (`MessageBubbleView`/`DayMarkerView`) in recycled
  `NSHostingView` rows.
- The MODEL CONTRACT IS UNCHANGED — every SwiftUI-era behavior maps to an
  explicit AppKit call we own:
  - open-at-bottom → `scrollRowToVisible(lastRow)` after the first
    reload (synchronous, no materialization race);
  - `followBottomGeneration` bump → `scrollRowToVisible(lastRow)`;
  - `viewIsAtBottom` → derived from `documentVisibleRect` vs content
    height (deterministic; retires the 1px sentinel + visibility-callback
    race class entirely);
  - loadOlder trigger → visible-rect near top (replaces the
    ProgressView-visibility sentinel);
  - prepend restore → save anchor row + offset-in-row before insert,
    restore after (documentVisibleRect math);
  - MDN visibility reporting → `rows(in: documentVisibleRect)` feeding
    the existing `messageVisibilityChanged`.
- Update strategy driven by a PURE transition function over entry-id
  sequences (unit-tested first):
  `entriesTransition(from:to:)` → `.none | .initial | .inPlace |
  .appended(n) | .prepended(n) | .slide(droppedTop:appended:) | .reset`.
  `.inPlace` refreshes visible rows' rootViews; append/prepend/slide use
  row insert/remove without reload; `.reset` reloads + restores position
  via the anchor machinery. Note: a prepend can legally regenerate the
  old leading day marker (same-day merge) — that degrades to `.reset` +
  anchor restore, which is correct, just less pretty.
- Staged behind the existing container switch
  (`DCNATIVE_LIST_CONTAINER=table`) until the gauntlet + user pass, then
  flipped to default and the SwiftUI containers deleted.

## Acceptance Criteria

- Transition function fully unit-tested (all seven classifications,
  including the day-marker prepend degradation).
- Five-behavior gauntlet in the lume VM, all pass: open-at-bottom (long
  chat), follow-on-send at bottom, scrolled-up stability during appends,
  prepend position restore, tall-item open.
- Stress harness numbers for the production table at n=200/1000
  comparable to the phase-1 List numbers (animated sweep this time, so
  per-frame stats are apples-to-apples).
- AUTOSEND probe green against the table container.
- Full Swift suite green; user confirms daily-driver feel (scrollback in
  a big chat, no regressions in the five behaviors).
- After the flip: eager/List container code and the sizeChanges anchor
  modifiers deleted; OverlayScrollers reduced to whatever the table
  still needs (scroller style is set at scroll-view creation there).

## Notes

- Keep dcvm/model untouched: this is a view-layer port by construction.
- The window caps from overnight-window-bloat stay: virtualization makes
  big windows cheap to SCROLL, not free to fetch through core.
