# Chat chrome polish: sidebar scrollbar, composer alignment + shape

## Summary

Screenshot review (2026-07-17) found three chrome-level rough edges:

1. The chat list (sidebar) still shows the always-on legacy scrollbar; the
   message list already fades its scroller via `OverlayScrollers`.
2. In the composer, the placeholder text is not vertically centered with the
   paperclip icon (hand-tuned `.padding(.bottom, 2)` on the buttons).
3. The chat list sits in a rounded container while the composer is a square
   full-width bar — the shapes clash.

## Requirements

- Sidebar list uses overlay (fade-out) scrollers like the message list.
  `OverlayScrollers` must find a `List`'s scroll view even though a
  `.background` anchor is a sibling of it, not a descendant.
- Composer icons align with the text baseline (no magic paddings), and stay
  anchored to the last line when the field grows to multiple lines.
- Composer becomes a rounded floating input card (bubble corner radius,
  incoming-bubble surface) over the tiled chat backdrop; reply banner and the
  contact-request Accept/Block bar get the same treatment.

## Acceptance Criteria

- Swift unit tests cover `OverlayScrollers.apply` for both hierarchy shapes
  (anchor inside the scroll view, anchor as sibling of it).
- User confirms in light+dark screenshots: sidebar scroller fades, placeholder
  centered with the icon, composer shape no longer clashes.

## Notes

- Baseline alignment and the floating-card look are visual — eyeball-verified
  by the user, declared untestable per project rules.

## Outcome (2026-07-17)

Done and user-confirmed ("nice, looks great"): sidebar scroller fades
(OverlayScrollers window-sweep redesign, unit-tested for both hierarchy
shapes), composer icons baseline-aligned, floating rounded composer card
over the tiled backdrop. New light/dark captures installed on the site.
