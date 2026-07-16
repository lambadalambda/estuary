# DeltaChat Desktop Frontend — Minimal UI Data Requirements for Native Prototype DTOs

Source: `/Users/lainsoykaf/repos/deltachat/deltachat-desktop/packages/frontend` (deltachat-desktop, jsonrpc-client 2.49.0). All fields below are the ones the UI *actually renders* for a text-only prototype; everything else in the core types can be dropped from the viewmodel DTOs.

---

## 1. Chat list row

Source files:
- `packages/frontend/src/components/chat/ChatListItem.tsx` (`RegularChatListItem`, `Header`, `Message`, `FreshMessageCounter`)
- `packages/frontend/src/components/conversations/Timestamp.tsx` + `formatRelativeTime.ts`
- `packages/frontend/src/components/Avatar/index.tsx`, `packages/shared/avatarInitial.ts`

The row is fed by core's `ChatListItemFetchResult` (a tagged union: `kind: "ChatListItem" | "ArchiveLink" | "Error"`). The desktop UI fetches ids via `getChatlistEntries` and items via `getChatlistItemsByEntries` (lazy, virtualized, cached per-id).

### Proposed DTO: `ChatRowVM`

| Field | Type | Rendered as | Example |
|---|---|---|---|
| `id` | u32 | key, selection | `12` |
| `name` | string | title line, truncated | `"Alice"` |
| `avatarPath` | string \| null | avatar image; when null → initials circle | `"/blobs/avatar12.jpg"` |
| `avatarInitial` | string (derived) | first grapheme of `name` (fallback `addr`), uppercased | `"A"` |
| `color` | string (CSS color) | initials circle background (`--local-avatar-color`) | `"#e56555"` |
| `lastUpdated` | i64 millis \| null | relative timestamp, right-aligned in header; hidden if null/0 | `1752666000000` |
| `summaryText1` | string | bold prefix before preview, rendered as `summaryText1 + ": "`; empty string → no prefix. Core fills this with sender name / "Me" / "Draft" | `"Me"` |
| `summaryText2` | string | preview text (one line, parsed/ellipsized) | `"see you tomorrow"` |
| `summaryStatus` | u32 (DC_STATE_*) | two uses: (a) `DC_STATE_OUT_DRAFT` → style prefix as draft; (b) if outgoing state → tick icon after preview via `mapCoreMsgStatus2String` (`sending`/`delivered`/`read`/`error`). Incoming states (`IN_FRESH/IN_SEEN/IN_NOTICED`) → no icon | `26` (OUT_DELIVERED) |
| `freshMessageCounter` | usize | unread badge; hidden if 0; also `has-unread` row styling. Hidden when `isContactRequest` | `3` |
| `isPinned` | bool | pin icon in header + `pinned` styling | `false` |
| `isMuted` | bool | mute icon in header + `muted` styling | `false` |
| `isContactRequest` | bool | "Request" label instead of status icon/badge | `false` |
| `isArchived` | bool | "Archived" label (only needed if you show the archive) | `false` |

Skippable for prototype: `chatType`/`isGroup` (only used for OutBroadcast tick-hiding & test ids), `wasSeenRecently` (green online dot), `summaryPreviewImage`, `isSelfTalk`, `isDeviceTalk`, `isEncrypted`, `dmChatContact`, ArchiveLink/Error variants.

### Timestamp format (chat list, `extended: false`, `formatRelativeTime`)
- < 1 min → "now"; < 1 h → "N minutes"; same day → "N hours"
- ≤ 6 days but not today → weekday `ddd` ("Wed")
- same year, > 6 days → `MMM D` ("Jul 2")
- older year → moment `ll` ("Jul 2, 2024")
- Timestamps < 24h old re-render on a 60s global timer.

---

## 2. Message bubble

Source files:
- `packages/frontend/src/components/message/Message.tsx` (bubble, info messages, author name/avatar)
- `packages/frontend/src/components/message/MessageMetaData.tsx` (footer: time + ticks)
- `packages/frontend/src/components/message/MessageList.tsx` (`DayMarker`, list assembly)
- `packages/frontend/src/components/message/MessageWrapper.tsx` (li wrapper + mark-read IntersectionObserver)
- `packages/frontend/src/utils/getDirection.ts`, `components/helpers/MapMsgStatus.ts`

