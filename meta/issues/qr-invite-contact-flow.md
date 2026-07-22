# QR invite contact flow (first contact on chatmail)

## Summary

Chatmail relays reject unencrypted outbound mail, so "new chat by e-mail address" cannot
reach anyone without prior key exchange. Real first contact works via securejoin QR
invites. The client needs both directions.

## Requirements

- Show my invite QR (`get_securejoin_qr`) + copyable invite link.
- Scan/paste another person's invite (`join_securejoin`) — reuse the existing camera
  scanner and QrKind classification (extend for openpgp4fpr QR kinds).
- Group invite QRs (`get_securejoin_qr` with chat id) later, same mechanics.

## Acceptance Criteria

- Two local-relay test accounts can establish first contact through the UI flow.
- Opt-in relay test covers securejoin via the dcvm API surface (core-level test exists
  already in the round-trip test).

## Notes

- Discovered while building the local relay round-trip test (see DEVLOG 2026-07-16).

## Resolution (2026-07-23)

Shipped end to end. dcvm exports securejoin_qr (core's shareable
i.delta.chat link) + join_securejoin; QrKind gained
AskVerifyContact/AskVerifyGroup. InviteSheet: my QR + copy link, join by
paste (live name preview) or the reused onboarding camera scanner.
Verified: offline cross-account classification test; the opt-in relay
round-trip rewired through the exported dcvm surface passed live against
the podman relay (3.35s securejoin handshake + encrypted message); full
UI flow driven in the VM against the mock. Residual: pixel-level UI on a
REAL relay wasn't driven (VM cannot reach the host-local relay); the
layers between UI and the relay-proven API are unit-tested. Group invite
GENERATION (get_securejoin_qr with chat id) remains future work per the
original notes; group invites are classified and joinable already.
