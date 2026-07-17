//! The exported `DcApp` object: thin async glue between UniFFI and deltachat core.

use std::future::Future;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};

use deltachat::accounts::Accounts;
use deltachat::chat::{
    self, Chat, ChatId, ChatItem as CoreChatItem, ChatVisibility,
};
use deltachat::chatlist::Chatlist;
use deltachat::config::Config;
use deltachat::constants::{Chattype, DC_GCL_ADDRESS, DC_GCL_ARCHIVED_ONLY};
use deltachat::contact::{Contact, ContactId};
use deltachat::context::Context;
use deltachat::login_param::{EnteredImapLoginParam, EnteredLoginParam};
use deltachat::message::{self, Message, MsgId, Viewtype};
use deltachat::reaction;
use deltachat::receive_imf::receive_imf;
use deltachat::EventType;
use tokio::sync::RwLock;

use crate::mapping::{
    color_to_hex, map_event, map_message_state, map_qr, map_viewtype, summary_preview,
    viewtype_for_path,
};
use crate::types::{
    AccountInfo, ChatItem, ContactItem, MessageItem, QrKind, QuoteInfo, ReactionItem, VmError,
    VmEvent,
};

/// Default chatmail relay used for instant account creation. A client-side
/// choice (core has no default); same instance the official clients use.
pub const DEFAULT_CHATMAIL_INSTANCE: &str = "https://nine.testrun.org/new";

/// Exposed to shells so alternate relays can be offered next to the default.
#[uniffi::export]
pub fn default_instance_url() -> String {
    DEFAULT_CHATMAIL_INSTANCE.to_string()
}

/// Global runtime: the event pump and all core work live here, so behavior is
/// identical whether methods are driven by Swift (UniFFI) or by Rust tests.
static RT: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("tokio runtime")
});

/// Bridge a future onto the global runtime (see uniffi-recipe.md section 2).
async fn on_rt<T, F>(fut: F) -> Result<T, VmError>
where
    T: Send + 'static,
    F: Future<Output = Result<T, VmError>> + Send + 'static,
{
    RT.spawn(fut).await.map_err(|e| VmError::Core {
        msg: format!("runtime join error: {e}"),
    })?
}

/// Implemented by Swift; called from tokio worker threads.
#[uniffi::export(foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, account_id: u32, event: VmEvent) -> Result<(), VmError>;
}

#[derive(uniffi::Object)]
pub struct DcApp {
    accounts: Arc<RwLock<Accounts>>,
    /// Cache so `selected_account()` can stay sync (contract: "sync ok").
    selected: Arc<Mutex<Option<u32>>>,
}

async fn get_ctx(accounts: &RwLock<Accounts>, account_id: u32) -> Result<Context, VmError> {
    accounts
        .read()
        .await
        .get_account(account_id)
        .ok_or_else(|| VmError::Core {
            msg: format!("no such account: {account_id}"),
        })
}

fn path_string(path: std::path::PathBuf) -> String {
    path.to_string_lossy().into_owned()
}

/// One chat row from a loaded Chat + its summary (shared by list and by-id).
async fn build_chat_item(
    ctx: &Context,
    chat_id: ChatId,
    chat: &Chat,
    summary: &deltachat::summary::Summary,
) -> Result<ChatItem, VmError> {
    Ok(ChatItem {
        id: chat_id.to_u32(),
        name: chat.get_name().to_string(),
        preview: summary_preview(summary.prefix.as_ref(), &summary.text),
        timestamp: summary.timestamp,
        fresh_count: chat_id.get_fresh_msg_cnt(ctx).await? as u32,
        is_self_talk: chat.is_self_talk(),
        is_pinned: chat.visibility == ChatVisibility::Pinned,
        is_muted: chat.is_muted(),
        is_contact_request: chat.is_contact_request(),
        color: color_to_hex(chat.get_color(ctx).await?),
        is_group: chat.typ != Chattype::Single,
        is_archived: chat.visibility == ChatVisibility::Archived,
        is_device_talk: chat.is_device_talk(),
        avatar: chat.get_profile_image(ctx).await?.map(path_string),
    })
}

