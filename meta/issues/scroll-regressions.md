# Scroll regressions: jump-to-top on select/post, sidebar scroller flash

## Summary

User-reported after the chrome polish landed:

1. Selecting a chat, or posting in one, can scroll the conversation all the
   way to the top — reproducible for some chats.
2. On chat selection the legacy scrollbar briefly flashes in the chat list.

## Analysis

1. `loadOlderMessages` returns a top-anchor id and the view restores it via
   `proxy.scrollTo(anchor, .top)`. When the viewport is at the bottom (chat
   just opened / just posted) and the load-older sentinel is realized —
   which happens for chats whose loaded window fits the viewport — the
   restore flings the view to the top. At the bottom the
   `.defaultScrollAnchor(.bottom, for: .sizeChanges)` pin already handles
   prepended content; the restore only exists for scrolled-up reading.
2. AppKit re-stamps the preferred (legacy) scroller style when the List
   re-tiles on selection change. Since the per-update re-apply was removed
   (perf), nothing corrects it until a rare trigger — a regression from the
   OverlayScrollers redesign.

## Requirements

- History restore anchor is suppressed while the view is at the bottom.
- Overlay scroller style is pinned per scroll view: a revert is corrected
  synchronously (before it can draw), not on the next global trigger.

## Acceptance Criteria

- Unit tests: restore-anchor decision (nil at bottom, id when scrolled up);
  scroller style re-pins after an external revert.
- User confirms: no jump-to-top on select/post, no sidebar scroller flash.

## Outcome (2026-07-17)

User-confirmed fixed ("yup, that fixed it") after three commits: at-bottom
restore suppression, KVO style pin (sidebar flash), and the pin-bottom
rescue for the stranded-viewport blank pane. DCNATIVE_DEBUG_SCROLL=1
diagnostics stay in for future scroll forensics.

## Reopened (2026-07-17, same evening)

Blank-open still reproduces for the problematic chat, and it is
window-size-dependent: a given size reliably breaks it, ANY resize heals it
instantly, and switching away/back at the broken size re-breaks it.
DCNATIVE_DEBUG_SCROLL logs show NO loadOlder activity — the prepend theory
is falsified for this repro; the initial bottom-anchored layout itself
strands the viewport (bottom-anchor visibility flaps ~12x per open while
layout oscillates). Next: scroll-geometry diagnostics + post-open re-pin.

## Plan after approach review (2026-07-17)

Stopgap shipped: 120ms proxy re-pin + 450ms 1pt container nudge (the
resize-heal path). Real fix queued: replace LazyVStack with plain VStack
(100 fixed-size items in the open window; three lazy-realization
regressions to date), profile, then delete the rescue machinery.

## Root-cause fix (2026-07-18)

LazyVStack replaced with plain VStack after the geo trace proved 2.2x
height overestimates parked the viewport in phantom space (and that no
scroll API nor container nudge could re-anchor it). Rescue machinery
deleted. Remaining before archive: user confirms the repro chat, and a
profiling pass on a deep-scrolled (~500-item) window.
