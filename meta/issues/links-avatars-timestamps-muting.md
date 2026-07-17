# Links, in-chat avatars, human timestamps, full muting

## Summary

Messenger basics: clickable links in messages, sender avatars next to bubbles in
groups, relative timestamps ("5 min") in the chat list, and complete mute support.

## Requirements

- URLs in message text open in the browser (detected, styled as links).
- Incoming group messages show the sender's avatar beside the bubble.
- Chat list timestamps: now / N min / HH:mm / Yesterday / weekday / date, refreshing
  over time.
- Mute/unmute from the chat context menu (FFI set_chat_muted); muted chats show a
  gray unread badge, play no sound, and post no notifications.

## Acceptance Criteria

- Offline test covers mute round trip; builds green; user confirms.