The list is built from `getMessageListItems(accountId, chatId)` → array of `{kind:'message', msg_id}` | `{kind:'dayMarker', timestamp}` (day separators come from core, seconds-based unix timestamp), and messages loaded via `getMessage`/batch into a `messageCache`.

### Proposed DTO: `MessageListItemVM` (tagged union)
- `{ kind: "dayMarker", timestamp: i64 /* unix seconds */ }` — rendered as centered pill: Today / Yesterday / long date (`moment.calendar` with `LL`).
- `{ kind: "message", message: MessageVM }`

### Proposed DTO: `MessageVM`

| Field | Type | Rendered as | Example |
|---|---|---|---|
| `id` | u32 | DOM id, key, mark-seen | `4501` |
| `text` | string | bubble body (parsed for links/emoji; plain text is fine for prototype) | `"hi there"` |
| `isOutgoing` | bool (derived: `fromId == DC_CONTACT_ID_SELF` (=1)) | alignment left/right + bubble color | `true` |
| `isInfo` | bool | centered system pill instead of bubble (text only; shows sending/error status icon if outgoing) | `false` |
| `timestamp` | i64 unix seconds (UI multiplies ×1000) | footer time, `extended: true` relative format (same buckets as above but with time appended for recent, e.g. "Wed 14:03") | `1752662400` |
| `state` | u32 → derived `status: "sending"\|"delivered"\|"read"\|"error"\|""` | delivery ticks in footer, only when outgoing (one tick = delivered, two = read/MDN, clock = sending, red = error) | `28` (MDN_RCVD → read) |
| `error` | string \| null | error styling + red status icon overrides `state` | `null` |
| `senderName` | string (`sender.displayName`, prefixed `~overrideSenderName` if set) | author line above bubble, **only for incoming messages in multi-participant chats** (`showAuthor = conversationType.hasMultipleParticipants`) | `"Bob"` |
| `senderColor` | string | author name text color AND `msg-container` border color; also avatar initials bg | `"#3d7bde"` |
| `senderAvatarPath` / `senderInitial` | string \| null / string | small avatar next to incoming group messages | `null` / `"B"` |

Hidden/skip for prototype: `quote`, `reactions`, `file*`, `viewType` (assume `"Text"`), `showPadlock`/email icon, `isEdited` ("edited" label), `isForwarded`, `savedMessageId` (bookmark icon), `downloadState` (assume `"Done"`), `hasHtml`, `systemMessageType`/`infoContactId` (info-message interactivity), read-receipt ViewCount (OutBroadcast only).

Notes:
- Outgoing messages never show author/avatar; incoming 1:1 messages don't either.
- Unread marking: each incoming message with state `IN_FRESH`/`IN_NOTICED` gets an observer; when visible & window focused → `markseenMsgs(accountId, [msgIds])`.
- `ChatVM` needs at minimum: `id`, `name`, `chatType` (or just `hasMultipleParticipants: bool` = chatType != Single), `canSend: bool`, `isContactRequest: bool`, `freshMessageCounter` (for jump-down badge, optional).

---

## 3. Composer

Source files:
- `packages/frontend/src/components/composer/Composer.tsx`
- `packages/frontend/src/hooks/chat/useDraft.ts` (`DraftObject`)

For text-only, the composer state reduces to:

### Proposed DTO: `DraftVM`
| Field | Type | Notes | Example |
|---|---|---|---|
| `chatId` | u32 | which chat the draft belongs to (guards stale updates) | `12` |
| `text` | string | textarea content; send button shown iff `text.length > 0` | `"typing…"` |

Behavior worth copying:
- On chat open: `getDraft(accountId, chatId)` → populate text (`draftIsLoading` flag while fetching).
- On typing: update local state immediately; persist with `miscSetDraft(accountId, chatId, text, null, null, null, 'Text')` **debounced 15 s**, flushed on chat switch/unmount and on app-hidden (`visibilitychange`). Empty draft → `removeDraft`.
- On send: `miscSendTextMessage`-equivalent (desktop uses `sendMsg` via `useMessage().sendMessage` with `{text, viewtype:'Text'}`); clear local draft state *immediately* (prevents double-send), then `removeDraft(accountId, chatId)` after success; restore draft state on failure.
- Contact-request chats render Accept / Block buttons instead of the composer (`acceptChat` / `blockChat`); `!chat.canSend` renders nothing.
- Everything else (quote, attachments, stickers, voice, edit-mode, emoji picker) can be ignored.

---

## 4. Login screen (classic email)