/// Loads chat rows for the given chatlist flags / search query.
async fn chat_items(
    ctx: &Context,
    listflags: usize,
    query: Option<&str>,
) -> Result<Vec<ChatItem>, VmError> {
    let chatlist = Chatlist::try_load(ctx, listflags, query, None).await?;
    let mut out = Vec::with_capacity(chatlist.len());
    for index in 0..chatlist.len() {
        let chat_id = chatlist.get_chat_id(index)?;
        if chat_id.is_special() {
            continue; // e.g. the "archived chats" pseudo-row
        }
        let chat = Chat::load_from_db(ctx, chat_id).await?;
        let summary = chatlist.get_summary(ctx, index, Some(&chat)).await?;
        out.push(build_chat_item(ctx, chat_id, &chat, &summary).await?);
    }
    Ok(out)
}

/// Full message row incl. media metadata, quote, and aggregated reactions.
async fn message_item(ctx: &Context, msg: &Message) -> Result<MessageItem, VmError> {
    let from_id = msg.get_from_id();
    let sender = Contact::get_by_id(ctx, from_id).await?;

    let quote = match msg.quoted_text() {
        None => None,
        Some(text) => {
            let (sender_name, sender_color) = match msg.quoted_message(ctx).await? {
                Some(quoted) => {
                    let contact = Contact::get_by_id(ctx, quoted.get_from_id()).await?;
                    (
                        contact.get_display_name().to_string(),
                        color_to_hex(contact.get_color()),
                    )
                }
                None => (String::new(), "#999999".to_string()),
            };
            Some(QuoteInfo {
                text,
                sender_name,
                sender_color,
            })
        }
    };

    // v2.53: one reaction (single emoji) per contact.
    let mut reactions: Vec<ReactionItem> = Vec::new();
    let msg_reactions = reaction::get_msg_reactions(ctx, msg.get_id()).await?;
    for contact_id in msg_reactions.contacts() {
        let contact_reaction = msg_reactions.get(contact_id);
        let emoji = contact_reaction.as_str();
        if emoji.is_empty() {
            continue;
        }
        match reactions.iter_mut().find(|r| r.emoji == emoji) {
            Some(entry) => {
                entry.count += 1;
                entry.is_from_self |= contact_id == ContactId::SELF;
            }
            None => reactions.push(ReactionItem {
                emoji: emoji.to_string(),
                count: 1,
                is_from_self: contact_id == ContactId::SELF,
            }),
        }
    }

    Ok(MessageItem {
        id: msg.get_id().to_u32(),
        chat_id: msg.get_chat_id().to_u32(),
        text: msg.get_text(),
        timestamp: msg.get_timestamp(),
        is_outgoing: from_id == ContactId::SELF,
        is_info: msg.is_info(),
        sender_name: sender.get_display_name().to_string(),
        sender_color: color_to_hex(sender.get_color()),
        sender_avatar: sender.get_profile_image(ctx).await?.map(path_string),
        state: map_message_state(msg.get_state()),
        kind: map_viewtype(msg.get_viewtype()),
        file: msg.get_file(ctx).map(path_string),
        file_name: msg.get_filename(),
        file_size: msg.get_filebytes(ctx).await?.unwrap_or(0),
        width: msg.get_width().max(0) as u32,
        height: msg.get_height().max(0) as u32,
        duration_ms: msg.get_duration().max(0) as u32,
        quote,
        reactions,
    })
}

#[uniffi::export(async_runtime = "tokio")]
impl DcApp {
    /// Opens (or creates) the accounts dir and starts the event pump.
    #[uniffi::constructor]
    pub async fn new(
        data_dir: String,
        listener: Arc<dyn EventListener>,
    ) -> Result<Arc<Self>, VmError> {
        on_rt(async move {
            let accounts = Accounts::new(PathBuf::from(&data_dir), true).await?;
            let emitter = accounts.get_event_emitter();
            let selected = Arc::new(Mutex::new(accounts.get_selected_account_id()));
            let accounts = Arc::new(RwLock::new(accounts));

            // Weak, or the pump would keep `Accounts` (and with it the event
            // sender inside core's `Events`) alive forever: pump -> Accounts
            // -> sender -> channel never closes -> pump never exits. With the
            // cycle, a dropped DcApp leaks every Context and holds the
            // accounts.lock, so no new DcApp could ever open the data dir.
            let pump_accounts = Arc::downgrade(&accounts);
            RT.spawn(async move {
                while let Some(event) = emitter.recv().await {
                    match event.typ {
                        // Core's broadcast channel dropped events (capacity
                        // 10_000, drop-oldest). We cannot know what was lost —
                        // possibly ConfigureProgress or the last
                        // ChatlistChanged — so synthesize a full refresh:
                        // accounts plus every account's chat list.
                        EventType::EventChannelOverflow { .. } => {
                            let Some(accounts) = pump_accounts.upgrade() else {
                                break;
                            };
                            let _ = listener.on_event(0, VmEvent::AccountsChanged);
                            for id in accounts.read().await.get_all() {
                                let _ = listener.on_event(id, VmEvent::ChatlistChanged);
                            }
                        }
                        typ => {
                            if let Some(vm_event) = map_event(typ) {
                                // Listener errors are ignored by design; only a
                                // closed channel (None above) stops the pump.
                                let _ = listener.on_event(event.id, vm_event);
                            }
                        }
                    }
                }
            });

            Ok(Arc::new(Self { accounts, selected }))
        })
        .await
    }

