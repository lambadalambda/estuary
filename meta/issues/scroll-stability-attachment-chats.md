# Scroll stability in attachment-heavy chats

## Summary

Bottom-pinning still fails: new messages sometimes don't scroll down (or don't keep
the scrolled-down state), especially in chats with many attachments; scrollbar
position can end up seemingly random. Suspected root: LazyVStack estimates heights
for unrealized cells; realized media bubbles change content height and the anchor
math drifts.

## Requirements

- Deterministic behavior: at-bottom stays at bottom through incoming messages and
  media loads; scrolled-up positions never move; chat switch lands exactly at bottom.
- Must hold with 100+ attachment bubbles in the window.

## Acceptance Criteria

- User cannot reproduce the drift in real attachment-heavy chats.
- Any new pure logic covered by tests (scroll feel itself is untestable — AGENTS.md).
