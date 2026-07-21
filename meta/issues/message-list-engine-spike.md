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

## Results (2026-07-21, phase 2: List correctness gauntlet, lume VM)

Real MessageListView behind DCNATIVE_LIST_CONTAINER=list, mock account,
DCNATIVE_SEED=120 into a 1:1 chat, driven via cua-driver:

- Open-at-bottom (long chat): **FAIL** — fresh open parks at the TOP of
  the loaded window (screenshot: Echo seed 19–30 visible, newest 120
  offscreen), with the loadOlder spinner visible and firing pointless
  history loads. Both explicit scrollTo attempts (.task(id:) and
  first-assembly onChange) fired before List materialized rows: no-ops.
- Follow-on-append: **FAIL under churn** — 2 follow events across 120
  seeds (eager fires continuously); the first scrollTo never landed, the
  sentinel scrolled out, viewIsAtBottom went false, and the model
  correctly stopped following. ScrollViewReader.scrollTo is unreliable
  against List's row virtualization at open/append time.
- Short chat open (fits viewport): pass, trivially.
- Scrolled-up stability / prepend-restore: not reached — blocked on the
  two failures above.

Verdict: List = excellent raw scrolling (phase 1) but unreliable
programmatic scroll through SwiftUI's wrapper — fixable only with the
retry/timing-hack pattern this spike exists to escape. The eager VStack
is the mirror image (correct control, collapsing perf). The NSTableView
representable is the only candidate with BOTH: nominal-time sweeps in
phase 1 AND deterministic, immediate scroll control (scrollRowToVisible
is synchronous AppKit, no materialization races).

## Recommendation

Port the message list to an NSTableView-backed representable: SwiftUI
bubbles in recycled NSHostingView rows, model layer unchanged (the
followBottomGeneration/loadOlder/sentinel contract maps 1:1 to explicit
AppKit calls we own). The spike harness's table probe is the skeleton;
the port issue should cover row-height caching, prepend scroll-position
restore via documentVisibleRect math, and the five-behavior gauntlet as
its acceptance gate.

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

## Outcome (2026-07-21)

Spike complete: phase-1 numbers + phase-2 gauntlet drove the port
decision; the port shipped, passed 5/5, and the user confirmed feel.
Archived together with appkit-message-table-port.
