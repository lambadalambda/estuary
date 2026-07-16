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
