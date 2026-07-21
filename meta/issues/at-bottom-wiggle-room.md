# At-bottom detection needs human wiggle room

## Summary

The table's follow gate uses a strict 4pt offset tolerance. A trackpad
graze can leave the viewport 20-60pt shy of true bottom while still
LOOKING pinned (the newest bubble is merely clipped) — incoming messages
then legitimately-but-surprisingly stop following. Likely explanation for
the user's "doesn't scroll down when unfocused" report (2026-07-21), which
did not reproduce under focus/occlusion testing.

## Approach

Adopt the Telegram semantic instead of a bigger pixel constant: the view
counts as at-bottom when the NEWEST row is at least partially inside the
viewport. If the reader can see the live edge, follow; if the newest row
is fully below the fold, never yank. Self-scaling, no tunable. Decision
extracted as a pure function for tests; the strict-offset check stays as
the degenerate/empty-list fast path.

## Acceptance Criteria

- Pure-function tests: exact bottom, few-pt shy, newest-row-partially
  visible (follow), newest-row-fully-below (no follow), empty list.
- VM check: nudge 2-3 wheel notches up → incoming still follows; scroll a
  full screen up → incoming does not move the viewport.
- Full suite green; user confirms the original annoyance is gone.
