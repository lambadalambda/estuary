# Attachments send immediately instead of staging in the composer

## Summary

Dropping a file on the chat or picking one via the attach button sends
it right away (user report 2026-07-22). Expected: the attachment stages
in the composer — visible as a preview chip/thumbnail next to the text
field — and only goes out when the user hits send, optionally with the
typed text as caption.

## Requirements

- Drop and attach-button both stage instead of sending.
- Staged attachment shows a preview (thumbnail for images, name+icon for
  files) with a remove control.
- Send transmits attachment + composer text as caption in one message;
  the existing reply state applies to it.
- Staged state clears on send/remove and survives chat-switch sanely
  (either per-chat like drafts or cleared — decide and document).

## Acceptance Criteria

- VM: drop → nothing sent; preview visible; send → one message with
  caption; remove → nothing sent.
- Model-side staging logic unit-tested (mirrors the drafts mechanism).

## Notes

- Prerequisite for [image paste](composer-image-paste.md), which needs
  somewhere for the pasted image to land before sending.