    pub async fn accounts(&self) -> Result<Vec<AccountInfo>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ids = accounts.read().await.get_all();
            let mut out = Vec::with_capacity(ids.len());
            for id in ids {
                let Ok(ctx) = get_ctx(&accounts, id).await else {
                    continue;
                };
                let addr = match ctx.get_config(Config::ConfiguredAddr).await? {
                    Some(addr) => Some(addr),
                    None => ctx.get_config(Config::Addr).await?,
                };
                out.push(AccountInfo {
                    id,
                    addr,
                    display_name: ctx.get_config(Config::Displayname).await?,
                    is_configured: ctx.is_configured().await?,
                    avatar: ctx.get_config(Config::Selfavatar).await?,
                });
            }
            Ok(out)
        })
        .await
    }

    pub async fn add_account(&self) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        let selected = self.selected.clone();
        on_rt(async move {
            let mut guard = accounts.write().await;
            let id = guard.add_account().await?;
            *selected.lock().unwrap() = guard.get_selected_account_id();
            Ok(id)
        })
        .await
    }

    /// Removes an account and deletes its data. Core reassigns the selection
    /// (or clears it) — the cache is refreshed afterwards.
    pub async fn remove_account(&self, id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        let selected = self.selected.clone();
        on_rt(async move {
            let mut guard = accounts.write().await;
            guard.remove_account(id).await?;
            *selected.lock().unwrap() = guard.get_selected_account_id();
            Ok(())
        })
        .await
    }

    pub async fn select_account(&self, id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        let selected = self.selected.clone();
        on_rt(async move {
            let mut guard = accounts.write().await;
            guard.select_account(id).await?;
            *selected.lock().unwrap() = guard.get_selected_account_id();
            Ok(())
        })
        .await
    }

    pub fn selected_account(&self) -> Option<u32> {
        *self.selected.lock().unwrap()
    }

    /// Stores credentials and configures the account (autoconfig fills in the
    /// rest). Progress arrives as `ConfigureProgress` events.
    pub async fn login(
        &self,
        account_id: u32,
        addr: String,
        password: String,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let mut param = EnteredLoginParam {
                addr,
                imap: EnteredImapLoginParam {
                    password,
                    ..Default::default()
                },
                ..Default::default()
            };
            ctx.add_or_update_transport(&mut param).await?;
            Ok(())
        })
        .await
    }

    pub async fn start_io(&self) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            accounts.write().await.start_io().await;
            Ok(())
        })
        .await
    }

    pub async fn stop_io(&self) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            accounts.read().await.stop_io().await;
            Ok(())
        })
        .await
    }

    pub async fn chat_list(&self, account_id: u32) -> Result<Vec<ChatItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            chat_items(&ctx, 0, None).await
        })
        .await
    }

    /// Single fresh chat row by id — for notification decisions and other
    /// point lookups where fetching whole lists would be wasteful or stale.
    /// Returns None for unknown/deleted chats.
    pub async fn chat_by_id(
        &self,
        account_id: u32,
        chat_id: u32,
    ) -> Result<Option<ChatItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let chat_id = ChatId::new(chat_id);
            // No _optional variant for Chat; a missing/deleted chat is an
            // expected outcome here, not an error.
            let Ok(chat) = Chat::load_from_db(&ctx, chat_id).await else {
                return Ok(None);
            };
            let last_msg_id = chat::get_chat_msgs(&ctx, chat_id)
                .await?
                .into_iter()
                .rev()
                .find_map(|item| match item {
                    CoreChatItem::Message { msg_id } => Some(msg_id),
                    _ => None,
                });
            let summary = Chatlist::get_summary2(&ctx, chat_id, last_msg_id, Some(&chat)).await?;
            Ok(Some(build_chat_item(&ctx, chat_id, &chat, &summary).await?))
        })
        .await
    }

    /// Archived chats only (the main list never contains them).
    pub async fn archived_chats(&self, account_id: u32) -> Result<Vec<ChatItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            chat_items(&ctx, DC_GCL_ARCHIVED_ONLY, None).await
        })
        .await
    }

    /// Chat list filtered by a search query (name/address substring).
    pub async fn search_chats(
        &self,
        account_id: u32,
        query: String,
    ) -> Result<Vec<ChatItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            chat_items(&ctx, 0, Some(&query)).await
        })
        .await
    }

    /// Global full-text message search, newest last, capped at 100 hits.
    pub async fn search_messages(
        &self,
        account_id: u32,
        query: String,
    ) -> Result<Vec<MessageItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let ids = ctx.search_msgs(None, &query).await?;
            let mut out = Vec::new();
            for msg_id in ids.into_iter().rev().take(100).rev() {
                if let Some(msg) = Message::load_from_db_optional(&ctx, msg_id).await? {
                    out.push(message_item(&ctx, &msg).await?);
                }
            }
            Ok(out)
        })
        .await
    }

    /// Loads messages, newest last. `limit == 0` means all. With
    /// `before_msg_id`, returns up to `limit` messages strictly older than
    /// that message (for loading history while scrolling up).
    pub async fn messages(
        &self,
        account_id: u32,
        chat_id: u32,
        limit: u32,
        before_msg_id: Option<u32>,
    ) -> Result<Vec<MessageItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            // Ids only — cheap; the expensive per-message loading below is
            // what pagination bounds.
            let mut ids: Vec<MsgId> = chat::get_chat_msgs(&ctx, ChatId::new(chat_id))
                .await?
                .into_iter()
                .filter_map(|item| match item {
                    CoreChatItem::Message { msg_id } => Some(msg_id),
                    _ => None,
                })
                .collect();
            if let Some(before) = before_msg_id {
                match ids.iter().position(|id| id.to_u32() == before) {
                    Some(pos) => ids.truncate(pos),
                    // Anchor gone (deleted elsewhere, ephemeral expiry):
                    // there is no stable "older than" answer. Empty beats
                    // returning the newest page again, which the caller
                    // would prepend as duplicates.
                    None => ids.clear(),
                }
            }
            if limit > 0 && ids.len() > limit as usize {
                ids.drain(..ids.len() - limit as usize);
            }
            let mut out = Vec::with_capacity(ids.len());
            for msg_id in ids {
                let Some(msg) = Message::load_from_db_optional(&ctx, msg_id).await? else {
                    continue;
                };
                out.push(message_item(&ctx, &msg).await?);
            }
            Ok(out)
        })
        .await
    }

    pub async fn send_text(
        &self,
        account_id: u32,
        chat_id: u32,
        text: String,
    ) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let msg_id = chat::send_text_msg(&ctx, ChatId::new(chat_id), text).await?;
            Ok(msg_id.to_u32())
        })
        .await
    }

    pub async fn mark_noticed(&self, account_id: u32, chat_id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            chat::marknoticed_chat(&ctx, ChatId::new(chat_id)).await?;
            Ok(())
        })
        .await
    }

    /// Creates (or finds) the contact and its 1:1 chat; returns the chat id.
    pub async fn create_chat(
        &self,
        account_id: u32,
        email: String,
        name: String,
    ) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let contact_id = Contact::create(&ctx, &name, &email).await?;
            let chat_id = ChatId::create_for_contact(&ctx, contact_id).await?;
            Ok(chat_id.to_u32())
        })
        .await
    }

    /// Sends text and/or a file attachment; `quoted_msg_id` makes it a reply.
    pub async fn send_message(
        &self,
        account_id: u32,
        chat_id: u32,
        text: Option<String>,
        file_path: Option<String>,
        quoted_msg_id: Option<u32>,
    ) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let viewtype = match &file_path {
                Some(path) => viewtype_for_path(path),
                None => Viewtype::Text,
            };
            let mut msg = Message::new(viewtype);
            if let Some(text) = text.filter(|t| !t.trim().is_empty()) {
                msg.set_text(text);
            }
            if let Some(path) = &file_path {
                msg.set_file_and_deduplicate(&ctx, std::path::Path::new(path), None, None)?;
            }
            if let Some(quoted_id) = quoted_msg_id {
                let quoted = Message::load_from_db(&ctx, MsgId::new(quoted_id)).await?;
                msg.set_quote(&ctx, Some(&quoted)).await?;
            }
            let msg_id = chat::send_msg(&ctx, ChatId::new(chat_id), &mut msg).await?;
            Ok(msg_id.to_u32())
        })
        .await
    }

    /// Sets the own reaction on a message; an empty string clears it.
    pub async fn send_reaction(
        &self,
        account_id: u32,
        msg_id: u32,
        emoji: String,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            reaction::send_reaction(&ctx, MsgId::new(msg_id), &emoji).await?;
            Ok(())
        })
        .await
    }

    pub async fn delete_messages(
        &self,
        account_id: u32,
        msg_ids: Vec<u32>,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let ids: Vec<MsgId> = msg_ids.into_iter().map(MsgId::new).collect();
            message::delete_msgs(&ctx, &ids).await?;
            Ok(())
        })
        .await
    }

    pub async fn forward_messages(
        &self,
        account_id: u32,
        msg_ids: Vec<u32>,
        chat_id: u32,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let ids: Vec<MsgId> = msg_ids.into_iter().map(MsgId::new).collect();
            chat::forward_msgs(&ctx, &ids, ChatId::new(chat_id)).await?;
            Ok(())
        })
        .await
    }

    /// Marks messages seen: sends MDN read receipts and syncs the read state
    /// to other devices (stronger than `mark_noticed`).
    pub async fn mark_seen(&self, account_id: u32, msg_ids: Vec<u32>) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let ids: Vec<MsgId> = msg_ids.into_iter().map(MsgId::new).collect();
            message::markseen_msgs(&ctx, ids).await?;
            Ok(())
        })
        .await
    }

    /// Accepts a contact request chat.
    pub async fn accept_chat(&self, account_id: u32, chat_id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            ChatId::new(chat_id).accept(&ctx).await?;
            Ok(())
        })
        .await
    }

    /// Blocks a chat. NOTE: core cannot block group chats — blocking a group
    /// DELETES it and its history ("can't block groups yet"), and outgoing
    /// broadcasts error. UIs should only offer this on contact requests and
    /// 1:1 chats.
    pub async fn block_chat(&self, account_id: u32, chat_id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            ChatId::new(chat_id).block(&ctx).await?;
            Ok(())
        })
        .await
    }

    /// Mutes a chat: `duration_seconds` 0 = unmute, negative = forever,
    /// positive = until now + duration. Synced to other devices.
    pub async fn set_chat_muted(
        &self,
        account_id: u32,
        chat_id: u32,
        duration_seconds: i64,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let duration = match duration_seconds {
                0 => chat::MuteDuration::NotMuted,
                s if s < 0 => chat::MuteDuration::Forever,
                s => chat::MuteDuration::Until(
                    std::time::SystemTime::now() + std::time::Duration::from_secs(s as u64),
                ),
            };
            chat::set_muted(&ctx, ChatId::new(chat_id), duration).await?;
            Ok(())
        })
        .await
    }

    pub async fn set_chat_archived(
        &self,
        account_id: u32,
        chat_id: u32,
        archived: bool,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let visibility = if archived {
                ChatVisibility::Archived
            } else {
                ChatVisibility::Normal
            };
            ChatId::new(chat_id).set_visibility(&ctx, visibility).await?;
            Ok(())
        })
        .await
    }

    /// Address-book contacts (for group creation / new chats).
    pub async fn contacts(&self, account_id: u32) -> Result<Vec<ContactItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            // DC_GCL_ADDRESS: include e-mail (address) contacts, not just
            // key-contacts — otherwise contacts created by address are hidden.
            let ids = Contact::get_all(&ctx, DC_GCL_ADDRESS, None).await?;
            let mut out = Vec::with_capacity(ids.len());
            for contact_id in ids {
                let contact = Contact::get_by_id(&ctx, contact_id).await?;
                out.push(ContactItem {
                    id: contact_id.to_u32(),
                    display_name: contact.get_display_name().to_string(),
                    addr: contact.get_addr().to_string(),
                    color: color_to_hex(contact.get_color()),
                    avatar: contact.get_profile_image(&ctx).await?.map(path_string),
                    is_verified: contact.is_verified(&ctx).await?,
                });
            }
            Ok(out)
        })
        .await
    }

    /// Creates a group chat with the given members; returns the chat id.
    pub async fn create_group(
        &self,
        account_id: u32,
        name: String,
        member_contact_ids: Vec<u32>,
    ) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let chat_id = chat::create_group(&ctx, &name).await?;
            for contact_id in member_contact_ids {
                chat::add_contact_to_chat(&ctx, chat_id, ContactId::new(contact_id)).await?;
            }
            Ok(chat_id.to_u32())
        })
        .await
    }

    pub async fn set_display_name(&self, account_id: u32, name: String) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let name = name.trim().to_string();
            let value = (!name.is_empty()).then_some(name);
            ctx.set_config(Config::Displayname, value.as_deref()).await?;
            Ok(())
        })
        .await
    }

    /// Sets or clears the self-avatar (synced to other devices and contacts).
    pub async fn set_avatar(
        &self,
        account_id: u32,
        path: Option<String>,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            ctx.set_config(Config::Selfavatar, path.as_deref()).await?;
            Ok(())
        })
        .await
    }

    /// DC connectivity scale: 1000 not connected … 4000 fully connected.
    pub async fn connectivity(&self, account_id: u32) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            Ok(ctx.get_connectivity() as u32)
        })
        .await
    }

    /// Classifies a scanned/pasted QR payload. Pure parsing, no network.
    pub async fn check_qr(&self, account_id: u32, qr: String) -> Result<QrKind, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let parsed = deltachat::qr::check_qr(&ctx, &qr).await?;
            Ok(map_qr(&parsed))
        })
        .await
    }

    /// Creates an account on a chatmail relay (default instance if none given)
    /// and configures it — the modern "no visible e-mail" onboarding. Progress
    /// arrives as `ConfigureProgress` events; on success IO for this account
    /// is already running.
    pub async fn create_instant_account(
        &self,
        account_id: u32,
        display_name: String,
        instance: Option<String>,
    ) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let name = display_name.trim();
            if !name.is_empty() {
                ctx.set_config(Config::Displayname, Some(name)).await?;
            }
            let instance = instance.unwrap_or_else(|| DEFAULT_CHATMAIL_INSTANCE.to_string());
            // Accept a full DCACCOUNT: payload, an https url, or a bare domain.
            let qr = if instance.to_uppercase().starts_with("DCACCOUNT:") {
                instance
            } else {
                format!("DCACCOUNT:{instance}")
            };
            ctx.add_transport_from_qr(&qr).await?;
            Ok(())
        })
        .await
    }

    /// Receives the full account (credentials, keys, chats) from another
    /// device showing an "Add Second Device" QR, over an encrypted P2P
    /// connection. The target account must be freshly created/unconfigured.
    /// Progress arrives as `ImexProgress` events (1000 = done); afterwards
    /// call `start_io`.
    pub async fn join_second_device(&self, account_id: u32, qr: String) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            if ctx.is_configured().await? {
                return Err(VmError::Core {
                    msg: format!(
                        "account {account_id} is already configured; \
                         joining as second device needs a fresh account"
                    ),
                });
            }
            let parsed = deltachat::qr::check_qr(&ctx, &qr)
                .await
                .map_err(|e| VmError::Core {
                    msg: format!("not a valid Second Device QR code: {e:#}"),
                })?;
            match map_qr(&parsed) {
                QrKind::Backup => {}
                QrKind::BackupTooNew => {
                    return Err(VmError::Core {
                        msg: "the other device runs a newer Delta Chat; \
                              update this app to join"
                            .into(),
                    });
                }
                other => {
                    return Err(VmError::Core {
                        msg: format!(
                            "this is not an \"Add Second Device\" QR code (got {other:?})"
                        ),
                    });
                }
            }
            deltachat::imex::get_backup(&ctx, parsed).await?;
            Ok(())
        })
        .await
    }

    /// Hints that the network may be available again (wake from sleep,
    /// connectivity regained): all accounts retry/fetch immediately instead
    /// of waiting for the next poll interval.
    pub async fn maybe_network(&self) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            accounts.read().await.maybe_network().await;
            Ok(())
        })
        .await
    }

    /// Cancels an ongoing configure or backup transfer for this account.
    pub async fn cancel_ongoing(&self, account_id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            ctx.stop_ongoing().await;
            Ok(())
        })
        .await
    }

    /// Adds an offline, pseudo-configured account seeded with demo chats,
    /// selects it and returns its id.
    pub async fn add_demo_account(&self) -> Result<u32, VmError> {
        let accounts = self.accounts.clone();
        let selected = self.selected.clone();
        on_rt(async move {
            let id = accounts.write().await.add_account().await?;
            let ctx = get_ctx(&accounts, id).await?;
            // Core's add_account auto-selects and PERSISTS the new account.
            // If seeding fails, roll it back and resync the cache — otherwise
            // the next launch lands on a broken half-seeded account.
            if let Err(e) = seed_demo_account(&ctx).await {
                let mut guard = accounts.write().await;
                let _ = guard.remove_account(id).await;
                *selected.lock().unwrap() = guard.get_selected_account_id();
                return Err(e.into());
            }

            let mut guard = accounts.write().await;
            guard.select_account(id).await?;
            *selected.lock().unwrap() = guard.get_selected_account_id();
            Ok(id)
        })
        .await
    }
}

