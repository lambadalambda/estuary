# Image attachments can't be pasted into the composer

## Summary

Cmd+V with an image on the pasteboard does nothing in the compose field
(user report 2026-07-22). Pasting an image (screenshot, copied from a
browser, Copy Media from our own menu) should attach it.

## Requirements

- Paste with image data (or an image file URL) on the pasteboard stages
  the image as an attachment; text paste keeps working unchanged.
- Pasted bitmap data is written to a temp file for the send path.

## Acceptance Criteria

- VM: copy an image, Cmd+V in the composer, image is staged (or sent
  with caption once staging exists); plain-text paste unaffected.

## Notes

- Depends on [attachment staging](attachment-staging-in-composer.md) —
  without it a paste would have to send immediately, repeating the bug
  that issue removes.
