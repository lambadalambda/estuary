# Close UI gaps: media, reactions, and chat management

## Summary

The prototype UI renders text-only chats while core already syncs everything.
Close the gap to a usable daily-driver client (webxdc excluded, see its own issue).

## Requirements

- Message bubbles render by kind: images/gif/sticker inline, audio/voice with playback,
  video/file as openable rows with name+size; captions under media.
- Quotes/replies: quoted block display + reply-compose via context menu.
- Reactions: chip row per message, toggle own reaction, react via context menu.
- Message context menu: copy, reply, react, forward (chat picker), delete (confirm).
- Composer: attach files (picker + drag&drop onto the chat).
- Contact requests: Accept / Block instead of composer.
- Chat list: real avatars, search, archived chats view, archive/unarchive, group creation.
- Settings sheet: display name, self-avatar, address, connectivity indicator.
- Read sync: mark_seen on visible incoming messages (MDN + cross-device read state).
- Notifications for incoming messages when unfocused (bundle build only).
- dcvm exposes all of the above over UniFFI with offline tests.

## Acceptance Criteria

- All dcvm offline tests green (existing 16 + new coverage for each new method).
- `swift build` green; mock-mode launch shows media/reactions/quotes seed data.
- Real-core smoke run works; features verified against demo account where possible.

## Notes

- In progress: parallel build (Rust FFI agent + SwiftUI agent), fixed contract, then integration.
- Voice message *recording* is out of scope here (playback only).
