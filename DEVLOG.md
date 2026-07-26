# DEVLOG

## 2026-07-23 — Group invites; encrypted-group issue closed

Audit confirmed the 2026-07-18 group-creation fixes in the tree (picker
is key-contacts-only, members prevalidated before core creates/syncs,
orphan cleanup, offline coverage). The missing half was invite
GENERATION: securejoin_qr now takes an optional chat id (core's
get_securejoin_qr(Some(chat)) — the receiving side shipped with the
contact-invite work), the sidebar's group context menu gets "Group
Invite…", and InviteSheet gained a group mode (invite-only, no join
section). Review kept the mock honest: own group invites are rejected
like core's withdraw classification, joins are idempotent, and 1:1 chat
ids refuse to mint group links; all pinned by a mock-semantics test.
Residuals documented in the issue, both upstream-blocked: the
post-creation rollback branch has no fault-injection seam in core, and
cross-device create atomicity needs a core API.

## 2026-07-23 — QR invite contact flow (securejoin end to end)

First contact on chatmail relays now works: securejoin invites in both
directions. Nice discovery: core v2.53's get_securejoin_qr already
returns the shareable https://i.delta.chat/# link — one string serves as
QR content AND copyable invite. dcvm exports securejoin_qr /
join_securejoin and QrKind gained AskVerifyContact (display name
resolved in check_qr — the pure map_qr can't do contact lookups) and
AskVerifyGroup. The InviteSheet shows my QR (CIQRCodeGenerator, rendered
interpolation-free) + copy link, and joins via paste (with a live "Chat
with <name>" preview through check_qr) or the reused onboarding camera
scanner. Verified: offline cross-account classification test; the
opt-in relay round-trip rewired through the exported API passed live
against the podman chatmail relay (3.35s handshake + encrypted
round-trip); full UI flow driven in the VM against the mock. Camera
scan path shares the proven onboarding scanner but is not
VM-verifiable (no camera).

## 2026-07-22 — Composer attachment staging + image paste

Attachments no longer send on drop/pick: they stage per conversation
(drafts-style dict), render as a chip with remove control, and go out on
explicit send with the draft as caption. Review caught two real traps
before commit: async drop-provider callbacks must stage into the
DROP-TARGET chat (keying on read-at-callback selection misdirects a slow
iCloud/file-promise drop after a chat switch), and contact-request chats
must refuse stages (no composer chip → invisible time bomb that ships on
Accept). Paste finding worth remembering: **onPasteCommand never fires
while a TextField is focused** — the field editor wins and pastes a file
URL as literal text. The working shape is an NSEvent local keyDown
monitor gated on a model-mirrored composer-focus flag (FocusState can't
be read from monitor closures), with Caps-Lock-tolerant flag matching
and a keyCode fallback for non-Latin layouts. Pasted bitmaps normalize
to PNG in tmp/EstuaryPasted (reclaimed on replace/remove; sent files
left for the OS tmp purge — the mock renders from the original path).
Known v1 trade-off: PNG encode of a huge pasted screenshot runs
synchronously in the keypress (the swallow decision must be sync).
Monitor itself is the untestable AppKit sliver; VM-verified both ways
(focused paste stages, unfocused passes through). Everything else is
unit-tested at the model seam.

## 2026-07-22 — Pill hover affordance; reply banner un-ballooned

Reaction pills got a hand cursor + hover tint (Color.primary wash works
on all four fill/appearance combos); review caught that a pill vanishing
mid-hover (removing your own last reaction, row recycling) leaks the
pushed NSCursor — onDisappear pops it. Reply banner filling half the
window was the greedy-accent-bar family again: the bar made the composer
accept any height and the chat VStack split the window between two
greedy children; fixedSize(vertical:) on the banner pins it. Rule of
thumb recorded: any decorative Shape given only a width constraint
poisons ancestor sizing wherever the proposal isn't content-driven —
third instance (bubble quote, height measurement, composer banner).
Filed from the same user report: composer attachment staging (drop/
attach currently send immediately) and image paste, staged as dependent
issues.

## 2026-07-22 — One-line bubbles: row measurement fixed; real Show more

User report: long plain messages cut to one line + "…", clicking reflowed
text outside the bubble. Root cause was the table's height primitive:
NSHostingView.fittingSize returns SwiftUI Text's IDEAL (single-line) size,
not height-at-width — broken since the AppKit port for any wrapping plain
message; never seen because demo texts were short and link-bearing
messages measure correctly through LinkText.sizeThatFits (VM A/B test
pinned it: plain=collapsed, linked=fine). First fix — NSHostingController
sizeThatFits proposing (width, ∞) — swapped the bug for giant bubbles:
greedy views (quote accent bar) expand into any proposed height. Final
form pins content with .frame(width:) + .fixedSize(vertical:) so Text
reports wrapped height while decorations keep their ideal; both failure
modes are regression tests now. On top: >5000-char messages collapse at a
whitespace boundary with an explicit Show more/Show less (pure
longMessageDisplay, tested), expansion state on AppModel (cleared on chat
switch), and ChatTableView re-keys the row height per expansion and
re-pins the bottom. Untestable-by-unit and covered in the VM instead:
the actual row resize on toggle and the scroll re-pin.

## 2026-07-21 — Telegram-style message context menu

Menu composition is a pure descriptor (messageContextMenuEntries /
reactedSummary, unit-tested) rendered by the view: quick-reaction palette
on top (ControlGroup .palette), then Reply / Copy Text / Copy Media /
Save As… / Quick Look / Open in App, Forward…, "N Reacted" submenu
(reactor avatar + name + their emoji, "and N more" past the identity
cap), red Delete. The old React submenu + Remove Reaction item are
subsumed by the palette's toggle semantics (self emoji shows a baked-in
selection circle; a self reaction outside the defaults is appended).
Findings: palette items render their ICON only — text labels come out as
empty slots, so emojis (and the selection circle — tint can't touch
non-template images) are rasterized via ImageRenderer, same trick as the
reactor-avatar menu icons. Right-clicking the message TEXT still yields
the system text-selection menu (textSelection(.enabled) wins there);
rest of the bubble gets ours — same trade-off Telegram avoids by owning
text views, noted as acceptable for now. VM QA: SwiftUI context menus
never open from pid-targeted synthetic right-clicks — only desktop-scope
HID events pop them (AppKit's field-editor menu opens either way).
Visually verified in the VM: capped 👍5 group menu, full-identity
3-Reacted submenu, appended+selected 🌅, media rows, live palette toggle
honoring one-reaction-per-user replacement.

## 2026-07-21 — Telegram-style reaction pills (in-bubble, reactor avatars)

Reference: user's Telegram screenshot + ChatReactionsView.swift source
read. dcvm ReactionItem carries up to three reactor identities
(name/color/avatar, riding the message-page sender caches; count keeps
the full number) — exported-API change, bindings regenerated, ChatService
protocol + Core + Mock updated together. Pills moved inside the bubble
card above the timestamp line: emoji + overlapping 18pt avatar bubbles
(ring = pill fill) when identities cover every reactor, count fallback
past the cap; accent fill for own reactions, white-opacity fills on the
teal outgoing surface. Mock showcases both variants; VM screenshots
verified both + AUTOSEND probe green. Rust offline test pins reactor
identity on self-reactions.

## 2026-07-21 — AppKit message table ported, gauntleted, flipped to default

ChatTableView: NSTableView + recycled NSHostingView bubbles, exact
per-(entry,width) height cache, updates classified by the pure
entriesTransition (surgical row edits; ambiguity → reload + anchor
restore). Every scroll behavior is now an explicit synchronous AppKit
call: bottom-pin via setBoundsOrigin, at-bottom derived from
documentVisibleRect (the 1px sentinel and its visibility races are gone
from the table path), loadOlder from viewport-top proximity, prepend
restore via saved anchor row + offset, MDN from the visible row range.
Five-behavior gauntlet in the VM: all pass, including the two List
killed (open-at-bottom long chat, follow under churn) and the tall-item
open that used to blank the lazy stack. Default flipped to table;
eager remains an env rollback hatch until the user signs off, then the
SwiftUI containers get deleted.

## 2026-07-21 — List-engine spike phases 1+2: verdict is the AppKit table

Phase 1 (stress harness, same corpus/bubbles): eager collapses at n=1000
(589 hitches, 2x-nominal sweep — the user's choppiness, quantified);
LazyVStack mediocre (171); SwiftUI List near-perfect (7 hitches, nominal);
NSTableView probe nominal with instant precise jumps. Phase 2 (real
MessageListView behind DCNATIVE_LIST_CONTAINER=list, VM-driven): List
FAILS open-at-bottom on a long chat (parks at the top of the window,
loadOlder spinner firing) and follow-on-append under churn (2 follows per
120 seeds — the first scrollTo never lands against row virtualization,
the sentinel exits, the model correctly stops). Same lesson at a new
altitude: SwiftUI's wrappers scroll fast but won't take orders reliably;
the eager container takes orders but can't scroll fast. The NSTableView
representable demonstrated both. Recommendation recorded in the spike
issue: port to an AppKit-backed list, SwiftUI bubbles in recycled rows,
model contract unchanged.

## 2026-07-21 — Overnight window bloat bounded; list-engine spike agreed

Overnight-open chat went choppy, switch-back hung. Mechanism: passive
window growth (scrolled-up/stale sentinel + incoming traffic) never
shrinks, the eager VStack renders O(window), and the 07-20 window cache
removed the accidental relief valve (selection reset) by faithfully
restoring the bloated window. Bounded on three sides: at-bottom reloads
trim to one page, passive growth caps at 20 pages (explicit loadOlder
stays uncapped — user intent), and the cache stores only the newest page
(switch-back always lands at the bottom anyway). Found along the way: the
scripted test service ignored `limit`/`beforeMsgId` entirely — honest
pagination in the stub surfaced one test leaning on the old behavior.
User reports only ~90 overnight messages, so bloat alone may not explain
the severity — and live deep-scroll is slow at a few hundred items
regardless. Research says our container pattern is the CURRENT Apple
recommendation with exactly our failure modes documented; serious chat
apps sit on custom AppKit/UIKit lists. Decision (user): measured spike —
stress harness, four candidates (eager, modern LazyVStack, List,
NSTableView representable), numbers + correctness gauntlet before any
port (issue: message-list-engine-spike).

## 2026-07-20 — Viewed chat's unread badge climbed: stale fresh-count guard

Incoming-in-selected-chat did call markSelectedChatNoticed, but its
`freshCount > 0` guard reads the SIDEBAR row — refreshed by a debounced
reload scheduled by the same event, so it still says 0 at call time; the
marknoticed RPC never fired and the badge stuck until reselection. Fix:
`force: true` on the incoming path (the count is definitionally about to
rise); the guard stays for the other call sites. TDD: positive case red
first (marks noticed despite stale 0), negative cases pin that other
chats and inactive-app still accumulate. 103/103.

## 2026-07-20 — Chat-switch empty flash: per-conversation window cache

Side-by-side with Telegram-macOS (cloned, read): their switch never renders
an unready chat — navigation gates the swap on the ChatController's `ready`
promise (TGUIKit NavigationViewController.push) and Postbox serves the
initial window from an indexed store, so fetch-then-swap is imperceptible.
Estuary did the opposite: selection clears the window synchronously (the
anti-bleed guard) and awaits an FFI fetch that core serves by scanning the
whole history — a guaranteed, fetch-length empty frame. Fix: cache the last
loaded window per (account, chat) — a sibling of the drafts dict — and
restore it synchronously on selection (both in the didSet AND after
chatSelectionChanged's second reset, which was silently wiping the first
restore; the suspended-fetch test caught that). Cache writes on reload and
loadOlder, LRU-bounded at 16, cleared on account-scoped resets. Restored
data is same-conversation, so the stale-window growth check stays valid and
a restore cannot fire the bottom-follow (previousLast guard). 100/100
tests; AUTOSEND probe unchanged. First-ever opens still fetch — that tail
belongs to dcvm indexed pagination.

## 2026-07-20 — Send-scroll regression: sizeChanges anchor inert under eager VStack

User report: posting no longer follows to the bottom. Since 880af5f the ONLY
follow mechanism was `defaultScrollAnchor(.bottom, for: .sizeChanges)`; the
eager-VStack swap (de596ad) silently killed it — geo logs (new
DCNATIVE_AUTOSEND probe + DCNATIVE_DEBUG_SCROLL) show the offset frozen
through every append. First fix attempt (view-side onChange gated on
viewIsAtBottom) failed for a second, subtler reason: visibility callbacks
are post-layout, so the sentinel already reads "not at bottom" by decision
time. Landed fix: model-side `followBottomGeneration` captures the
pre-append sentinel state in `refreshMessageListEntries` (keyed on last
entry id — full-window slides keep the count constant); the view just
scrolls on the bump. Two new AppModel tests pin the trigger semantics;
98/98 green. Probe evidence before (offset 153 while content 800→6736) and
after (offset tracks bottom, probe ends atBottom=true). Lesson: every
scroll behavior riding on a SwiftUI default needs a probe-able invariant —
the pin died two days before anyone noticed.

## 2026-07-19 — Core objects now pinned to the app's macOS minimum

Local Rust builds compiled cc-crate C deps against the host OS (26.5) while
the app links and claims minos 15.0 — invisible in `verify-app` because the
final binary's load command says 15.0 regardless; only the archive members
tell the truth. Fix: `MACOSX_DEPLOYMENT_TARGET ?= 15.0` exported from the
Makefile plus `check-object-minos.sh` gating `app` packaging and `make
check` on every `libdcvm.a` member. Cargo gotcha: the env pin
re-fingerprints rustc compiles but not cached cc build-script outputs —
blake3's NEON object kept its 26.5 stamp until `cargo clean -p blake3`, and
only the new archive gate caught it. Zero ld min-version warnings now; the
rebuilt release app re-verified in the lume VM.

## 2026-07-18 — Nightly DMG trapped on every machine but the builder

First real-world install (lume VM via cua-driver) crashed at first render:
SwiftPM's generated `Bundle.module` accessor checks only the app-bundle ROOT
and the absolute build-scratch path baked at compile time
(`/Users/runner/...`). `make app` correctly puts the bundle in
Contents/Resources — which the accessor never looks at — and every dev
machine hid the bug because the local scratch dir satisfied the baked path.
Diagnosed by running the shipped binary over SSH (the fatalError prints both
candidates) and confirmed by symlinking the CI path inside the VM, after
which the same DMG ran fine. Fix: `AppResources.locate` — a pure,
candidate-ordered bundle search (main resourceURL, then bundleURL, then the
generated accessor for dev loops) with unit tests over temp-dir fixtures;
call sites use `AppResources.bundle`. Lesson for release checks: artifact
verification that runs on the build machine cannot catch baked-path rescues;
the VM install is the honest gate.

## 2026-07-18 — Immutable nightly inputs and artifact gates

Release checks are executable locally through `make verify-app` and
`make verify-dmg`: they compare plist and Mach-O minimum versions, require exact
numeric build/current-commit stamps and the host architecture, verify deep
codesigning and DMG integrity/layout, then hold a mock-mode launch alive for
three seconds. A stale pre-change app failed first; a fresh app passes all app
checks. Real DMG creation is not automatable in this restricted agent because
`hdiutil` reports that sandboxed `hdiejectd` cannot start, so the mount path
still needs a normal terminal or CI run.

Both workflows pin checkout and rust-cache by commit; nightly pins Xcode 16.4,
and the local chatmail relay pins its locally verified OCI digest. Nightly no
longer deletes the public release: it uploads a unique SHA-named asset, verifies
the downloaded SHA-256, retains previous assets, and advances release notes only
when the previous published commit is an ancestor. Its extracted state-machine
test covers non-main and mismatched checkouts, upload-then-fail recovery with a
non-byte-identical rebuild, API failure, and backward/unrelated publication.
Checkout does not persist the write token; only the final step receives it.
Required `main` branch protection is documented, but repository settings and
the first workflow run remain external verification steps.

## 2026-07-18 — Composer/list render isolation

The conversation screen now has separate Observation subtrees for
`MessageListView` and `ChatComposerView`; forwarding/Quick Look/history state is
owned by the list child, while draft/reply/file-picker state is owned by the
composer. AppModel memoizes pure `MessageListEntry` assembly whenever messages
or selected group metadata changes, replacing the O(window) build previously
performed in list `body`. A red/green assembly-counter test proves three draft
keystrokes trigger no additional entry builds; selection changes synchronously
invalidate the previous message/cache before rendering the new chat. Swift: 90
passed. The rendering issue remains open for an Instruments/body-signpost trace
of actual SwiftUI subtree evaluations and the manual grown-window typing check.

## 2026-07-18 — Visible-only MDNs + action isolation + honest mock IDs

TDD reproduced three remaining shell races: New Chat swallowed failures after
dismissing its sheet, stale group creation selected its result over a newer
chat, and a transient message reload blanked the valid window. New Chat now
matches New Group's result contract, both create paths use selection generations,
exit excluding search/archive filters, and point-cache the created row before
selection. Stale failures remain errors while stale successes cannot steal a
new selection. A chat-list request generation also prevents an older normal
reload from erasing a newly created/selected row. Reload failure preserves
rendered content. Suspended create/group,
attachment, and mark-noticed tests pin completion isolation; failed attachment
sends retain captions. Security-scoped file/avatar access now stays active for
the entire async core call (structural verification only; sandbox/TCC prompts
are not automatable here). File-provider callbacks also carry their initiating
account/chat/caption/reply identity, so a delayed drop cannot retarget another
conversation.

Read receipts no longer mark the whole eager message window. Each bubble reports
actual scroll visibility with a captured account/chat/message key; AppModel
tracks the current visible set and selection epoch, rejects delayed cross-account
and stale-view callbacks, deduplicates successful requests, retries transient
failures with up to three attempts, and retries visible MDNs on activation. Finally,
MockChatService now
uses per-account chat/message counters and account+chat storage keys throughout;
two accounts deliberately share chat 10/message 1000 without delete/search
cross-talk; noticed and seen/fresh state remain distinct. Swift: 88 passed. The
AppModel issue remains open only because core
progress events have no flow generation to distinguish two onboarding attempts
that reuse one account; the leftovers issue remains open for the manual
second-device MDN confirmation.

## 2026-07-18 — Bounded events + exact notifications + global unread

TDD reproduced duplicate burst notifications: `IncomingMessage` carried a
`msgId`, but AppModel discarded it and reread the chat's final preview. dcvm now
exports exact `message_by_id` lookup; AppModel loads that message before a final
fresh mute/device-chat check, so two rapid messages retain distinct bodies and
a mute racing the lookup suppresses delivery. Bundled foreground notifications
install a retained banner+sound delegate for all accounts.

The unbounded Swift `AsyncStream` bridge is replaced by a hybrid channel:
incoming IDs use a bounded FIFO with callback backpressure, state events
coalesce by key in a separate bounded queue, state overflow owns an explicit
full-refresh slot, and dequeue is weighted so refresh cannot starve. Foreign
callbacks run on Tokio's blocking pool to avoid starving async RPC work. AppModel
chat/message/badge schedulers are dirty-bit single-flight loops, and transient
unread failures preserve the last badge. dcvm sums core `get_fresh_msgs()` across
configured accounts, making the Dock independent of account selection and
sidebar filters. The upstream core event channel can still overflow before this
bridge; current-state recovery is possible, but replaying exact dropped
notifications would need a durable core watermark API. Rust: 10 unit + 23
offline integration passed (2 relay ignored); Swift: 70 passed; strict
Clippy/rustfmt green.

## 2026-07-18 — Reproducible local checks + PR CI

The fresh-link failure reproduced earlier is fixed structurally: `make test`
depends on locked Rust build and UniFFI generation before Swift. A full run
passed 30 Rust tests (2 relay ignored) and 56 Swift tests. Regeneration exposed
that exported Rust doc comments change UniFFI checksums, so the previously
stale generated Swift binding is included. Cargo is locked throughout, Rust
1.97/rustfmt/Clippy is declared, and PR CI runs `make check`, lints, and a clean
binding diff. `make PROFILE=release run` and bindgen now stay entirely in the
release profile. App assembly uses numeric commit-count `CFBundleVersion`,
stores and displays the SHA separately, advertises macOS 15, and passes strict
code-sign verification. Full-history nightly checkout makes the count accurate
for ordinary `main` descendants, but rewrite/rerun-safe monotonic publication,
publication atomicity, immutable CI pins, DMG checks, and branch protection
remain open.

## 2026-07-18 — Three cheap rendering wins

A deterministic service-call test first showed three rapid sidebar edits
issuing three searches; the model now cancels and replaces a 250 ms debounce
task, producing one query. A search generation also rejects stale in-flight
results, including identical-text `A→B→A`; continuation gates avoid timing
sleeps in tests. Link helpers share one immutable NSDataDetector
instead of constructing it per bubble/render, and sidebar avatars now use the
existing decoded image cache. Swift: 56 passed. The rendering issue stays open
for composer/message-list invalidation isolation and memoized entry assembly,
which need body-count or Instruments verification.

## 2026-07-18 — SQL chat preview + page sender cache

TDD pinned `chat_by_id` draft semantics, then replaced its all-message Rust ID
allocation with core's SQL `get_last_message_for_chat` helper. This makes
previews agree with Chatlist drafts, but EXPLAIN still shows a temp sort without
a composite core index, so bounded lookup remains open. Message
pages/searches now cache each sender and quoted sender's name/color, plus
avatars only for actual message senders, instead of repeating reads per bubble.
Rust: 30 passed, 2 relay tests ignored; fmt and strict Clippy green. The data
performance issue remains open for the composite index, true cursor pagination,
reaction helper alignment, and missing-chat/error classification. Cache lookup
counts are not externally instrumentable; existing quote/avatar integration
coverage pins behavior while the optimization is structural.

## 2026-07-18 — dcvm correctness batch: four fixes green

Red tests caught the search cap selecting old hits in reverse display order,
WebM/Opus/HEIC being over-classified as inline media, and `i64::MAX` mute
duration panicking a runtime worker. Search now takes the newest 100 then
reverses for display, generic attachments follow core's conservative mapping,
and unrepresentable timed mutes become `Forever`. Overflow recovery snapshots account
IDs before foreign callbacks, releasing the manager read lock. Rustfmt was
applied, the stale `mut` warning removed, and strict Clippy is green. Rust: 30
passed, 2 relay tests ignored. The issue stays open only for the chatlist
snapshot/deletion race because core v2.53 exposes no optional Chat loader or
public existence query.

## 2026-07-18 — Account-scoped drafts and stale action guards

The AppModel harness next reproduced filtered search tearing down the selected
chat, out-of-order account switches selecting the older request in both UI and
core, and late send/block completions clearing state in a newly selected chat.
AppModel now caches the selected row independently of sidebar filters, stores
drafts by account/chat, reconciles stale account selections to the latest user
intent, and guards completion-side state writes by account/chat/reply identity.
The composer no longer clears text before send: successful sends clear only an
unchanged originating draft; failures and edits during suspension survive.
Progress events are account-scoped and mark-noticed requires the app to remain
active; core does not carry a same-account flow generation, so that narrower
progress hole remains open. A single reconciliation driver now handles
1→2→1, third-intent, and latest-failure account switching; pending sends are
deduplicated, and filtered selected rows refresh through `chatById`. The
broader isolation issue remains open for remaining action tests and production
mock ownership semantics. Swift: 54 passed.

## 2026-07-18 — AppModel tests + message-window serialization

The first direct AppModel suite uses a scripted actor service to stop requests
at exact suspension points. Red reproduced all three reviewed failures:
loadOlder followed by reload collapsed 100 messages back to 50 and disabled
history, a stale normal-list response overwrote Archive, and a demo account
with the same numeric chat id retained the previous profile's messages. Green:
message-window generations serialize reload/prepend mutations, archive mode is
snapshotted before fetch, and account transitions share a full scoped reset.
Additional tests pin reload/loadOlder chat-switch guards and prove a stale
failed reload cannot erase a newer prepend. Account removal now uses the same
scoped reset. Swift: 42 passed.
The message-window issue is archived; broader action/draft/progress isolation
remains open in `appmodel-state-isolation.md`.

## 2026-07-18 — Encrypted group discovery and safe creation

TDD exposed the group mismatch directly: dcvm listed address contacts while
core encrypted groups accept only key-contacts, and the existing create-then-
add loop left a committed orphan after rejection. The member API now lists
key-contacts, validates every member before core creates/syncs anything, and
deletes the new local chat if an unexpected add still fails. The offline test
imports a second account's keyed vCard, creates a non-empty encrypted group,
and pins both eligible discovery and no-orphan rejection. Rust: 28 passed, 2
relay tests ignored; Swift: 36 passed. Core has no fault-injection seam after
group creation, so that defensive rollback branch and true cross-device
atomicity remain explicitly unverified; the issue stays open.

## 2026-07-18 — Full-repo review findings filed

Delegated four parallel review passes (dcvm, Swift model/services, SwiftUI
views, build/CI), then verified the headline findings by hand against the code
and the pinned core checkout. Both suites green at review time (28 Rust tests
passed, 2 relay tests ignored; 36 Swift passed). Findings filed as issues:
dcvm-correctness-batch (search_messages
returns the oldest 100 hits newest-first — wrong window AND wrong order vs
its own doc + the mock; plus three one-line dcvm fixes),
message-window-race-appmodel-tests (reload/loadOlder interleaving clobbers a
grown window and wedges hasMoreMessages; AppModel has zero direct tests),
render-perf-easy-wins (keystroke → full message-list re-render confirmed;
static NSDataDetector; avatar ImageCache; search debounce),
review-leftovers-batch (make test missing bindings dep — fresh-clone broken;
Info.plist min 14.0 vs 15.0 build; window-wide read receipts; silent
createChat; security-scoped URL lifetime). Also learned: the nightly core pin
matches upstream v2.53.0 exactly; lockfile pins intact.

A follow-up verification pass added five focused issues that did not fit those
batches: encrypted-group member discovery + safe creation, cross-account and
stale-result AppModel isolation, dcvm data-access performance/real pagination,
notification delivery + event backpressure, and build/CI/release
reproducibility. It also corrected the chat-deletion-race note: core v2.53 has
no `Chat::load_from_db_optional`, so the eventual fix must distinguish a
missing row without suppressing real database/decoding failures. Additional
small findings were folded into the existing dcvm and review-leftovers batches.

## 2026-07-16 — Gap closing: media, reactions, chat management (issue: close-ui-gaps)

Built in-session after repeated 529 API overloads killed both delegated build agents
four times each (no work lost — they died during read phases; strict TDD was compressed
to tests-with-implementation under the circumstances).

**dcvm:** MessageKind/QuoteInfo/ReactionItem/ContactItem; MessageItem carries file
metadata + quote + aggregated reactions; ChatItem group/archive/device flags + avatar;
send_message (attachments by extension-guessed viewtype, quoted replies), send_reaction,
delete/forward/mark_seen, accept/block, archive + archived_chats, search (chats +
messages), contacts, create_group, display name/self-avatar, connectivity. 22 offline
tests green (9 unit + 13 integration).

**v2.49 semantics discovered:**
- `Contact::get_all` hides address-contacts unless `DC_GCL_ADDRESS` is passed.
- Encrypted groups reject address-contacts ("Only key-contacts can be added") — the
  group UI warns; proper fix arrives with the QR-invite contact flow issue.
- `prepare_msg_blob` demotes undecodable images to File — tests need a real PNG
  (tests/fixtures/1x1.png).

**macOS UI:** media bubbles (inline images/gif/sticker, audio/voice playback via a
shared AVAudioPlayer, file/video rows opening in Finder apps), quote blocks + reply
composing, reaction chips with own-reaction toggling, context menu (copy/reply/react/
forward-with-chat-picker/delete), paperclip + drag&drop attachments, Accept/Block
replacing the composer for contact requests, mark-seen on visible chats (read receipts
+ cross-device read sync), real avatars, sidebar search, archived-chats view +
archive/unarchive, group creation with member picker, profile settings sheet (name,
avatar, connectivity), incoming-message notifications (bundle builds only).

Webxdc rendering intentionally still out (own issue). Visual pass on the new UI is
pending the user; builds + smoke runs green.

## 2026-07-16 — Camera QR scanning + .app bundle

"Add Second Device" can now scan the QR live off the other device's screen:
AVCaptureSession → per-frame (throttled, queue-confined) CIDetector; first hit
auto-fills the payload and starts the join. No new dependencies.
TCC nuance: camera permission for a bare `swift run` binary gets attributed to the
terminal; `make run-app` builds a minimal ad-hoc-signed DeltaApp.app with
NSCameraUsageDescription so the prompt is properly attributed and persists.
Camera path is build-verified only in the agent session (no TCC interaction possible);
first real scan happens on the user's machine.

## 2026-07-16 — Local relay verified end-to-end; two hard-won findings

The podman chatmail relay works (amd64 image forced via `--platform`, runs under
Rosetta): `/new` POST, IMAP/SMTP with self-signed `_cm.example` certs, and both opt-in
tests green — instant account creation (~2 s) and a full encrypted message round trip
between two accounts (~1.5 s). The app onboards against it via
`DCNATIVE_INSTANCE=DCACCOUNT:_cm.example`.

Debugging the round trip surfaced two product-relevant core behaviors (details in
dev/chatmail/README.md):
1. **filtermail rejects unencrypted outbound** — first contact by bare address cannot
   deliver on chatmail; securejoin QR invites are the real flow (the test now does the
   handshake; the UI will need an invite/QR contact flow eventually).
2. **The first-scan race**: mail arriving during an account's initial post-configure
   inbox scan is classified as pre-existing and silently skipped. This produced a
   perfectly alternating test flake (fast runs beat the scan) — fixed by waiting for
   connectivity Connected (4000) before messaging a fresh account. Conceivably a real
   edge case for instant-onboarding flows, not just tests.
   Red herrings on the way: inotify limits (fine), maybe_network nudging (didn't help —
   the mail was fetched and *deliberately* skipped, not unseen).

Also: exported `maybe_network()` through the FFI; the app calls it when the scene
becomes active (wake from sleep → immediate fetch instead of next poll).

## 2026-07-16 — Local test infrastructure: offline second-device test + podman chatmail relay

**Second-device transfers need no server.** The DCBACKUP transfer is a direct iroh/QUIC
connection with `RelayMode::Disabled` — core's own tests run provider→joiner in one
process. `dcvm/tests/vm.rs` now covers the full happy path (demo account provides,
fresh account joins, chats + ImexProgress verified) in ~1.5 s offline. Gotcha: iroh QRs
advertise only LAN/VPN direct addresses, never loopback, and self-connect via the LAN IP
is blocked in the agent sandbox — the test rewrites `direct_addresses` to `127.0.0.1`,
which also makes it hermetic on any network.

**Local chatmail relay (dev/chatmail/):** official `ghcr.io/chatmail/docker:main` image
with `MAIL_DOMAIN=_cm.example`. Underscore domains are the officially anticipated local
mode: the server self-signs certs and skips DNS checks, and core v2.49 skips TLS
verification for `_`-hosts (src/net/tls.rs) — including the DCACCOUNT HTTPS POST, which
otherwise only trusts compiled-in webpki roots. `DCACCOUNT:<bare-domain>` skips HTTP
entirely (credentials invented locally, mailbox created on first login — what core's own
CI does against `CHATMAIL_DOMAIN`). Wired up: `DCNATIVE_INSTANCE` env in the app,
`DCVM_TEST_RELAY` + `#[ignore]`d `instant_account_against_local_relay` test.
**Unverified end-to-end:** the podman VM cannot boot in the agent session
(Virtualization.framework "Internal Virtualization error" regardless of memory/EFI
reset — environment restriction; UDP loopback works, VZ doesn't). Needs
`podman machine start` from a normal terminal, plus one-time
`127.0.0.1 _cm.example` in /etc/hosts (sudo). Image is amd64 → Rosetta on this host.

## 2026-07-16 — Project start

**Decision: shared Rust viewmodel + per-platform native shells, macOS first.**
Rationale: `deltachat-core-rust` already does all protocol/crypto/storage work, so a client is
~just a view layer. We put everything below the pixels into a Rust crate (`dcvm`) exposed via
UniFFI, and keep native shells thin and idiomatic. If per-platform maintenance proves too heavy,
the same crate serves a cross-platform Rust toolkit (Slint/Iced) instead — the architecture keeps
that reversal cheap.

**Decisions:**
- Depend on `deltachat` core crate directly (git tag `v2.49.0`, same as deltachat-desktop's Tauri
  target) — in-process, no JSON-RPC/IPC.
- UniFFI proc-macro style for Swift bindings.
- Prototype scope: classic email login, chat list, message list (text only), send text, live
  event-driven updates.
- Local core source for reference reading: the submodule checkout at
  `deltachat-ios/deltachat-ios/libraries/deltachat-core-rust`.

**Finding: fresh lockfile breaks the build.** With a fresh `Cargo.lock`, cargo resolves
`socket2 0.6.5`, which no longer compiles with the `netwatch 0.5.0` pinned by core v2.49.0
(E0277/E0599). Fix: mirror deltachat-desktop's known-good lock — `cargo update tokio@… --precise
1.48.0` then `socket2@… --precise 0.6.1` (newer tokio requires socket2 ^0.6.3, so tokio must be
downgraded first). `Cargo.lock` is committed for reproducibility.

**Environment notes:**
- No system Rust; installed rustup (Rust 1.97) into `~/.cargo` / `~/.rustup`.
- Swift 6.3.3 / xcodebuild on macOS 26, arm64.

## 2026-07-16 — dcvm implemented + Swift bindings generated

**Design:**
- Pure mapping layer (`src/mapping.rs`): core `EventType`/`MessageState`/`SummaryPrefix`/u32
  color → FFI types, all side-effect-free and unit-tested first (true red→green TDD). The async
  glue in `src/app.rs` only composes these. `DcApp` integration work used compile-fail as the red
  phase (tests written and run before `app.rs` existed).
- `DcApp` holds `Arc<tokio::sync::RwLock<Accounts>>` (rpc-server pattern). All core work — the
  event pump AND every method body — is bridged onto one global `LazyLock<Runtime>` via
  `RT.spawn(...)`, so core-internal `tokio::spawn`s land on the same long-lived runtime whether
  a call comes from Swift (UniFFI/async-compat) or a Rust test runtime.
- `selected_account()` must be sync per contract; a `std::sync::Mutex<Option<u32>>` cache
  (refreshed from `get_selected_account_id()` after every mutation) avoids blocking on the
  tokio RwLock from sync context.
- Event pump: one `EventEmitter` from the accounts manager; `map_event` drops noise (Info/
  Warning/etc.), listener errors are ignored, pump exits when the channel closes.
  `MsgsChanged`/`MsgDelivered`/`MsgRead`/`MsgFailed`/`MsgsNoticed`/`ChatlistItemChanged(Some)`
  all collapse to `ChatChanged { chat_id }` — the UI reloads the visible chat either way.

**Surprises / deviations from the specs:**
- **v2.49.0 gates `receive_imf` behind the `internals` feature** (2.44 spec said plain public).
  `internals = []` is cfg-only (no extra deps), so it's enabled unconditionally.
- **Adding uniffi to Cargo.toml silently re-resolved three lock edges**: hyper-util/quinn/
  quinn-udp flipped their socket2 dep 0.5.10 → 0.6.1. That dropped the `all` feature previously
  unified onto socket2 0.5.10, breaking netwatch's bsd.rs (E0599 `Type::RAW`). Fix: hand-flip
  those three edges back in `Cargo.lock`, verify with `cargo build --locked`. Moral: even
  "additive" manifest changes can re-resolve shared deps; check `git diff Cargo.lock`.
- `uniffi-bindgen-swift --modulemap` names the module after the *crate* (`dcvm`), ignoring
  `module_name` in uniffi.toml — pass `--module-name DeltaCoreFFI` explicitly (baked into the
  Makefile `bindings` target).
- Demo account (`add_demo_account`): pseudo-configure via `Config::ConfiguredAddr`, contacts
  created first so `receive_imf` messages land in normal chats (not contact requests), last
  incoming message per chat left unseen for unread badges, plus a "Saved Messages" note.

**State:** `cargo test` green (4 unit + 4 integration, all offline, no `start_io`). Bindings in
`macos/Sources/DeltaCore` + `DeltaCoreFFI` typecheck with `swiftc -swift-version 5`. Root
Makefile targets: `rust`, `bindings`, `run`, `test` (dev profile everywhere).

## 2026-07-16 — Swift/Rust integration: app runs against the real core

**Wiring:**
- `macos/Package.swift` grew the two generated targets per the recipe:
  `.systemLibrary(DeltaCoreFFI)` + `.target(DeltaCore, swiftLanguageMode(.v5))`, with
  linker settings on the executable: `-L dcvm/target/debug`, `.linkedLibrary("dcvm")`,
  `.linkedFramework("SystemConfiguration")` (the only framework the linker demanded —
  needed by netwatch's `system-configuration` crate).
- `CoreChatService` (actor) adapts the generated `DcApp` to the app's `ChatService`
  protocol. `DcApp`'s constructor is async but `ServiceFactory.make()` is sync, so the
  DcApp is created lazily via a stored `Task<DcApp, Error>` (idempotent under concurrent
  first calls). Generated types collide by name with the app's mirror types — qualified
  as `DeltaCore.X` inside the adapter only; the rest of the app never imports DeltaCore.
- Event bridge: the `EventListener` callback (tokio worker thread) just yields into an
  `AsyncStream` continuation — that *is* the thread hop, since the single consumer
  (AppModel's event loop) runs on the MainActor. Listener class is `@unchecked Sendable`.
- `ServiceFactory`: CoreChatService by default (data dir
  `~/Library/Application Support/DeltaChatNative`, `DCNATIVE_DATA_DIR` override);
  `DCNATIVE_MOCK=1` keeps the pure-Swift mock.

**Findings:**
- **Stale `libdcvm.dylib` shadowed the static lib**: the crate-type used to include
  `cdylib`; the leftover dylib in `target/debug` predated `DcApp`, and `ld -ldcvm`
  prefers dylibs over `.a`, so the link failed with missing `uniffi_dcvm_fn_*` symbols
  even though the `.a` had all 136 of them. Deleted the stale dylib (cargo won't
  regenerate it now that crate-type is `["lib","staticlib"]`).
- Swift 6 strict concurrency rejected a closure-based `mapping { ... }` error helper on
  the actor ("sending 'self'-isolated value ... risks data races"); plain
  `do/catch { throw mapError(error) }` per method is boring but clean.
- Benign ld warnings: prebuilt sqlite3/OpenSSL objects in libdcvm.a target macOS 26.5
  vs the package's 14.0 deployment target.
- UI scripting (System Events) can't attach to the bundle-less `swift run` binary in
  this environment, so the demo path got a dev hook instead: `DCNATIVE_AUTODEMO=1`
  auto-triggers `tryDemo()` when bootstrap lands on onboarding.

**Verification:** `cargo test` 8/8 green (unchanged, no exported-API changes so no
binding regen needed). `swift build` green. Smoke tests with a mktemp data dir: plain
launch alive after 8 s, core wrote `accounts.toml`; `DCNATIVE_AUTODEMO=1` launch alive
after 10 s with a demo account on disk — 12 chats / 18 msgs in its `dc.db`, empty stderr.

## 2026-07-16 — Chatmail-first onboarding: instant accounts + second-device join

Modern DeltaChat hides the e-mail: onboarding is now "Create New Profile" (instant
account on a chatmail relay) and "Add as Second Device" (receive the full existing
account — credentials, keys, chats — from another device's DCBACKUP QR over encrypted
iroh P2P). Classic e-mail login demoted to "Other options".

**Core facts (v2.49.0, verified in checkout):**
- `ctx.add_transport_from_qr("DCACCOUNT:<url>")` does everything for instant accounts:
  HTTP POST to the relay (only for `https://` payloads; a bare domain generates random
  credentials locally), configure, IO restart. Progress via `ConfigureProgress`.
- The default relay (`https://nine.testrun.org/new`) is a **client-side** constant —
  core has none. Exported as `default_instance_url()`.
- Second device: `qr::check_qr` → `Qr::Backup2` → `imex::get_backup(ctx, qr)`;
  progress via `ImexProgress` (0=error/cancel, 1000=done); receiver account must be
  fresh/unconfigured (guarded in dcvm with a friendly error); `start_io()` afterwards.
  Cancel = `ctx.stop_ongoing()`.

**dcvm additions:** `VmEvent::ImexProgress`, `QrKind` classification (`map_qr`, TDD),
`check_qr` / `create_instant_account` / `join_second_device` / `cancel_ongoing` on
DcApp. Offline tests cover QR classification and join_second_device rejection paths
(wrong QR kind, garbage input, already-configured account).

**macOS:** QR arrives via clipboard (image *or* text) or an image file — decoded with
CoreImage's built-in `CIDetector` QR support, no new dependency; no camera flow yet.
Second-device UI is a sheet with paste/file pickers and imex progress.

**Verification:** cargo test 14/14 green (6 unit + 8 integration); swift build green; mock smoke run alive.
**Live test (network):** `DCNATIVE_AUTOCREATE=1` dev hook exercised the real flow —
created and configured `a7ghrcg2d@nine.testrun.org` on the default relay from the app,
landing on the main screen. Second-device join needs a second real device, so only its
error paths are machine-tested; the happy path awaits a manual run.

## 2026-07-16 — Code-review fixes: event-loss recovery, stale sidebar, retryable DcApp init

Applied five confirmed review findings (all verified against the actual v2.49.0
checkout in `~/.cargo/git/checkouts/core-eddc226e816ba9ee/dab7ca1`):

- **`EventChannelOverflow` no longer swallowed** (`dcvm/src/app.rs`): core's broadcast
  channel (capacity 10_000, drop-oldest) reports lost events as a single overflow event
  with `id: 0` (verified in events.rs `recv()`), which `map_event` mapped to `None`. The
  pump now synthesizes a full-refresh hint: `AccountsChanged` (manager-level) plus
  `ChatlistChanged` per account. Tested deterministically by stalling the pump with a
  gated listener and flooding 10_100 `Info` events through `ctx.emit_event`.
- **`MsgsChanged { chat_id: 0 }` sentinel** (`dcvm/src/mapping.rs`): core's
  `emit_msgs_changed_without_ids()` uses chat_id 0 as "no specific chat"; forwarding it
  as `ChatChanged { chat_id: 0 }` was a phantom id outside the FFI contract. Now maps
  (whole msg-event group, via `ChatId::is_unset()`) to `ChatlistChanged`.
- **Stale sidebar with the real core** (`AppModel.swift`): `marknoticed_chat` emits only
  `MsgsNoticed` + `ChatlistItemChanged` and `send_msg` only `MsgsChanged` — all mapping
  to `chatChanged`, which only reloaded the open chat's messages, never the chat list;
  badges/previews stayed stale forever (invisible in mock mode, which emits
  `.chatlistChanged`). `chatChanged`/`incomingMessage` now also `reloadChats()`.
- **Poisoned lazy DcApp task** (`CoreChatService.swift`): a transient `DcApp::new`
  failure was cached in `appTask` until relaunch. Failures now clear the cached task,
  generation-guarded so a concurrent retry's fresh task is never clobbered;
  `selectedAccount()` logs instead of silently `try?`-ing the error away.
- **Makefile had no non-interactive Swift check**: added `swift-build` (build-only) and
  `check` (= `test` + `swift-build`). Finding confirmed live: SPM's manifest sandbox
  (`sandbox-exec`) cannot nest inside this restricted dev shell when swift runs under
  make — `SWIFT_FLAGS ?= --disable-sandbox` (overridable) fixes both `swift-build` and
  `run`. Curiously, `swift build` invoked directly (not under make) worked either way.

**Verification:** `cargo test` 9/9 green (4 unit + 5 integration, incl. the new overflow
test). `make check` green end-to-end (cargo test → bindings regen → `swift build`);
bindings regen produced zero diff, confirming no exported-API change.

## 2026-07-17 — Core upgrade v2.49.0 → v2.53.0 (second-device vs newer iOS)

A real iOS phone's "Add Second Device" QR was rejected as BackupTooNew: current mobile
clients emit DCBACKUP **5**, v2.49 supports ≤4. v2.53 supports 5.

API fallout fixed in dcvm:
- `EnteredServerLoginParam` split into `EnteredImapLoginParam`/`EnteredSmtpLoginParam`.
- `MessageState::OutPreparing` removed.
- Reactions: one emoji per contact, `Reaction::as_str()` (no more `emojis()` vec).
- **`ForceEncryption` now defaults ON**: unencrypted sends fail and unencrypted
  incoming mail is not processed. Correct for real accounts; the offline demo account
  and test fixtures relax it (`set_config_bool(ForceEncryption, false)`, same as
  core's own test_utils), since keyless pseudo-configured accounts can't encrypt and
  inject plaintext mail by design.
- Dependency tree grew aws-lc-rs/aws-lc-sys (needs `cmake` at build time — present via
  homebrew here). socket2/netwatch pins survived re-resolution.

Verified: 22 offline tests + both relay tests green on v2.53; swift build clean;
demo smoke run alive; bundle rebuilt. Real iOS join pending user retry.

## 2026-07-17 — Scroll/pagination polish (issue: chat-list-width-and-scroll-behavior)

First real-account feedback fixes:
- Sidebar: min 300 / ideal 360 (was 240/300) — names and previews no longer truncate.
- Message pagination: `messages(limit, before_msg_id)` in the FFI (limit 0 = all, used
  by tests). The app loads the newest 100 and fetches another page when a top sentinel
  becomes visible, restoring the scroll anchor ("msg-<id>") after prepending. Event
  reloads refresh exactly the loaded window, so reactions/state updates on visible
  history still appear without loading everything.
- Bottom-follow only when already at bottom (tracked by a bottom-sentinel
  appear/disappear); otherwise incoming messages leave the viewport alone.
- Chat switch snaps to the newest message without animation (the animated scroll only
  runs for new-message-while-at-bottom).

## 2026-07-17 — Scroll follow-up: layout-aware anchoring + stable image sizes

The manual scroll bookkeeping raced layout: snapping to bottom before lazy cells and
images had their real sizes landed mid-chat, and a blob finishing its download grew the
bubble after the last scroll. Replaced with the purpose-built API (needs macOS 15,
platform bumped): `.defaultScrollAnchor(.bottom)` for layout-aware initial position
(+ `.id(chat.id)` so each chat starts fresh = snap semantics) and
`.defaultScrollAnchor(.bottom, for: .sizeChanges)` to stay pinned through content
growth only while actually at the bottom. Deleted isAtBottom/lastNewest tracking;
prepend anchor-restore stays.

Image bubbles now size themselves from core's stored pixel dimensions BEFORE the blob
exists (placeholder at final size while downloading), so arrival changes pixels, not
layout. Plus an NSCache for decoded images (LazyVStack re-renders hit disk otherwise).

## 2026-07-17 — Native-feel polish (issue: native-feel-polish)

- Multi-line growing composer (TextField axis .vertical, 1–5 lines; Return sends,
  Option+Return newline), focus kept after send and set on chat switch.
- Quick Look previews for attachments (tap or context menu); "Open in App" separate.
- Menu-bar commands: New Chat ⌘N, New Group ⇧⌘N, Profile Settings ⌘, (replacing the
  stock settings item), Show Archived ⇧⌘A — sheet state moved into AppModel so both
  toolbar and menu drive the same sheets.
- Dock badge: total unread across unmuted chats, updated with the (unfiltered) list.
- Subtle "Pop" for messages landing in other chats while active (notifications cover
  the inactive case).
- Liquid Glass composer bar on macOS 26 via #available (min platform stays 15).

## 2026-07-17 — Links, in-chat avatars, live timestamps, full muting

- URLs in bubbles are tappable (NSDataDetector -> AttributedString links; white
  underline on outgoing accent bubbles, accent on incoming).
- Group chats show the sender avatar beside the first bubble of each run
  (MessageItem.sender_avatar over the FFI); later bubbles keep the indent.
- Chat-list timestamps were already relative but never refreshed — now wrapped in
  TimelineView(.everyMinute) so "now"/"5 min" stay honest.
- Muting: set_chat_muted over the FFI (MuteDuration::Forever/NotMuted, synced),
  mute/unmute in the row context menu, gray unread badge, no sound, no notification
  for muted chats. Offline mute round-trip test (24 dcvm tests total).

## 2026-07-17 — Whole-app audit: 3 parallel reviewers, ~25 findings, fix pass

Three independent audit agents (Rust/FFI, Swift concurrency/bridge, app state/UX)
converged on the same core bug families. Fixed in this pass:

**Rust:** event pump held a strong Arc cycle keeping Accounts (and the accounts.lock)
alive after DcApp drop — now Weak with upgrade-or-exit; demo conversation order was
scrambled after its hardcoded dates passed (send_text_msg sorts at "now") — both
directions now injected via receive_imf with relative dates (regression-tested);
add_demo_account error path rolls back the auto-selected half-seeded account;
messages(before: deleted-anchor) returned the NEWEST page (duplicate prepends) — now
empty (tested); ContactsChanged/SelfavatarChanged were unmapped (no refresh signal);
new chat_by_id point lookup (TDD) so notification decisions never scan stale lists.

**Swift:** the stale-await family — reloadChats/reloadMessages/loadOlderMessages all
re-validate account/chat/filter state after every await (chat A's slow fetch can no
longer render inside chat B, nor corrupt its pagination window); read receipts and
mark-noticed no longer fire while the app is inactive (they run on activation
instead); notifications now work for ALL accounts, use a fresh chat_by_id lookup
(fixes muted-chat bypass under search/archive and one-event-stale previews), and
queue while the permission prompt is unanswered; event bursts are coalesced (80 ms)
instead of one full reload per event; onboarding flows can't brick isConfiguring or
clobber each other; search keystrokes no longer destroy the open chat's draft;
archive toggle clears search; account switch/remove resets filters and dock badge;
deleted messages clear a dangling reply banner; forward sheet lists all chats, not
the filtered sidebar; audio player resets when playback finishes (with stale-player
identity guard); camera scanner can't fire after stop (lock, not queue-async flag);
main-screen errors surface as an alert instead of leaking into onboarding.

**Deferred (accepted for now, in the audit issue):** distinct EventsDropped signal
instead of overloading ChatlistChanged; per-account notification coalescing during
initial-sync storms of background accounts; live connectivity outside the settings
sheet. showAuthor/avatar per-run rules and Color-hex validation got Swift unit tests
(new test target, macos/Tests/DeltaAppTests).

## 2026-07-17 — Link cursor (AppKit) + send-scroll window fix

- pointerStyle(.link) never rendered: SwiftUI's text-selection pointer wins. Link-
  bearing messages now render via an NSTextView-backed `LinkText` (per-range hand
  cursor through the `.cursor` attribute, native link clicks, selection); plain
  messages keep SwiftUI Text. `nsLinkified` (AppKit-scope attributes) is unit-tested.
- "Send lands mid-chat in 100+ chats": the reload window-growth heuristic fired on
  every send (window slides one, previous oldest drops off, misread as lost reading
  position) and prepended a full page — destabilizing lazy layout. Growth is now
  gated on the view's actual at-bottom state (bottom sentinel reports to the model);
  decision extracted as pure `windowNeedsGrowth` and TDD'd (4 cases).

## 2026-07-17 — Estuary rebrand, first slice (issue: estuary-rebrand)

The app has a name: **Estuary** ("where conversations converge" — delta and
estuary are both river mouths; Delta Chat compatible, not a fork). User
approved a brand sheet: teal/coral palette, wave-into-speech-bubble icon.

- `EstuaryTheme` (TDD'd: hex validity — a typo'd hex silently falls back to
  gray — role distinctness, adaptive accent): deep teal `#0F3D3E` accent in
  light mode, sea glass `#7FBDB4` in dark (deep teal reads near-black there),
  via an NSColor dynamic provider so appearance switches re-resolve. Outgoing
  bubbles stay deep teal in BOTH modes: they carry white text, and sea glass
  would wash it out. Unread badges are coral `#FF6F61` (muted stays gray).
- Renames: Info.plist name/display "Estuary", bundle output `Estuary.app`,
  window title, onboarding title + tagline. Deliberately UNCHANGED: bundle id
  (TCC camera + notification grants are keyed to it), data dir
  `DeltaChatNative` (existing accounts), internal target names (churn).
- Visual result (accent rendering in both appearances) is eyeball-verified,
  not unit-testable; constants and adaptive selection logic are.
- Icon asset pending → app-bundle-polish issue. Mockup features out of scope:
  calls/presence (no core support), list filter tabs, accent picker.
- Review pass caught: coral badge with white numerals is ~2.7:1 → badge text
  is midnight blue now (muted gray badges keep white); badge theme test
  tightened to guard the actual `badge`/`badgeText` colors, not hex literals.
  Flagged-plausible, accepted: dark-mode sea-glass tint behind prominent
  buttons — macOS auto-contrasts control labels for light accents (same
  mechanism as the system yellow accent), needs a dark-mode eyeball.

## 2026-07-17 — App icon + onboarding logo (issue: app-bundle-polish, icon slice)

User delivered the wave-into-speech-bubble logo — as an AI export with the
transparency checkerboard BAKED INTO the pixels (hasAlpha: no). Recovery
pipeline in `dev/icon/gen-icon.swift` (make icon):

- Border-seeded flood fill over the two sampled checker colors recovers real
  alpha; the interior white wave is safe because the fill only spreads
  through checker-colored pixels. 1px anti-aliasing rim gets half alpha.
- Premultiplied-alpha gotcha: zeroing ONLY the alpha byte leaves RGB
  contributing on composite (src-over adds premultiplied RGB regardless) —
  the icon rendered a white box behind the logo until RGB was zeroed too.
- Composite follows Apple's icon grid (824px rounded square, r=185, on a
  1024 canvas), warm-ivory fill like the brand sheet's header lockup;
  `iconutil` packs the ten-size iconset into assets/brand/Estuary.icns.
- Onboarding shows the real logo (bundled via SPM resources, loaded through
  `Bundle.module`, SF-symbol fallback). Resource presence is TDD'd — and the
  Makefile now copies DeltaApp_DeltaApp.bundle into Contents/Resources,
  because Bundle.module TRAPS at runtime if the bundle is missing from the
  .app. Icon rendering itself is eyeball-verified (build artifact).

## 2026-07-17 — Going public (issue: publish-github-nightly-site)

Repo published as github.com/lambadalambda/estuary. Pieces:

- **License**: the Unlicense (public-domain dedication) for our code; core
  stays MPL-2.0 (noted in README, deliberately NOT inside LICENSE — extra
  text there breaks GitHub's licensee similarity matching). Review caught
  dcvm/Cargo.toml still claiming MPL-2.0 from the prototype scaffold.
- **README**: rewritten around the brand (logo header, website + nightly
  links, honest Gatekeeper note for ad-hoc-signed builds).
- **CI nightly** (.github/workflows/nightly.yml): macos-15 runner, rust-cache,
  cargo test → make app → swift test → drag-install DMG (hdiutil UDZO) →
  delete+recreate the `nightly` prerelease so the asset URL stays stable.
  Concurrency queues rather than cancels: a cancel between release delete
  and create would 404 the download link (review catch). Dev-profile build,
  same as `make app` — honest nightly; release packaging = app-bundle-polish.
- **Website**: docs/index.html (single file, palette + Sora, light/dark),
  served by GitHub Pages from main:/docs. Review catch: the features card
  claimed "voice messages" while recording is still on the not-yet list —
  now says playback.
- CI YAML/HTML aren't unit-testable; verification = the live workflow run
  and the served page.

## 2026-07-17 — Review follow-ups: link cursor, message timestamps, timed mutes

- Hand cursor over link-bearing bubble text (pointerStyle(.link); SwiftUI has no
  per-range pointer — link-free text inherits the normal cursor, caught in the new
  pre-commit review).
- Message footers now use the same fresh-relative format as the chat list ("now",
  "5 min", then clock time), refreshing every minute.
- Mute durations: FFI takes seconds (0 unmute / negative forever / positive timed via
  MuteDuration::Until); menu offers 1 h / 8 h / 1 week / forever.
- Process: a code-review pass now precedes every commit.

## 2026-07-17 — Rebrand slice 2: calm ivory surfaces (issue: estuary-rebrand)

User verdict: keep teal/coral, add the warm ivory background, "calmer
overall". Chat surface is now adaptive ivory/midnight; incoming bubbles are
flat white cards (card navy in dark), delineated by a faint shadow — the
fills sit deliberately close to the surface, which is the calm. Review pass
flagged the near-invisible card edges (mockup-accurate but risky) → shadow;
and a theme test overclaiming "contrast" when it only guards same-color
pairs → renamed honestly. Dynamic-color creation extracted into one
`adaptive(_:)` helper now that three colors use it.

## 2026-07-17 — Quote contrast fix, tiling chat background, showcase mock

- User-found bug: quote blocks in OUTGOING bubbles used `.primary`/contact
  colors → black-on-deep-teal. Everything inside an outgoing bubble must be
  white; quote bar/name/text now switch on `isOutgoing`.
- Tiling chat background from the user's CC0 pattern (make tiles →
  dev/icon/gen-tiles.swift): light = pattern MULTIPLIED onto warm ivory;
  dark = DIFFERENCE-inverted, then SCREENED onto midnight at 0.5 alpha so
  only the strokes lift the background. 512px bitmaps declared at 256pt for
  @2x retina density. `ChatBackdrop` (surface + tile, per-appearance via
  colorScheme) replaces the flat surface. Tile visuals are eyeball-verified
  (both variants inspected); resource presence is theme-tested.
- Mock seed reworked into the website showcase (Elena/Marco/Priya/Sam,
  Weekend Hikers group with isGroup flag, real bundled CC0 sunset photo,
  previews/timestamps synced for manual appends) — pinned Saved Messages
  would have hijacked chats.first for the AUTOSELECT hook, so it's unpinned.
  Showcase shape is pinned by MockShowcaseTests. Screenshot env recipe:
  DCNATIVE_MOCK=1 DCNATIVE_AUTODEMO=1 DCNATIVE_AUTOSELECT=1
  DCNATIVE_APPEARANCE=light|dark.

## 2026-07-17 — Hugging bubbles + website screenshots

- User request (with official-DC reference shot): bubbles must hug their
  content, anchored to their side, instead of stretching the full row. The
  stretch came from the timestamp footer's `.frame(maxWidth: .infinity)`
  inside the bubble VStack — any greedy child makes the whole bubble
  greedy. Now: content VStack + timestamp as a ZStack(.bottomTrailing)
  overlay (reserved bottom padding so it never covers text) + a 560pt
  readability cap on wide windows. Pure layout, eyeball-verified via the
  screenshot loop.
- Screenshot pipeline in practice: mock showcase + AUTOSELECT/APPEARANCE
  hooks, user captures the windows (⇧⌘4+Space; agent shell has no window-
  server access — CGWindowList returns zero bounds, screencapture blank).
  Both variants on the site via <picture> prefers-color-scheme.

## 2026-07-17 — Overlay scrollers in the chat (user: intrusive scrollbar)

The persistent scroll track (system "Always show scroll bars") reads as
intrusive on the tiled surface. `OverlayScrollers` NSViewRepresentable walks
up to the backing NSScrollView and forces scrollerStyle = .overlay (fade
after scrolling). Review catch: AppKit reverts the style on
preferredScrollerStyleDidChange (pref flip, mouse plug) with no SwiftUI
update to piggyback on → explicit NotificationCenter observer re-applies.
AppKit view-walking is untestable in unit tests (no window hierarchy) —
eyeball-verified.

## 2026-07-17 — Chat chrome polish (sidebar scroller, composer card)

- Correction of the entry above: AppKit view-walking IS unit-testable —
  NSScrollView hierarchies build fine headless, no window needed
  (OverlayScrollersTests). Only the live-window timing/insertion races stay
  eyeball-only.
- OverlayScrollers redesigned after the sidebar needed it too: a List's
  NSScrollView is a *sibling* of a `.background` anchor, not an ancestor,
  and review showed any "style the first match" lookup fails open (styles
  the wrong pane's scroller, reports success, never retries — SwiftUI gives
  no locality guarantees in its platform hierarchy). apply() now sweeps the
  whole window and styles EVERY scroll view — idempotent, race-tolerant.
  Also dropped the updateNSView re-apply: it ran on every composer
  keystroke; insertion + 0.4s retry + style-change observer cover all real
  reversion events.
- Composer is now a floating rounded card (incoming-bubble surface) over the
  tiled backdrop instead of a square bar — resolves the shape clash with the
  rounded sidebar. Bubble + composer share one `cardSurface` recipe so they
  can't drift apart. The Liquid Glass `barBackground` helper (and its
  `#if compiler(>=6.2)` CI guard) is gone with the bar.
- Backdrop ownership moved up to MainView's detail column so the
  "No Chat Selected" state sits on the same tiled surface (no flash on
  selection changes).
- Composer icon alignment: `.lastTextBaseline` instead of hand-tuned bottom
  paddings. Untestable visuals (baseline alignment incl. multi-line drafts,
  card look, scroller fade) are eyeball-verified per project rules.

## 2026-07-17 — Scroll regressions (user report after chrome polish)

- Jump-to-top on select/post: the loadOlder anchor restore
  (`proxy.scrollTo(oldest, .top)`) also ran while the viewport was pinned
  at the bottom — for chats whose loaded window fits the viewport the
  sentinel is realized right on open, so opening/posting flung the view to
  the top. Restore is now suppressed at the bottom
  (AppModel.historyRestoreAnchor, unit-tested); the
  `.defaultScrollAnchor(.bottom, for: .sizeChanges)` pin absorbs prepends.
- Sidebar legacy-scroller flash on selection: AppKit re-stamps the
  preferred style when the List re-tiles; dropping the per-update re-apply
  (perf fix) left nothing to correct it — a regression from the sweep
  redesign. Scroll views are now KVO-pinned (scrollerStyle +
  autohidesScrollers corrected synchronously, before drawing); pins live as
  associated objects so their lifetime matches the scroll view. KVO on
  NSScrollView.scrollerStyle works — proven by test, revert corrected
  within the setter call.
- User clarification: the jump hits HUGE chats with scrollback — the lazy
  container realizes its top edge during initial layout (before settling at
  the bottom anchor), spuriously firing the load-older sentinel; the
  unconditional anchor restore then scrolled to the old window top. The
  at-bottom suppression covers it; the spurious load degrades to a harmless
  history prefetch.
- Review catch on the fix itself: viewIsAtBottom was realization-based
  (onAppear/onDisappear span the realized region, not the viewport), which
  could wrongly suppress a legitimate restore for a scrolled-up user in
  short chats. Now visibility-based via onScrollVisibilityChange — also
  makes windowNeedsGrowth honest. Known pre-existing edge (review, left
  open): if content still fits the viewport after a prepend, the sentinel
  never re-fires and the spinner can stall until the next visibility change.
- Follow-up user report: with the restore suppressed, the huge chat opened
  BLANK (no scrollbar), content popping in at the bottom only after a real
  scroll gesture — the spurious initial prepend strands the viewport in
  unrealized lazy space, and the old jump-to-top restore had been the
  accidental rescue. loadOlderMessages now returns a HistoryLoadOutcome
  (.restore for scrolled-up reading, .pinBottom when pinned at the bottom)
  and the view re-pins via scrollTo(bottomAnchorID, .bottom). Caveat
  (review): the rescue relies on the bottom anchor id staying resolvable
  from the initial layout — verified against the real huge-chat repro by
  the user; if it recurs, defer the scrollTo one tick. DCNATIVE_DEBUG_SCROLL=1
  prints sentinel/anchor/outcome diagnostics for exactly that case.
- Reopened: blank-open persists and is WINDOW-SIZE-dependent (a given size
  reliably breaks the problematic chat; any resize heals instantly; logs
  show zero loadOlder activity → the prepend theory is falsified for this
  repro). The initial bottom-anchored lazy layout itself strands the
  viewport, with the bottom-anchor visibility flapping ~12x while it
  settles. Stopgap shipped: two unguarded post-open re-pins (~120/450ms,
  cancellation-checked — a viewIsAtBottom guard would defeat the rescue
  since the stranded state reports not-at-bottom) + opt-in
  onScrollGeometryChange diagnostics (offset/content/container) to
  pin down the stranded geometry for a principled geometry-triggered fix.
  All view-timing behavior — untestable per project rules, user-verified.
- Geometry logs from the failing open (user): contentSize estimates
  oscillate wildly during settling (672→4346→7830→6957, sometimes
  collapsing to ~120), the broken state's geometry LOOKS sane (offset
  nominally inside content) while nothing renders, and the proxy re-pin
  produces zero geometry delta — ScrollViewProxy.scrollTo silently no-ops
  against derealized targets. An AppKit clip-view rescue was built, then
  REPLACED after an approach review: a resize heals via container-size
  invalidation (full lazy re-solve + bottom re-anchor), while a clip move
  is only an origin change over the same corrupted bookkeeping, with a
  silent no-op hole at zero delta. Shipped stopgap: shot 1 proxy re-pin
  (~120ms), shot 2 a 1pt ScrollView-padding toggle (~450ms) that rides
  exactly the proven resize path. Untestable view timing per rules.
- Root cause per approach review, queued as the real fix: LazyVStack
  realization bookkeeping under bottom anchoring has now caused three
  consecutive regressions; the open window is 100 fixed-size items, so
  laziness earns ~nothing. Plan: swap to plain VStack, profile 100-item
  open + ~500-item grown window (hoist per-bubble TimelineView if needed),
  then delete the rescue machinery. Also: deployment target is macOS 15 —
  dropped a dead #available(15) guard.

## 2026-07-18 — Root cause: LazyVStack estimates (blank-open finally explained)

The user's scroll-up trace was the smoking gun: 2000pt of blank scrolling
with content frozen at 6138, then realization snaps content to 2738 — the
lazy estimate was 2.2x the REAL height, and the bottom-anchored viewport
was parked beyond the real content's end in phantom space. The nudge log
also proved container-size invalidation re-solves estimates but does NOT
re-anchor (offset frozen through the nudge), so no stopgap could win.
Fix: message list is now a plain VStack (open window is ~100 fixed-size
items) — exact layout, no estimates, no phantom space; scrollTo always
resolves. Sentinel is visibility-triggered only (eager onAppear fires once
at insertion — would fire a pointless page load per open). All rescue
machinery deleted (never shipped: AppKit clip-move was replaced by the
container nudge after approach review, and the nudge by this).
Follow-up queued: profile a ~500-item grown window (per-bubble closures
defeat struct-equality skips → all bubbles re-eval per keystroke; hoist
TimelineView / cap the window if it hitches). Layout behavior untestable
per project rules — user-verified against the known repro.
- Page size halved 100 → 50 after user confirmation: eager layout renders
  the whole loaded window and a viewport shows ~10 messages, so smaller
  pages halve open-time layout/decode work. Review traced the halved
  margin: a viewport-filling initial window still converges in one bounded
  auto-load with the bottom pinned.

## 2026-07-18 — Release-profile packaging (nightly ships release now)

`make app-release`: one PROFILE knob drives cargo --release, the uniffi
lib path, the SPM lib dir (DCVM_PROFILE env read in Package.swift), and
.app assembly. Separate SPM scratch dir per profile — belt-and-suspenders;
review verified empirically that current SPM re-evaluates
Context.environment per build even in a shared scratch. CI builds release
end-to-end on a SINGLE Rust profile (cargo test --release shares artifacts
with the app build; Swift tests link the release lib) and rotates the
rust-cache prefix-key — review catch: an exact hit on the old debug cache
would never save release artifacts, cold-building core every night. Local
release app (76MB bundle) verified launching against mock data. Build
plumbing is untestable per rules — verified by building both profiles.

## 2026-07-26 — STT stage 1: voice-message audio decode (issue: stt-audio-decode)

Engine decision recorded in meta/issues/voice-message-transcription.md:
transcribe.cpp + Parakeet TDT 0.6B v3 (25 languages, Rust bindings, model
below the FFI) over macOS 26 SpeechAnalyzer (zero-bloat but shell-side and
narrower locales). User picked Parakeet.

New `dcvm/src/stt/decode.rs`: symphonia (aac/isomp4/mp3 features added) +
rubato → 16 kHz mono f32 for the ASR engine. Findings:
- Adding symphonia/rubato re-resolved socket2 edges 0.5.10 → 0.6.1 on
  hyper-util/quinn/quinn-udp AGAIN (same trio as 2026-07-16), breaking
  netwatch. Same fix: hand-flip the three edges in Cargo.lock, verify
  `cargo build --locked`. Any manifest touch requires this check.
- Review-caught real bug the length/RMS tests couldn't see: trimming
  resampler output to expected length from the FRONT eats speech onset —
  rubato's process_partial zero-pads at the END (measured 363-sample /
  23 ms shift via an impulse-position test). Fix: drain output_delay()
  from the front, truncate padding from the end; residual error 22
  samples (~1.4 ms, rubato's reported-vs-actual delay rounding).
  Moral: for DSP code, test *timing* with impulse positions, not just
  length + energy.
- Opus-in-Ogg → typed Unsupported (no symphonia decoder); core never
  classifies bare .opus as Voice/Audio, so realistic voice blobs are
  m4a/aac/mp3/wav. 30-min decode cap (TooLong) guards memory.

## 2026-07-26 — STT stage 2: Parakeet engine + model manager (issue: stt-engine-parakeet)

transcribe-cpp pinned =0.1.3 (crates.io latest; repo's 0.2.0 unpublished).
C++/GGML build via cmake in build.rs worked first try (cmake 4.4, Metal on).
Adding the dep flipped the socket2 trio AGAIN — third occurrence; flip-back
now routine (see stage 1 entry).

`stt::engine`: SttEngine trait (fake-able for offline tests) + ParakeetEngine
(session-per-call; Model verified Send+Sync in vendored source, sessions are
Send-only). `stt::model`: ensure_model → `<data_dir>/stt-models/`, streaming
download with sha256-before-rename, private .part.<pid>.<seq> temp files,
connect (30s) + stall (60s) timeouts after review flagged hung-FFI risk of
the default reqwest client. Offline tests run against a one-shot local TCP
server (happy/checksum/truncated/oversized/stalled).

Real-model smoke test (`--ignored`, DCVM_TEST_STT env): Parakeet Q8_0
(739,508,576 bytes, sha256 5859f779…, HF handy-computer repo) transcribed
whisper.cpp's jfk.wav verbatim incl. punctuation. ~90 s total = model load +
first-run Metal warmup; inference itself seconds for 11 s audio. macOS `say`
synthesizes zero audio bytes in this agent session (even unsandboxed), so
the test accepts DCVM_TEST_STT_AUDIO/_EXPECT overrides; kept the `say` path
for normal terminals. Honest TDD note: download-manager tests were written
alongside the implementation (local test server design drove the API), not
strictly red-first; review + five error-path tests compensate.

## 2026-07-26 — STT stage 3: transcription FFI + Swift UI (issue: stt-ffi-ui)

`DcApp::transcribe_message` (cache → decode via spawn_blocking → engine
mutex → model download w/ throttled permille events → inference) +
`VmEvent::TranscriptionProgress {msg_id, phase, permille}`. DcApp now keeps
the listener for out-of-pump events. Offline vm tests use an injected fake
engine (`set_stt_engine_for_test`, non-FFI helper block).

Swift: TranscriptState machine in Support/Transcription.swift (pure reducer;
late events never downgrade done/failed — that guard is what makes the
event-vs-return race benign), AppModel.transcripts per-visit like
expandedMessageIds with stale-await guards, AudioMessageView grows a
Transcribe button → progress → italic transcript / readable error + retry.
Row heights: heightKey now composes `+expanded` × `+t:<class>` variants;
applyTranscriptChanges mirrors applyExpansionChanges (invalidate on every
class change — a retry's failure text can differ under the same key).
ServiceEventBuffer coalesces progress latest-wins per (account, msg).
Mock: bundled 1.2s voice fixture + honest transcribe (audio-only error,
session cache, visible delay).

Build finding: once libdcvm.a contains transcribe.cpp/GGML objects, the
Swift link needs `-lc++` + Metal/Foundation/Accelerate — added to both
Package.swift targets. Review carry-over filed as stt-engine-eviction
(engine stays ~700 MB resident after first use).

## 2026-07-26 — STT e2e in a lume VM (host session cannot touch the GUI)

Host agent session is contained beyond its own seatbelt (no WindowServer,
no ~/.lume writes, no `ps`; `say` synthesizes 0 bytes) — GUI verification
moved into the `cua-driver-dev-26.5.2` lume VM per user request. Recipe
that worked: stage binary + DeltaApp_DeltaApp.bundle + seeded data dir in
a host dir; start the VM via the lume HTTP API on :7777 (the daemon runs
outside the containment; the CLI does not) with that dir as
--shared-dir; ssh (paramiko, lume/lume) to copy VM-local and launch with
DCNATIVE_DATA_DIR; drive clicks/AX/screenshots with the in-VM
CuaDriver.app (`cua-driver call get_window_state/click …` — start the
.app, not the raw binary, for TCC identity). Data dir seeded by
dcvm/examples/seed_stt_e2e.rs (demo account + jfk.wav send); model
pre-planted under <data_dir>/stt-models/ to skip the 700 MB download.

Result: Transcribe button on the jfk.wav bubble produced the exact JFK
line in-bubble in ~20 s on 4 vCPUs (CPU inference — no Metal in the VM
path). stt-audio-decode + stt-engine-parakeet archived; stt-ffi-ui stays
open for two real-app checks (first-use download progress UX, received
Voice-kind message via the local relay).

## 2026-07-26 — STT latency: measured, explained, amortized (issue: stt-performance)

User-reported "transcription takes quite some time". Bench (stt_bench
example, host M-series, dev profile, Q8_0, 11 s jfk.wav):
backend MTL0 (Metal — no CPU fallback), warm model load 0.44 s,
inference 0.3–0.8 s → RTF 0.03–0.07 (~15–35x realtime). Decode ~0 s.
The slowness is entirely the FIRST-EVER cold start: 700 MB page-in +
first-run Metal pipeline compile ≈ 90 s (the ignored smoke test's 92.77 s
body drops to 0.93 s warm — same machine, same code). Q8→Q4 would not
help (quant is not the bottleneck on Metal); Q8 kept for accuracy.
Fixes: TranscriptionPhase::LoadingModel so the spinner says "Preparing
transcription engine…" instead of lying with "Transcribing…", and
DcApp::warm_transcription — fired once per launch when the first audio
bubble renders (loads only an already-downloaded model; never downloads),
so the cold start runs while the user is still reading. Skipped (noted per
TDD rule): Swift unit test for the once-per-launch warm guard — trivial
flag; covered implicitly by e2e.

Review catch before commit: Double→Int64 conversion TRAPS (not clamps)
past Int64.max — a corrupt container whose CMTime decodes to ~9.2e18 s
would crash the app while rendering the bubble. Guard added in
durationMs(fromSeconds:) with a test at 9.2e18.

## 2026-07-26 — Audio duration on every bubble (issue: audio-duration-display)

Core only knows durations for real Voice messages (Chat-Duration header);
plain audio attachments showed nothing. AudioMessageView now always
renders the duration line ("–:––" placeholder), with AVURLAsset probing
+ per-path cache filling in when core reports 0. Always-rendered keeps
row height stable when the async probe lands (no invalidation needed).
Core's value stays authoritative when nonzero (pure helpers
durationMs(fromSeconds:)/effectiveDurationMs, unit-tested incl. NaN /
infinity / overflow-trap edges).