/// Non-FFI helpers (used by integration tests; not exported through UniFFI).
impl DcApp {
    /// Raw core context for an account, for tests and debugging.
    pub async fn context(&self, account_id: u32) -> Option<Context> {
        self.accounts.read().await.get_account(account_id)
    }
}

const DEMO_ADDR: &str = "demo@example.org";

/// Inject one chat message via `receive_imf` with a Date relative to now.
/// Both directions go through this (From: self = outgoing): send_text_msg
/// always sorts at "now", so a back-dated conversation could never
/// interleave incoming and outgoing correctly.
async fn demo_mail(
    ctx: &Context,
    from: (&str, &str),
    to_addr: &str,
    seq: u32,
    minutes_ago: i64,
    body: &str,
    seen: bool,
) -> anyhow::Result<()> {
    let (from_name, from_addr) = from;
    let date = (chrono::Utc::now() - chrono::Duration::minutes(minutes_ago)).to_rfc2822();
    let raw = format!(
        "From: {from_name} <{from_addr}>\r\n\
         To: {to_addr}\r\n\
         Subject: demo\r\n\
         Message-ID: <demo.{seq}@example.com>\r\n\
         Date: {date}\r\n\
         Chat-Version: 1.0\r\n\
         MIME-Version: 1.0\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         \r\n\
         {body}\r\n"
    );
    receive_imf(ctx, raw.as_bytes(), seen).await?;
    Ok(())
}

