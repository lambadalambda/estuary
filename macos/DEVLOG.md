
## 2026-07-17 — Review follow-ups: link cursor, message timestamps, timed mutes

- Hand cursor over link-bearing bubble text (pointerStyle(.link); SwiftUI has no
  per-range pointer — link-free text inherits the normal cursor, caught in the new
  pre-commit review).
- Message footers now use the same fresh-relative format as the chat list ("now",
  "5 min", then clock time), refreshing every minute.
- Mute durations: FFI takes seconds (0 unmute / negative forever / positive timed via
  MuteDuration::Until); menu offers 1 h / 8 h / 1 week / forever.
- Process: a code-review pass now precedes every commit.
