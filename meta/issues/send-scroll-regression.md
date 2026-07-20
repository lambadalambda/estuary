# Posting a message no longer scrolls to the bottom

## Summary

User report (2026-07-20): sending a message while at the bottom of a chat no
longer follows the new message down — the viewport stays put and the new
bubble lands below the fold. Last user-confirmed working: stamped build
625719b (2026-07-17, LazyVStack + rescue-machinery era). Everything after —
the eager-VStack swap (de596ad), page-size halving, window-mutation
serialization, event-pipeline bounding, entry memoization, composer
isolation (78123e3) — is in the suspect window.

## Investigation so far (static, 2026-07-20)

Model side is provably intact:

- `send()` → MsgsChanged event → `scheduleReloadMessages` (80ms debounce) →
  `reloadMessages` → `messages = page` (append at the newest end).
- `windowNeedsGrowth` still gates growth on `viewIsAtBottom` (the original
  2026-07-17 send-scroll fix, unit-tested): at bottom → no prepend.
- `MessageListEntry` IDs are stable (`msg-<id>` / `day-<key>`), assembly is
  memoized off `messages.didSet` — appends diff as appends.

Which corners the bug in the view: the scroll pin is solely
`defaultScrollAnchor(.bottom, for: .sizeChanges)` on the ScrollView
(explicit scroll-on-change was removed in 880af5f in favor of this). The
pin only engages when the scroll position is exactly at the anchor when
content size changes. Prime hypothesis: the eager-VStack swap (or the view
restructure around it) changed conditions so the resting position no longer
counts as "at the anchor", or the sizeChanges anchor no longer engages for
appends under the new structure. The confirmed-working build had both
LazyVStack and the later-deleted re-pin rescues, so the sizeChanges pin
alone was never verified after de596ad.

## Requirements

- Posting while at the bottom follows the new message (viewport shows it).
- Posting while scrolled up must NOT yank the user down (preserved
  behavior).
- Whatever mechanism lands must be exercised with DCNATIVE_DEBUG_SCROLL=1
  evidence in the lume VM, not just eyeballed.

## Acceptance Criteria

- Model-side chain test: send in mock at bottom → exactly one window-sized
  reload, no growth, entries appended (guards the 07-17 regression class).
- VM repro before the fix (viewport stays put) and after (viewport
  follows), driven via cua-driver, screenshots or scroll-debug logs.
- User confirms send-scroll in a real chat on a stamped build.

## Notes

- Scroll-pin behavior itself is SwiftUI-runtime, untestable per project
  rules — evidence comes from the VM run instead.
- If the sizeChanges pin proves unreliable under eager VStack, the fallback
  is an explicit `proxy.scrollTo(bottomAnchorID)` on entry-append while
  `viewIsAtBottom` (the pre-880af5f mechanism, now gated on the
  sentinel-reported state instead of manual bookkeeping).

## Root cause + fix (2026-07-20)

Reproduced hands-free via a new `DCNATIVE_AUTOSEND` probe hook (seeds a
window's worth of sends, then probes) with `DCNATIVE_DEBUG_SCROLL=1`. Two
stacked causes:

1. `defaultScrollAnchor(.bottom, for: .sizeChanges)` is inert under the
   eager VStack: geo logs show the offset frozen (153) through every
   append while content grew 800 → 6736. The view had no other follow
   mechanism since 880af5f.
2. A view-side follow (`onChange` of last entry id, gated on
   `viewIsAtBottom`) also fails: visibility callbacks report post-layout
   geometry, so at decision time the grown content has already pushed the
   sentinel out — `atBottom` reads false on every append.

Fix: the model captures the PRE-append sentinel state —
`followBottomGeneration` bumps in `refreshMessageListEntries` when the
last entry id changes while `viewIsAtBottom`; the view obeys with
`proxy.scrollTo(bottom)`. Keyed on last-entry id, not count: a full-window
slide keeps the count constant (unit-tested). Post-fix probe: every append
logs a follow, offset tracks the content bottom, probe ends atBottom=true.
98/98 Swift tests green.

Remaining before archive: user confirms send-scroll in a real chat (and
scrolled-up reading positions still not yanked); VM re-verification once
the lume VM is back up.
