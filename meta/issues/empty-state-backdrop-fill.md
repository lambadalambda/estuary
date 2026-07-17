# Empty state: tiled backdrop only covers the placeholder box

## Summary

On the "No Chat Selected" screen the ChatBackdrop renders as a small
rectangle behind the ContentUnavailableView instead of filling the detail
pane — the Group carrying `.background(ChatBackdrop())` hugs its content.

## Requirements

- The detail pane's empty state shows the tiled surface edge to edge.

## Acceptance Criteria

- User confirms the first screen is fully tiled (visual; untestable).