/// Group message via a classic multi-recipient mail: core builds an ad-hoc
/// group named after the subject. No Chat-Version — chat messages to many
/// recipients don't ad-hoc-group; classic mail does. Later messages thread
/// via In-Reply-To to stay in the same group.
async fn demo_group_mail(
    ctx: &Context,
    from: (&str, &str),
    to_addrs: &str,
    subject: &str,
    seq: u32,
    minutes_ago: i64,
    body: &str,
    seen: bool,
) -> anyhow::Result<()> {
    let (from_name, from_addr) = from;
    let date = (chrono::Utc::now() - chrono::Duration::minutes(minutes_ago)).to_rfc2822();
    // "Re: <subject>" on EVERY mail: core recognizes reply subjects and
    // stops prepending "<subject> – " to rendered bodies, while the ad-hoc
    // group name still comes from the Re:-stripped subject.
    let subject_line = format!("Re: {subject}");
    let reply_header = if seq > 1 {
        "In-Reply-To: <demo.group.1@example.com>\r\n"
    } else {
        ""
    };
    let raw = format!(
        "From: {from_name} <{from_addr}>\r\n\
         To: {to_addrs}\r\n\
         Subject: {subject_line}\r\n\
         Message-ID: <demo.group.{seq}@example.com>\r\n\
         {reply_header}\
         Date: {date}\r\n\
         MIME-Version: 1.0\r\n\
         Content-Type: text/plain; charset=utf-8\r\n\
         \r\n\
         {body}\r\n"
    );
    receive_imf(ctx, raw.as_bytes(), seen).await?;
    Ok(())
}

