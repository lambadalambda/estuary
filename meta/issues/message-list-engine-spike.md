# Message-list engine spike: measure before the port

## Summary

Every scroll bug family to date lived in the SwiftUI container, and deep
scrollback is slow at a few hundred eager items (user-confirmed
2026-07-21). Research: our pattern IS the current Apple-recommended one;
its documented weak spots are exactly our bug list; macOS lags iOS; teams
shipping chat at scale use custom AppKit/UIKit lists. Decision (user):
run a measured stress spike before committing to a port.

## Plan

1. Stress harness in the app behind env hooks (mock-only):
   - `DCNATIVE_STRESS=<n>` seeds a synthetic chat with n messages
     (mixed lengths, links, a few images — realistic bubble variety).
   - `DCNATIVE_STRESS_CONTAINER=eager|lazy|list|table` renders the SAME
     `MessageListEntry` array + `MessageBubbleView` rows in the chosen
     container, isolated from window management (harness holds the full
     array).
   - Instrumented: scroll-geometry callback cadence under a scripted
     programmatic sweep (bottom → top → bottom) logged as frame gaps;
     plus time-to-first-frame after container creation (the switch cost).
2. Candidates:
   - eager VStack (current, baseline)
   - LazyVStack + full macOS-15+ anchor-role stack
   - SwiftUI List
   - minimal NSTableView representable (recycled NSHostingView rows)
3. Correctness gauntlet per candidate, driven in the lume VM via
   cua-driver: open lands at bottom; append follows at bottom; scrolled-up
   position survives append; prepend (loadOlder) preserves reading
   position; tall-item open not blank.
4. Verdict table in this issue; the winner gets its own port issue.

## Results (2026-07-21, phase 1: numbers)

Sweep = bottom→top→bottom, stride 8, 100ms steps, hitch = gap > 34ms
between scroll-geometry callbacks. Same corpus, same bubbles, same
machine (dev host, debug build):

| container | n=200 hitches | n=1000 hitches | n=1000 maxGapMs | n=1000 sweepMs |
|---|---|---|---|---|
| eager (current) | 12 | 589 | 385 | 56055 (stalls: 2x nominal) |
| lazy | 7 | 171 | 125 | 35675 |
| list | 1 | 7 | 94 | 27172 (nominal) |
| table (probe) | n/a* | n/a* | 216 | 29379 (nominal) |

*table swept via instant scrollRowToVisible (no animation): per-frame
numbers not comparable; nominal-time completion = no stalls.

Reading: eager collapses at n=1000 (matches user reports); List is
near-perfect and is NSTableView underneath — the custom-AppKit endpoint
with Apple maintaining the wrapper. Phase 2: correctness gauntlet on List
(primary) vs eager (control) in the real chat view behind a container
env switch, driven in the lume VM. The custom table stays the fallback
if List fails a gauntlet behavior.

## Acceptance Criteria

- Numbers for all four candidates at n=200 and n=1000 on the same
  machine, plus pass/fail on the five correctness behaviors.
- Recommendation written up with the data; user picks the port.

## Notes

- Window caps from overnight-window-bloat stay regardless: no container
  makes an unbounded window free.
- Sources reviewed 2026-07-21: Apple forums threads on List/LazyVStack
  jitter and pagination jumps; Stream SwiftUI SDK writeup; TGUIKit
  TableView (custom NSTableView) as the Telegram reference.
