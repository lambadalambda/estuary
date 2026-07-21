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

## Gauntlet results (2026-07-21, lume VM, DCNATIVE_SEED=120)

All five behaviors PASS on ChatTableView:

- Open-at-bottom, long chat: fresh open lands on the newest arrivals
  above the composer (screenshot; the exact scenario List failed).
- Follow-on-send at bottom: AUTOSEND probe ends atBottom=true with
  continuous bottom-pins (23 in the gauntlet build, 18 on the flipped
  default) — no dropped follows.
- Scrolled-up stability: send while mid-history → pixel-identical
  viewport, message lands (sidebar preview updates).
- Prepend restore: deep wheel-scroll drove multiple loadOlder prepends
  with continuous position; static check pixel-identical across a
  4s settle window.
- Tall item: 500-char message renders fully on reopen, exact height,
  styled link — no blanking.

Default flipped to "table"; DCNATIVE_LIST_CONTAINER=eager is the
rollback hatch. Remaining before archive: apples-to-apples animated
stress numbers for the production table; user confirms daily-driver
feel on the real account; then delete the SwiftUI containers, the
sizeChanges anchor modifiers, and slim OverlayScrollers.

## Notes

- Keep dcvm/model untouched: this is a view-layer port by construction.
- The window caps from overnight-window-bloat stay: virtualization makes
  big windows cheap to SCROLL, not free to fetch through core.

## Outcome (2026-07-21)

User confirmed: "feels fast now." Cleanup landed: ChatTableView is the
sole container; the eager/List branches, container env switch, bottom
anchor sentinel, ScrollViewReader plumbing, and scrollGeometryDebug are
deleted (git history and the spike issue keep the record). 118/118
tests; AUTOSEND probe on the cleaned build: 27 bottom-pins, ends
atBottom=true. The formal animated-sweep numbers item moved to
native-feel-polish alongside the deep-window profiling it supersedes.
