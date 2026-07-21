# Overnight chat becomes choppy; switching back to it hangs

## Summary

User report (2026-07-21): a thread left open all night got extremely slow
to scroll, and switching away and back hung the app. Not a memory leak —
unbounded model growth multiplied by eager rendering:

1. While not-at-bottom, every event reload grows the window by a page when
   new messages push the oldest loaded one out (`windowNeedsGrowth`) — and
   nothing ever shrinks `loadedLimit`. Overnight traffic (or a stale
   at-bottom sentinel while the window is occluded) ratchets the window up
   indefinitely.
2. The message list is an eager VStack by design — O(window) bubbles with
   NSTextView link text. Hundreds of items = choppy (the deep-window
   profiling debt deferred into native-feel-polish).
3. The chat-switch window cache (2026-07-20) removed the accidental relief
   valve: selection used to reset the window to one page; the cache now
   restores the bloated window synchronously AND the refresh re-requests
   the giant limit through core's full-history scan — the hang.

## Fix

- Reload while at-bottom trims the request back to one page (the user
  sees the newest ~10 messages either way; active use becomes the relief
  valve again).
- Passive event-driven growth is capped (`maxLoadedLimit`, 20 pages =
  1000): a backstop for the overnight scrolled-up case. Explicit
  user-driven loadOlder stays uncapped — deep manual reading is intent,
  and its perf belongs to native-feel-polish.
- The cache stores only the newest page: switching back always lands at
  the bottom (selection resets scroll), so a bigger cached window is pure
  render cost with no reader benefit.

## Acceptance Criteria

- Unit tests: at-bottom reload trims a grown window to one page; passive
  growth plateaus at the cap while scrolled up; a cache restore after
  deep scrolling is at most one page.
- Full Swift suite green; AUTOSEND probe unchanged.
- User confirms an overnight-style bloated chat recovers (scroll smooth
  after returning to bottom / switching back; no hang).

## Outcome (2026-07-21)

Window bounded on three sides (at-bottom trim, passive-growth cap,
one-page cache); the honest-stub fix made the bounds testable. The
severity question ("only ~90 messages") was answered by the spike: the
eager container's O(window) rendering amplified even modest windows —
now moot, the virtualized table renders ~15 rows regardless. User
sign-off 2026-07-21 ("feels fast now").
