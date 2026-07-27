# Persist transcripts across chat switches and restarts

## Summary

Transcripts vanish when leaving the chat (per-visit UI state; dcvm cache is
session-only). They should be saved permanently and reappear when the chat
is reopened, without re-running the engine.

## Requirements

- dcvm: durable per-account transcript store under the data dir (atomic
  writes, tolerant of missing/corrupt files). `transcribe_message` reads
  through it and persists successes.
- `MessageItem` gains `transcript: Option<String>` populated from the store
  so reopening a chat shows saved transcripts with no extra round trips.
- Swift: audio bubble renders the saved transcript when no in-flight local
  state exists; row heights measured consistently.
- Mock mirrors the semantics (transcript survives chat switch in mock mode).

## Acceptance Criteria

- vm.rs: transcribe → drop DcApp → reopen same data dir → message item
  carries the transcript AND transcribe_message returns it without invoking
  the engine.
- Store unit tests: round-trip, corrupt file tolerated.
- Real/mock app: transcript reappears when returning to the chat.

## Notes

- User feedback 2026-07-27.