async fn seed_demo_account(ctx: &Context) -> anyhow::Result<()> {
    // Pseudo-configure (core-api.md section 9): offline, but is_configured().
    ctx.set_config(Config::ConfiguredAddr, Some(DEMO_ADDR)).await?;
    ctx.set_config(Config::Displayname, Some("Demo User")).await?;
    // Since v2.53 ForceEncryption defaults to on; the demo account has no
    // keys and injects plaintext mail, so relax it here (demo only — real
    // accounts keep encryption enforced).
    ctx.set_config_bool(Config::ForceEncryption, false).await?;

    // --- Chat 1: Elena --------------------------------------------------
    // Dates are relative to now so ordering survives any seeding date;
    // the last incoming message per chat stays unseen for unread badges.
    let elena = ("Elena", "elena@example.com");
    let me = ("Demo User", DEMO_ADDR);
    Contact::create(ctx, elena.0, elena.1).await?;
    demo_mail(ctx, elena, DEMO_ADDR, 1, 2 * 1440 + 60,
        "Hey! Did you get the photos from the coast trip?", true).await?;
    demo_mail(ctx, me, elena.1, 2, 2 * 1440 + 55,
        "Just did \u{2014} they look amazing! The lighthouse one is my favorite.", true).await?;
    demo_mail(ctx, elena, DEMO_ADDR, 3, 2 * 1440 + 50,
        "Right? Let's print a few for grandma, she'll love them.", true).await?;
    demo_mail(ctx, me, elena.1, 4, 2 * 1440 + 45,
        "Good idea, I'll order prints tomorrow.", true).await?;
    demo_mail(ctx, elena, DEMO_ADDR, 5, 40,
        "Don't forget the sunset panorama!", false).await?;

    // --- Chat 2: Marco ---------------------------------------------------
    let marco = ("Marco", "marco@example.com");
    Contact::create(ctx, marco.0, marco.1).await?;
    demo_mail(ctx, marco, DEMO_ADDR, 6, 1440 + 30,
        "Are we still on for football on Saturday?", true).await?;
    demo_mail(ctx, me, marco.1, 7, 1440 + 25,
        "Yes! 10am at the usual field.", true).await?;
    demo_mail(ctx, marco, DEMO_ADDR, 8, 90,
        "Perfect, I'll bring the drinks.", false).await?;

    // --- Older 1:1s to fill the sidebar -----------------------------------
    let priya = ("Priya", "priya@example.com");
    let jonas = ("Jonas", "jonas@example.com");
    Contact::create(ctx, priya.0, priya.1).await?;
    Contact::create(ctx, jonas.0, jonas.1).await?;
    demo_mail(ctx, priya, DEMO_ADDR, 9, 3 * 1440 + 200,
        "The pottery class was so much fun, we should go again!", true).await?;
    demo_mail(ctx, me, priya.1, 10, 3 * 1440 + 190,
        "Definitely. Same time next month?", true).await?;
    demo_mail(ctx, priya, DEMO_ADDR, 11, 3 * 1440 + 185,
        "It's a date \u{2014} I'll book us two wheels.", true).await?;
    demo_mail(ctx, jonas, DEMO_ADDR, 12, 4 * 1440 + 100,
        "Found that book you mentioned \u{2014} it's great so far.", true).await?;
    demo_mail(ctx, me, jonas.1, 13, 4 * 1440 + 90,
        "Told you! Wait until the twist in chapter 12.", true).await?;
    demo_mail(ctx, jonas, DEMO_ADDR, 14, 4 * 1440 + 85,
        "No spoilers!!", true).await?;

    // --- Flagship group (ad-hoc via multi-recipient classic mail) ---------
    // Latest activity in the account, so it sorts first and the
    // DCNATIVE_AUTOSELECT screenshot hook opens it.
    let everyone = format!(
        "{DEMO_ADDR}, {}, {}, {}",
        elena.1, marco.1, priya.1
    );
    let group = "Weekend Hikers";
    demo_group_mail(ctx, marco, &everyone, group, 1, 1440 + 120,
        "Trail plan for Sunday: meet at the falls parking lot, 9am?", true).await?;
    demo_group_mail(ctx, me, &everyone, group, 2, 1440 + 110,
        "Works for me. Weather forecast looks perfect.", true).await?;
    demo_group_mail(ctx, elena, &everyone, group, 3, 55,
        "I'll bring the good trail mix this time", true).await?;
    demo_group_mail(ctx, priya, &everyone, group, 4, 12,
        "Can someone give me a ride? My car's in the shop.", false).await?;

    // --- A reaction chip on Elena's latest message ------------------------
    if let Some(elena_chat) = ChatId::lookup_by_contact(
        ctx, Contact::lookup_id_by_addr(
            ctx, elena.1, deltachat::contact::Origin::ManuallyCreated).await?
            .ok_or_else(|| anyhow::anyhow!("elena contact"))?,
    ).await? {
        let last = chat::get_chat_msgs(ctx, elena_chat)
            .await?
            .into_iter()
            .filter_map(|item| match item {
                CoreChatItem::Message { msg_id } => Some(msg_id),
                _ => None,
            })
            .next_back()
            .ok_or_else(|| anyhow::anyhow!("elena messages"))?;
        reaction::send_reaction(ctx, last, "\u{2764}\u{fe0f}").await?;
    }

    // No Saved Messages note: creating the self-chat stamps it "now", which
    // would outsort the flagship group (the sidebar is full enough without).

    Ok(())
}
