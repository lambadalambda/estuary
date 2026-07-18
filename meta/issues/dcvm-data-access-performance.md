# dcvm data-access performance and real pagination

## Summary

The UI limits message enrichment to a page, but `messages()` first calls
core's `get_chat_msgs`, which scans and sorts every message in the chat before
dcvm truncates the IDs (app.rs:467-489). Point chat lookup similarly scans the
whole history to find one last message, and message enrichment repeatedly
loads the same contacts and avatars within a page.

## Requirements

- Replace `chat_by_id`'s full-history scan (app.rs:395-403) with core v2.53's
  indexed `chatlist::get_last_message_for_chat`, deliberately matching
  Chatlist semantics by including an outgoing draft in the preview.
- Distinguish a genuinely deleted/missing chat from database or decoding
  errors; `chat_by_id` must not convert every load failure into `None`.
- Add a request-scoped sender/quoted-contact enrichment cache for message
  pages and search results; avoid repeated profile-image/configuration reads
  for the same contact.
- Use core's reaction aggregation/order helpers where they replace the current
  repeated linear aggregation without changing the FFI result semantics.
- Profile representative large chats, then add a stable cursor-based core API
  or an equally deliberate indexed query so fetching 50 messages does not scan
  and sort the entire history.
- Keep output ordering and deleted-anchor behavior covered by tests.

## Acceptance Criteria

- `chat_by_id` performs a bounded last-message query and still returns the
  same timestamp, unread, and mute behavior, with draft previews matching the
  main Chatlist.
- Point-lookup tests distinguish a missing chat (`Ok(None)`) from an injected
  chat-loader/database failure (`Err`); if core cannot inject that failure,
  cover the extracted error classifier and document the integration gap.
- A repeatable large-chat benchmark or query instrumentation demonstrates
  that page fetch work is bounded by page size rather than total history.
- Message pagination, deletion-anchor, search, quote, reaction, and avatar
  tests remain green.

## Notes

- The existing cheap-rendering issue tracks SwiftUI work only; this issue is
  the data-access half of deep-history performance.
- Bounded-concurrent chat/contact row enrichment may help, but should be
  profiled after removing the known whole-history and repeated-contact work.
