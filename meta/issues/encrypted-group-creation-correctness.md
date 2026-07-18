# Encrypted group member discovery and safe creation

## Summary

The group picker and the encrypted-group API currently disagree about which
contacts are eligible. `contacts()` passes `DC_GCL_ADDRESS` (app.rs:711-713),
which core v2.53 defines as address-contacts *instead of* key-contacts, while
`create_group()` creates an encrypted group whose members must be key-contacts.
The wrapper also creates and syncs the group before adding members, so a later
member failure leaves an empty or partially populated group behind.

## Requirements

- Make the group-member API return eligible key-contacts. Do not silently
  replace address-contact discovery needed by New Chat; split the APIs if the
  two callers need different contact sets.
- Validate every requested member before creating the group.
- Guarantee that a failed `create_group` call leaves no local orphan or partial
  group. Prevalidate predictable failures before creation and clean up an
  unexpected post-creation failure.
- Keep the mock aligned with the real eligibility and failure semantics.

## Acceptance Criteria

- An offline integration test establishes a key-contact, proves it appears in
  the member picker API, and creates a non-empty encrypted group successfully.
- Address-only contacts are either absent from the group picker or rejected
  before group creation with a clear error.
- A deterministic failed-member test proves no matching group or partial
  membership remains afterward.
- A scripted/fault-injected failure after core creates the chat proves local
  rollback, or the inability to inject that core failure is documented and
  the cleanup branch is covered at the smallest extracted unit boundary.
- `cargo test` and `swift test` are green; bindings and Swift are rebuilt if
  the FFI contact API changes.

## Notes

- Verified against core v2.53 `Contact::get_all`: list flags `0` select
  key-contacts; `DC_GCL_ADDRESS` selects contacts with an empty fingerprint.
- Core `create_group` inserts the chat, emits events/start messages, and queues
  a sync action before `add_contact_to_chat` is called by dcvm.
- Wrapper rollback cannot make an already-queued multi-device create action
  unobservable. If prevalidation cannot eliminate all practical member-add
  failures, true cross-device atomicity requires an upstream core API that
  accepts validated members before emitting/syncing creation.
