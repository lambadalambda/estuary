# deltachat-core Rust API map for the native viewmodel crate

**Checkout inspected:** `/Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust`, package `deltachat` **version 2.44.0** (workspace `Cargo.toml`). The target git tag is **v2.49.0** — everything below was verified against 2.44.0 source; the APIs listed are the current (post-"transports refactor") surface and are stable in the 2.4x line, but re-verify signatures against the v2.49.0 tag when the crate first compiles (notably `configure()` is already marked deprecated in 2.44.0 and could disappear).

All types below are `use deltachat::...` paths. Everything is async on tokio; all fallible functions return `anyhow::Result<T>` (core re-exports nothing special — add `anyhow` to your own deps).

---

## 1. Accounts manager

Module: `deltachat::accounts` (src/accounts.rs)

```rust
pub struct Accounts { /* private */ }   // Debug, NOT Clone

impl Accounts {
    pub async fn new(dir: PathBuf, writable: bool) -> Result<Self>;
    pub async fn new_with_events(dir: PathBuf, writable: bool, events: Events) -> Result<Self>;
    pub fn get_account(&self, id: u32) -> Option<Context>;          // Context is a cheap Arc clone
    pub fn get_selected_account(&self) -> Option<Context>;
    pub fn get_selected_account_id(&self) -> Option<u32>;
    pub async fn select_account(&mut self, id: u32) -> Result<()>;
    pub async fn add_account(&mut self) -> Result<u32>;             // creates db, opens it, emits AccountsChanged
    pub async fn add_closed_account(&mut self) -> Result<u32>;
    pub async fn remove_account(&mut self, id: u32) -> Result<()>;
    pub async fn migrate_account(&mut self, dbfile: PathBuf) -> Result<u32>;
    pub fn get_all(&self) -> Vec<u32>;                              // list account ids
    pub async fn start_io(&mut self);                               // start network IO for all accounts
    pub async fn stop_io(&self);
    pub async fn maybe_network(&self);
    pub async fn maybe_network_lost(&self);
    pub fn get_event_emitter(&self) -> EventEmitter;                // ONE emitter for ALL accounts
    pub fn emit_event(&self, event: EventType);
}
```

Notes:
- `Accounts::new(dir, true)` creates `dir` and an `accounts.toml` inside if missing; errors if dir exists non-empty without config. Each account lives in `dir/<uuid>/dbfile` (blobdir auto-created next to db as `<dbfile>-blobs`).
- Mutating methods take `&mut self`, so you need external synchronization.

**Initialization pattern used by deltachat-rpc-server** (`deltachat-rpc-server/src/main.rs:75-86`) — copy this:

```rust
#[tokio::main(flavor = "multi_thread")]
async fn main() { ... }

let accounts = Accounts::new(PathBuf::from(&path), /*writable=*/true).await?;
let accounts = Arc::new(tokio::sync::RwLock::new(accounts));
// deltachat-jsonrpc's CommandApi::from_arc then grabs the emitter:
let event_emitter = Arc::new(accounts.read().await.get_event_emitter());
```

So the canonical shared handle is `Arc<RwLock<Accounts>>` (tokio RwLock): `read()` for `get_account`/`get_all`, `write()` for `add_account`/`select_account`/`start_io`. Individual `Context` handles obtained from it are cloned out and used without the lock.

Also relevant: `deltachat::context::ContextBuilder` (src/context.rs) if you ever want a single account without the manager: `ContextBuilder::new(dbfile: PathBuf) -> Self`, `.with_id(u32)`, `.with_events(Events)`, `.with_stock_strings(StockStrings)`, `.with_password(String)`, then `.build().await -> Result<Context>` (closed) or `.open().await -> Result<Context>` (opened, empty passphrase).

Low-level: `Context::new(dbfile: &Path, id: u32, events: Events, stock_strings: StockStrings) -> Result<Context>` — creates AND opens (unencrypted) the db; this is exactly what `TestContext` uses internally.

## 2. Configure / login (classic email)

