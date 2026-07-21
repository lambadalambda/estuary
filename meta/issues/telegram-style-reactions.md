# Telegram-style reaction pills: in-bubble, reactor avatars

## Summary

Reactions currently render as emoji+count chips dangling BELOW the bubble.
Adopt the Telegram presentation (user-provided reference screenshot,
2026-07-21): pills integrated inside the bubble's content flow with
comfortable spacing; each pill shows the emoji plus small overlapping
avatar bubbles of the reactors instead of a bare count; the pill is
accent-filled when the user has reacted themselves.

Telegram implementation notes (ChatReactionsView.swift, read 2026-07-21):
avatars REPLACE the count whenever reactor identities are available (count
text only as fallback); ~18-20pt avatars advancing 12pt per extra reactor
(overlap); capsule with ~10pt outer / 5pt inner insets; selected state
uses the accent fill with light text.

## Plan

1. dcvm: `ReactionItem` gains `reactors: Vec<ReactionContact>`
   (`name`, `color`, `avatar_path?`), populated from core's per-emoji
   contacts, capped at 3 (the display cap; `count` keeps the full number).
   Offline TDD via self-reactions. Exported-API change: regen bindings,
   update ChatService protocol + CoreChatService + MockChatService
   together (checksum rule).
2. Mock: showcase both variants — a pill with ≤3 reactors (avatars,
   including a self-reaction for the accent state) and one with >3
   (count fallback).
3. UI: pills move INSIDE the bubble card (bottom-leading, under content,
   clear of the timestamp overlay); avatars via ChatAvatarView (initials
   circles when no image) overlapping at 12pt steps; accent fill +
   light text when isFromSelf; existing toggle-on-click behavior kept.

## Acceptance Criteria

- Rust offline test: reactions carry reactor identities (self-reaction
  case); cap at 3 reactors with count intact.
- Swift tests: mock reactions expose reactors; suite green.
- VM screenshots: avatar pill inside bubble (incoming + outgoing/self
  accent variant), count fallback for >3, no timestamp collision.
- User confirms the look against the Telegram reference.
