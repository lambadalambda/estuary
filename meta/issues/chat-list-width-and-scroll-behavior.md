# Chat list width + message loading/scroll behavior

## Summary

Four UX issues from first real-account use:
1. Sidebar too narrow by default — chat name/preview truncated next to the avatar.
2. Chats load ALL messages at once — slow for long histories.
3. Incoming messages make the view jumpy — should scroll fully down only when already
   at the bottom, otherwise keep position.
4. Selecting a chat animates a scroll to the newest message — should snap instantly.

## Requirements

- Wider default/min sidebar width.
- Paginated message loading: newest ~100 first, older pages fetched when the user
  scrolls near the top (scroll position preserved when prepending).
- Bottom-follow only when already at bottom; position preserved otherwise.
- Chat switch: instant snap to newest, no animation.

## Acceptance Criteria

- dcvm messages API supports (limit, before_msg_id); offline tests cover pagination.
- Builds green; user confirms scrolling feels right on the real account.