Module: `deltachat::config` (src/config.rs) — `pub enum Config` (strum, snake_case serialized). Relevant variants:
- `Config::Addr` — email address (`From:`)
- `Config::MailPw` — IMAP password (also used for SMTP unless `SendPw` set)
- `Config::MailServer`, `Config::MailUser`, `Config::MailPort`, `Config::MailSecurity` — optional manual IMAP settings
- `Config::SendServer`, `Config::SendUser`, `Config::SendPw`, `Config::SendPort` — optional manual SMTP
- `Config::Displayname`, `Config::BccSelf`, `Config::Bot`, `Config::Configured` (read-only flag), `Config::ConfiguredAddr` (see testing, section 9)

Context methods (src/config.rs):
```rust
pub async fn set_config(&self, key: Config, value: Option<&str>) -> Result<()>;
pub async fn get_config(&self, key: Config) -> Result<Option<String>>;
pub async fn get_config_bool(&self, key: Config) -> Result<bool>;
pub async fn set_config_bool(&self, key: Config, value: bool) -> Result<()>;
pub async fn set_config_u32(&self, key: Config, value: u32) -> Result<()>;
```

Configure entrypoints (src/configure.rs, all on `Context`):
```rust
pub async fn is_configured(&self) -> Result<bool>;
pub async fn configure(&self) -> Result<()>;   // DEPRECATED since 2025-02; reads Config::Addr, MailPw, Mail*/Send* via EnteredLoginParam::load()
pub async fn add_or_update_transport(&self, param: &mut EnteredLoginParam) -> Result<()>;  // PREFERRED; stops/starts IO itself
pub async fn add_transport_from_qr(&self, qr: &str) -> Result<()>;
pub async fn list_transports(&self) -> Result<Vec<EnteredLoginParam>>;
pub async fn delete_transport(&self, addr: &str) -> Result<()>;
```

`deltachat::login_param::EnteredLoginParam` (src/login_param.rs), all fields pub, `Default`:
```rust
pub struct EnteredLoginParam {
    pub addr: String,
    pub imap: EnteredServerLoginParam,   // { server: String, port: u16, security: Socket, user: String, password: String }
    pub smtp: EnteredServerLoginParam,
    pub certificate_checks: EnteredCertificateChecks, // Automatic(default) | Strict | AcceptInvalidCertificates
    pub oauth2: bool,
}
```
(`Socket` enum lives in `deltachat::provider::Socket`: Automatic/Ssl/Starttls/Plain.)