Source files:
- `packages/frontend/src/components/screens/AccountSetupScreen.tsx`
- `packages/frontend/src/components/LoginForm.tsx`
- `packages/frontend/src/components/Settings/DefaultCredentials.ts` (`Credentials = T.EnteredLoginParam`)
- `packages/frontend/src/components/dialogs/ConfigureProgressDialog.tsx`

### Proposed DTO: `LoginVM` (minimal)
| Field | Type | Example |
|---|---|---|
| `addr` | string | `"alice@example.org"` |
| `password` | string | `"hunter2"` |

The full `EnteredLoginParam` has advanced fields you can default to null and skip in the UI: `imapUser, imapServer, imapPort, imapSecurity ('automatic'|'plain'|'ssl'|'starttls'), certificateChecks ('automatic'|'strict'|'acceptInvalidCertificates'), smtpUser, smtpPassword, smtpServer, smtpPort, smtpSecurity, oauth2` (they're hidden behind a "More options" collapse). Provider hint (`getProviderInfo`) is optional polish.

Configure flow (`ConfigureProgressDialog`):
1. Call `addOrUpdateTransport(accountId, credentials)` (this both stores params and configures; it's the modern replacement for `setConfig`+`configure`).
2. While waiting, subscribe to core event `ConfigureProgress { progress: 0..1000, comment: string | null }` → render a progress bar (`progress/10 %`) plus the comment text underneath. `progress === 0` means error (UI ignores 0 for the bar).
3. Cancel button → `stopOngoingProcess(accountId)`.
4. On promise resolve → success (select account / enter main screen); on reject → show error string in an alert.

### Proposed DTO: `ConfigureProgressVM`
| Field | Type | Example |
|---|---|---|
| `progress` | u32 (0–1000) | `600` |
| `comment` | string | `"Connecting to IMAP…"` |

---

## 5. When the frontend refreshes (event → reload wiring)

Events arrive per-account via `BackendRemote.getContextEvents(accountId).on(eventName, cb)` (helper `onDCEvent(accountId, event, cb)` in `packages/frontend/src/backend-com.ts`); these are core jsonrpc notification events.

### Chat list
- **`ChatlistChanged`** (no payload beyond account) → refetch the *ordering*: `getChatlistEntries` (throttled 200 ms). (`useChatListSimple` in `components/chat/ChatListHelpers.tsx:200`)
- **`ChatlistItemChanged { chatId }`** → refetch a *single row*: `getChatlistItemsByEntries(accountId, [chatId])`, with per-chat debouncing; `chatId === null` → invalidate the whole row cache and reload visible rows; `DC_CHAT_ID_TRASH` ignored. (`components/chat/ChatList.tsx:837`)
- Unread badge sources: `IncomingMsg` + `MsgsNoticed` → `getFreshMsgCnt` (per-chat, `useUnreadCount` in `MessageList.tsx`).

### Message list (only if event's `chatId` == selected chat; store in `stores/messagelist.ts:113-184`)
- **`IncomingMsg { chatId }`** → queued incremental refresh: refetch `getMessageListItems`, append new tail, scroll to bottom if already there (+ notification sound).
- **`MsgsChanged { chatId, msgId }`** →
  - `chatId === 0` or `msgId === 0` → full `refresh()` of the list;
  - known `msgId` → `getMessage` and replace in cache (edit/state change);
  - unknown `msgId` → refetch list items and append (covers info messages, own multi-device sends);
  - draft-state messages are ignored (prevents scroll jumps).
- **`MsgDelivered { chatId, msgId }`** → in-place set state to `DC_STATE_OUT_DELIVERED` (no refetch).
- **`MsgRead { chatId, msgId }`** → in-place set state to `DC_STATE_OUT_MDN_RCVD`.
- **`MsgFailed { chatId, msgId }`** → refetch that message (to get the `error` string).
- (`ReactionsChanged` mirrors `MsgsChanged` — skip for prototype.)
- **`MsgDeleted`** is only handled for search results; normal deletion arrives as `MsgsChanged`/`ChatlistItemChanged`.

Minimal prototype rule of thumb: `ChatlistChanged` → reload chat list order; `ChatlistItemChanged(chatId)` → reload one row; for the open chat: `IncomingMsg`/`MsgsChanged` → reload/append messages, `MsgDelivered`/`MsgRead` → patch a single message's `state` in place; `ConfigureProgress` → login progress bar.