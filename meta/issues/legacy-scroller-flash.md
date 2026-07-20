# Legacy scrollbar flashes on chat switch

## Summary

With the chat-switch window cache, a newly created chat scroll view
(`.id(chat.id)` recreates it per switch) has content on its first frame —
and AppKit stamps new scroll views with the system-preferred scroller
style, so when that is legacy ("Always show scroll bars" / mouse attached)
the fat track draws for a frame before the OverlayScrollers sweep
re-styles it. All existing machinery is reactive; the race is structural.

## Approach

Stop losing the race: register `AppleShowScrollBars = "WhenScrolling"` in
the app's defaults (volatile, `UserDefaults.register` — never written to
disk, never touches the user's system pref) before any window exists.
`NSScroller.preferredScrollerStyle` then reports overlay app-wide and
every scroll view is born overlay. OverlayScrollers stays as
belt-and-braces for anything AppKit re-stamps at runtime.

## Acceptance Criteria

- Unit test: after registration, the app defaults report "WhenScrolling"
  and `NSScroller.preferredScrollerStyle` is `.overlay`.
- Full suite green; AUTOSEND probe unchanged.
- User confirms the flash is gone when switching chats on a machine whose
  system pref would otherwise show legacy bars.

## Notes

- Defaults search order caveat: NSGlobalDomain outranks the registration
  domain, so a user who EXPLICITLY chose "Always show scroll bars" in
  System Settings still beats the volatile registration — for that case
  the reactive OverlayScrollers sweep remains the (flash-prone) fallback.
  The common legacy trigger — "Automatic" plus a mouse — has no explicit
  global entry, so registration wins there (unit-verified on the dev
  machine, which reproduces the flash). Escalating to the argument domain
  would win unconditionally but overrides a deliberate accessibility
  choice; deliberately not done.