**Recommended flow** (this is what jsonrpc's `add_or_update_transport` does): build `EnteredLoginParam { addr, imap: EnteredServerLoginParam { password, ..Default::default() }, ..Default::default() }` and call `ctx.add_or_update_transport(&mut param).await`. Autoconfig fills in the rest. Progress is observed via `EventType::ConfigureProgress { progress: u16, comment: Option<String> }` — 0=error, 1..=999 permille progress, 1000=success. The deprecated `set_config(Addr/MailPw)` + `configure()` path still works in 2.44.0 (jsonrpc wraps it with manual `stop_io`/`start_io`; `add_or_update_transport` handles IO itself).

## 3. Event stream

Module: `deltachat::events` (src/events.rs + src/events/payload.rs). Re-exported at crate root: `deltachat::{Event, EventType, EventEmitter, Events}`.

```rust
pub struct Events;                       // Clone; broadcast channel, capacity 10_000, overflow drops oldest
impl Events { pub fn new() -> Self; pub fn emit(&self, event: Event); pub fn get_emitter(&self) -> EventEmitter; }

pub struct Event { pub id: u32 /* account/context id, 0 = accounts manager */, pub typ: EventType }

pub struct EventEmitter(/* Mutex<async_broadcast::Receiver> */);   // NOT Clone
impl EventEmitter {
    pub async fn recv(&self) -> Option<Event>;        // None = sender dropped; overflow yields EventType::EventChannelOverflow { n }
    pub fn try_recv(&self) -> Result<Event>;
    pub async fn recv_batch(&self) -> Vec<Event>;     // 1..=~101 events per call
}
```

Get it via `Accounts::get_event_emitter()` (all accounts share one `Events` channel; discriminate by `event.id`) or per-context `Context::get_event_emitter()`. Note: the doc-comment on `EventEmitter` claims multiple emitters split events, but the implementation is `async_broadcast` (`sender.new_receiver()`), so each emitter actually receives every event; still, use ONE long-lived emitter task like the official clients do.

**How deltachat-jsonrpc forwards events** (`deltachat-jsonrpc/src/api.rs:104-119, 188-203`): `CommandApi` stores `Arc<EventEmitter>` created once from `accounts.get_event_emitter()`; clients poll `get_next_event()` = `self.event_emitter.recv().await` (or `recv_batch`), converting each `Event` to a serializable mirror type. For your viewmodel: spawn one `tokio::task` looping `emitter.recv().await` and dispatch into your own broadcast/watch channels.

Relevant `EventType` variants (exact, from src/events/payload.rs):
```rust
EventType::IncomingMsg { chat_id: ChatId, msg_id: MsgId }        // fresh incoming message -> notify
EventType::IncomingMsgBunch                                       // batch download finished
EventType::MsgsChanged { chat_id: ChatId, msg_id: MsgId }        // 0-ids mean "multiple"
EventType::MsgsNoticed(ChatId)
EventType::MsgDelivered { chat_id: ChatId, msg_id: MsgId }
EventType::MsgRead { chat_id: ChatId, msg_id: MsgId }
EventType::MsgFailed { chat_id: ChatId, msg_id: MsgId }
EventType::MsgDeleted { chat_id: ChatId, msg_id: MsgId }
EventType::ChatlistChanged
EventType::ChatlistItemChanged { chat_id: Option<ChatId> }       // None = rerender all visible
EventType::ConfigureProgress { progress: u16, comment: Option<String> }
EventType::ConnectivityChanged                                    // then query ctx connectivity
EventType::AccountsChanged                                        // emitted by the manager (event.id == 0)
EventType::AccountsItemChanged
EventType::Info(String) / Warning(String) / Error(String)
EventType::EventChannelOverflow { n: u64 }
```
(`ChatId` = `deltachat::chat::ChatId`, `MsgId` = `deltachat::message::MsgId`; both are `Copy` u32 newtypes with serde.)

Connectivity detail: `Context::get_connectivity()` / `get_connectivity_html()` in src/scheduler (exposed on Context; returns `deltachat::net::Connectivity`-style enum — check `Context::get_connectivity` when wiring, it's what jsonrpc's `get_connectivity` calls).

## 4. Chat list

Module: `deltachat::chatlist` (src/chatlist.rs)

```rust
pub struct Chatlist { /* ids: Vec<(ChatId, Option<MsgId>)> */ }

impl Chatlist {
    pub async fn try_load(context: &Context, listflags: usize,
                          query: Option<&str>, query_contact_id: Option<ContactId>) -> Result<Self>;
    pub fn len(&self) -> usize;
    pub fn is_empty(&self) -> bool;
    pub fn get_chat_id(&self, index: usize) -> Result<ChatId>;
    pub fn get_msg_id(&self, index: usize) -> Result<Option<MsgId>>;   // last msg of that chat
    pub async fn get_summary(&self, context: &Context, index: usize, chat: Option<&Chat>) -> Result<Summary>;
    pub async fn get_summary2(context: &Context, chat_id: ChatId, lastmsg_id: Option<MsgId>, chat: Option<&Chat>) -> Result<Summary>;  // associated fn, for single-item refresh
    pub fn get_index_for_id(&self, id: ChatId) -> Option<usize>;
    pub fn iter(&self) -> impl Iterator<Item = &(ChatId, Option<MsgId>)>;
}
```
List flags in `deltachat::constants`: `DC_GCL_ARCHIVED_ONLY: usize = 0x01`, `DC_GCL_NO_SPECIALS = 0x02`, `DC_GCL_ADD_ALLDONE_HINT = 0x04`, `DC_GCL_FOR_FORWARDING = 0x08`. Pass `0` for the normal list. Query supports `is:unread`.

Summary type — `deltachat::summary::Summary` (src/summary.rs), fields pub:
```rust
pub struct Summary {
    pub prefix: Option<SummaryPrefix>,   // Username(String) | Draft(String) | Me(String); impl Display
    pub text: String,
    pub timestamp: i64,
    pub state: MessageState,
    pub thumbnail_path: Option<String>,
}
```

Chat object — `deltachat::chat::Chat` (src/chat.rs:1325):
```rust
pub struct Chat {
    pub id: ChatId,
    pub typ: Chattype,               // deltachat::constants::Chattype: Single/Group/Mailinglist/OutBroadcast/InBroadcast...
    pub name: String,
    pub visibility: ChatVisibility,  // Normal/Archived/Pinned
    pub grpid: String,
    pub blocked: Blocked,
    pub param: Params,
    pub mute_duration: MuteDuration,
    // is_sending_locations private
}
impl Chat {
    pub async fn load_from_db(context: &Context, chat_id: ChatId) -> Result<Self>;
    pub fn get_name(&self) -> &str;
    pub fn is_self_talk(&self) -> bool;    // "Saved Messages"
    pub fn is_device_talk(&self) -> bool;
    // also: get_profile_image, get_color, is_muted, why_cant_send, ...
}
```

Unread counts / mark read (per chat):
```rust
// on ChatId (Copy):
impl ChatId {
    pub async fn get_fresh_msg_cnt(self, context: &Context) -> Result<usize>;  // chat.rs:872, badge counter
    pub async fn get_msg_cnt(self, context: &Context) -> Result<usize>;
}
// free function:
pub async fn deltachat::chat::marknoticed_chat(context: &Context, chat_id: ChatId) -> Result<()>;  // chat.rs:3251 -> emits MsgsNoticed
```

## 5. Messages

```rust
// deltachat::chat
pub async fn get_chat_msgs(context: &Context, chat_id: ChatId) -> Result<Vec<ChatItem>>;   // chat.rs:3094
pub async fn get_chat_msgs_ex(context: &Context, chat_id: ChatId, options: MessageListOptions) -> Result<Vec<ChatItem>>; // MessageListOptions { info_only: bool, add_daymarker: bool }

pub enum ChatItem {                       // deltachat::chat::ChatItem
    Message { msg_id: MsgId },
    DayMarker { timestamp: i64 },
}
```

`deltachat::message` (src/message.rs):
```rust
pub struct MsgId(u32);  // Copy; MsgId::new(u32), .to_u32()
pub struct Message { /* fields pub(crate) — use getters */ }

impl Message {
    pub fn new(viewtype: Viewtype) -> Self;
    pub fn new_text(text: String) -> Self;
    pub async fn load_from_db(context: &Context, id: MsgId) -> Result<Message>;
    pub async fn load_from_db_optional(context: &Context, id: MsgId) -> Result<Option<Message>>; // prefer: msg may vanish
    pub fn get_id(&self) -> MsgId;
    pub fn get_text(&self) -> String;
    pub fn set_text(&mut self, text: String);
    pub fn get_timestamp(&self) -> i64;         // sort timestamp (smeared unix seconds)
    pub fn get_from_id(&self) -> ContactId;     // outgoing iff == ContactId::SELF
    pub fn get_chat_id(&self) -> ChatId;
    pub fn get_state(&self) -> MessageState;
    pub fn get_viewtype(&self) -> Viewtype;
    pub fn get_filename(&self) -> Option<String>;
    pub fn get_showpadlock(&self) -> bool;
    pub fn is_info(&self) -> bool;
    pub fn set_file_and_deduplicate(&mut self, ...);  // for attachments later
}

pub enum MessageState {   // #[repr] ordered; Ord comparisons used in core
    Undefined = 0, InFresh = 10, InNoticed = 13, InSeen = 16,
    OutPreparing = 18, OutDraft = 19, OutPending = 20, OutFailed = 24,
    OutDelivered = 26, OutMdnRcvd = 28,   // OutMdnRcvd == "read"
}

pub enum Viewtype { Unknown = 0, Text = 10, Image = 20, Gif = 21, Sticker = 23,
                    Audio = 40, Voice = 41, Video = 50, File = 60, Call = 71,
                    Webxdc = 80, Vcard /*...*/ }
```
"Is outgoing": `msg.get_from_id() == ContactId::SELF`. "Delivered/read": `state >= MessageState::OutDelivered` / `== OutMdnRcvd`.

Marking messages seen (drives MDNs + MsgsNoticed): `deltachat::message::markseen_msgs(context: &Context, msg_ids: Vec<MsgId>) -> Result<()>` (exists in message.rs; verify exact name when compiling — the C API equivalent is dc_markseen_msgs).

## 6. Sending

```rust
// deltachat::chat
pub async fn send_text_msg(context: &Context, chat_id: ChatId, text_to_send: String) -> Result<MsgId>;  // chat.rs:2986; rejects special chat ids
pub async fn send_msg(context: &Context, chat_id: ChatId, msg: &mut Message) -> Result<MsgId>;          // chat.rs:2617
```
Chat creation: `ChatId::create_for_contact(context: &Context, contact_id: ContactId) -> Result<ChatId>` (chat.rs:232); `deltachat::chat::create_group(context, name: &str) -> Result<ChatId>` (encrypted group), `create_group_unencrypted`, `create_broadcast(context, chat_name: String)`.

## 7. Contacts

`deltachat::contact` (src/contact.rs):
```rust
pub struct ContactId(u32);   // Copy; ContactId::new(u32)
impl ContactId {
    pub const UNDEFINED: ContactId = ContactId::new(0);
    pub const SELF: ContactId      = ContactId::new(1);
    pub const INFO: ContactId      = ContactId::new(2);
    pub const DEVICE: ContactId    = ContactId::new(5);
}

impl Contact {
    pub async fn get_by_id(context: &Context, contact_id: ContactId) -> Result<Self>;          // contact.rs:585
    pub async fn get_by_id_optional(context: &Context, contact_id: ContactId) -> Result<Option<Self>>;
    pub async fn create(context: &Context, name: &str, addr: &str) -> Result<ContactId>;       // contact.rs:712, works offline
    pub async fn lookup_id_by_addr(context: &Context, addr: &str, min_origin: Origin) -> Result<Option<ContactId>>;
    pub async fn get_all(context: &Context, listflags: u32, query: Option<&str>) -> Result<Vec<ContactId>>;
    pub fn get_display_name(&self) -> &str;   // name-to-show (authname/name/addr fallback)
    pub fn get_name(&self) -> &str;
    pub fn get_authname(&self) -> &str;
    pub fn get_addr(&self) -> &str;
}
```

## 8. Async runtime / thread-safety

- Runtime: **tokio multi-thread**. rpc-server uses `#[tokio::main(flavor = "multi_thread")]`. Core itself declares `tokio = { version = "1", features = ["fs", "rt-multi-thread", "macros"] }` (workspace pins `tokio = "1"`); dev-deps add `["rt-multi-thread", "macros"]`. Core internally spawns tasks (scheduler, IO) — a current-thread runtime is not recommended and IO requires the runtime to stay alive.
- `Context` is `#[derive(Clone, Debug)]` wrapping `Arc<InnerContext>` with `impl Deref<Target = InnerContext>` — cheap cloneable handle, Send + Sync (it is moved into `tokio::spawn` all over core). Clone freely into tasks.
- `Accounts` is NOT Clone; wrap in `Arc<tokio::sync::RwLock<Accounts>>` like rpc-server does. `Events` is Clone; `EventEmitter` is not Clone but is `Send + Sync` (internally `tokio::sync::Mutex<Receiver>`) — jsonrpc shares it as `Arc<EventEmitter>`.
- `ChatId`, `MsgId`, `ContactId` are `Copy + Serialize/Deserialize + Hash + Ord`.

## 9. Testability WITHOUT a mail server (TDD strategy)

- `src/test_utils.rs` (`TestContext`, `TestContextManager`) is **`#[cfg(test)]` only** (lib.rs:127 `mod test_utils;` under `#[cfg(test)]`) — NOT exported, NOT behind the `internals` feature. The `internals` feature only exposes `sql`, `pgp`, and `internals_for_benches`. So a downstream crate **cannot** use `TestContext`.
- BUT everything `TestContext` does is public API, and fully offline-capable:
  1. **Create a context offline**: `Context::new(&dbfile, id, Events::new(), StockStrings::new()).await` (exactly what `TestContext::new_internal` does), or `Accounts::new(tmpdir, true)` + `add_account()`. No network is touched until `start_io()`.
  2. **Pseudo-configure offline** (the key trick): `ctx.set_config(Config::ConfiguredAddr, Some("alice@example.org")).await?`. In config.rs (`set_config_ex`, ~line 798) this explicitly creates a "pseudo configured account which will not be able to send or receive messages. Only meant for tests!" via `add_pseudo_transport`. Afterwards `is_configured() == true`. This is public API (`set_config` + public `Config::ConfiguredAddr` variant) — exactly what `TestContext::configure_addr` calls.
  3. **Create chats/contacts offline**: `Contact::create(&ctx, "Bob", "bob@example.net")` then `ChatId::create_for_contact(&ctx, contact_id)`; self-chat via `ChatId::create_for_contact(&ctx, ContactId::SELF)` ("Saved Messages", `chat.is_self_talk()`); device chat via `deltachat::chat::add_device_msg(context, label: Option<&str>, msg: Option<&mut Message>) -> Result<MsgId>` (chat.rs:4844).
  4. **Send offline**: `send_text_msg` works on a pseudo-configured context — the message lands in the local DB (state OutPending, queued in the smtp table which never drains without IO) and appears in `get_chat_msgs`, chatlist, summaries. Do NOT call `start_io()` in tests.
  5. **Inject incoming messages offline**: `deltachat::receive_imf::receive_imf(context: &Context, imf_raw: &[u8], seen: bool) -> Result<Option<ReceivedMsg>>` (public module, src/receive_imf.rs:157) — feed raw RFC-822 bytes; fires `IncomingMsg` events, creates contacts/chats. This is how core's own tests simulate reception. `ReceivedMsg` has `chat_id`, `msg_ids` fields (pub).
- Conclusion: **full TDD offline is possible** — pseudo-configured Context + `receive_imf` for inbound + `send_text_msg` for outbound + real event assertions via `get_event_emitter()`. Use `tempfile::tempdir()` in your dev-deps for db dirs.

## 10. Cargo dependency snippet

Core features (`Cargo.toml [features]`): `default = ["vendored"]`, `vendored = ["rusqlite/bundled-sqlcipher-vendored-openssl", "async-native-tls/vendored"]`, `internals` (not needed). The workspace itself consumes deltachat with `default-features = false` and re-exposes `vendored` through jsonrpc/rpc-server (whose defaults enable it). Recommendation: keep `vendored` ON for a self-contained native app (bundled sqlcipher + vendored openssl), i.e. just use default features.

```toml
[dependencies]
deltachat = { git = "https://github.com/chatmail/core", tag = "v2.49.0" }  # default features = ["vendored"]
# or, to use system OpenSSL/sqlite: default-features = false
tokio = { version = "1", features = ["rt-multi-thread", "macros", "fs", "sync", "time"] }
anyhow = "1"            # core's Result type
futures = "0.3"         # optional, for stream utilities

[dev-dependencies]
tempfile = "3"
```

Pitfall: building `deltachat` pulls a heavy native dep tree (rusqlite/sqlcipher, rustls/ring, rPGP). First build is slow; nothing else special is required on macOS.

---

### Minimal prototype skeleton (verbatim pattern from rpc-server + jsonrpc)

```rust
use std::{path::PathBuf, sync::Arc};
use deltachat::accounts::Accounts;
use deltachat::config::Config;
use deltachat::{EventType};
use tokio::sync::RwLock;

let accounts = Accounts::new(PathBuf::from(data_dir), true).await?;
let emitter = accounts.get_event_emitter();
let accounts = Arc::new(RwLock::new(accounts));

tokio::spawn(async move {
    while let Some(event) = emitter.recv().await {
        match event.typ {
            EventType::IncomingMsg { chat_id, msg_id } => { /* event.id = account id */ }
            EventType::ChatlistChanged | EventType::ChatlistItemChanged { .. } => { }
            EventType::ConfigureProgress { progress, comment } => { }
            EventType::ConnectivityChanged => { }
            _ => {}
        }
    }
});

let id = accounts.write().await.add_account().await?;
accounts.write().await.select_account(id).await?;
let ctx = accounts.read().await.get_account(id).unwrap();  // Context, Clone

// login (classic email):
let mut p = deltachat::login_param::EnteredLoginParam {
    addr: addr.into(),
    imap: deltachat::login_param::EnteredServerLoginParam { password: pw.into(), ..Default::default() },
    ..Default::default()
};
ctx.add_or_update_transport(&mut p).await?;   // emits ConfigureProgress; handles IO
accounts.write().await.start_io().await;
```

Key source files (absolute paths):
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/src/accounts.rs
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/src/context.rs
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/src/config.rs, src/configure.rs, src/login_param.rs
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/src/events.rs, src/events/payload.rs
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/src/chatlist.rs, src/summary.rs, src/chat.rs, src/message.rs, src/contact.rs, src/receive_imf.rs, src/test_utils.rs
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/deltachat-rpc-server/src/main.rs
- /Users/lainsoykaf/repos/deltachat/deltachat-ios/deltachat-ios/libraries/deltachat-core-rust/deltachat-jsonrpc/src/api.rs