# Cheap rendering performance wins

## Summary

Review (2026-07-18) confirmed the structural re-render problem the DEVLOG
already suspected, plus three near-free wins. Today every composer keystroke
invalidates the whole ChatDetailView body (it reads `draft` via the composer),
re-running `buildMessageListEntries` (O(window) date math) and re-evaluating
every bubble — MessageBubbleView cannot synthesize Equatable because it stores
the model and closures.

## Requirements

- Isolate composer-owned draft state in a child view so keystrokes do not
  invalidate the parent message-list subtree. Extract a `MessageListView` and
  give it stable action routing/equality; memoize entry assembly (compute in
  AppModel when `messages` is set, or cache keyed on the array) instead of
  running it in `body` (ChatDetailView.swift:46).
- Share one `NSDataDetector` as a `static let` (Formatting.swift:73,127,144)
  — constructed fresh per bubble per render; measured ~7.5x cheaper reused;
  documented thread-safe.
- Route avatars through the existing ImageCache (MainView.swift:253) instead
  of uncached `NSImage(contentsOfFile:)` per row render.
- Debounce sidebar search (~250 ms) — currently one FFI query per keystroke.

## Acceptance Criteria

- No behavior change; `swift test` green (entry assembly is already pure and
  unit-tested — keep it that way after the move).
- A debug body-count/signpost test or Instruments trace shows composer
  keystrokes do not re-evaluate `MessageListView` or its existing bubbles.
- Scroll a grown window + type in the composer: visibly smoother, with the
  per-keystroke entry-assembly cost absent from an Instruments trace.

## Notes

- Deliberately out of scope (bigger, tracked elsewhere): capping the grown
  window + hoisting per-bubble TimelineView (see native-feel-polish notes /
  deep-window profiling); image downsampling on cache insert; dcvm per-page
  contact cache (message_item costs ~4-8 core calls per message,
  app.rs:135-203).
- `MessageBubbleView` cannot synthesize `Equatable` because it stores model and
  closures. Manual equality is useful only if callback/action identity is
  deliberately stable; do not ignore semantically changing closures.

## Progress (2026-07-18)

- One shared immutable `NSDataDetector` now serves all link helpers.
- Sidebar avatars use the existing decoded image cache.
- Sidebar search is debounced by 250 ms; explicit flush and suspended-service
  tests prove a rapid three-character edit performs one query and an old
  canceled `A→B→A` request cannot overwrite the newest identical query.
- Swift: 56 passed.
- Still open: isolate composer invalidation from the message subtree and
  memoize entry assembly, with body-count/Instruments verification.
