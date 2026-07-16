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
use deltachat::login_param::{EnteredLoginParam, EnteredServerLoginParam};
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
        out.push(ChatItem {
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
        });
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

    let mut reactions: Vec<ReactionItem> = Vec::new();
    let msg_reactions = reaction::get_msg_reactions(ctx, msg.get_id()).await?;
    for contact_id in msg_reactions.contacts() {
        let contact_reaction = msg_reactions.get(contact_id);
        for emoji in contact_reaction.emojis() {
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

            let pump_accounts = accounts.clone();
            RT.spawn(async move {
                while let Some(event) = emitter.recv().await {
                    match event.typ {
                        // Core's broadcast channel dropped events (capacity
                        // 10_000, drop-oldest). We cannot know what was lost —
                        // possibly ConfigureProgress or the last
                        // ChatlistChanged — so synthesize a full refresh:
                        // accounts plus every account's chat list.
                        EventType::EventChannelOverflow { .. } => {
                            let _ = listener.on_event(0, VmEvent::AccountsChanged);
                            for id in pump_accounts.read().await.get_all() {
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
                imap: EnteredServerLoginParam {
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

    pub async fn messages(
        &self,
        account_id: u32,
        chat_id: u32,
    ) -> Result<Vec<MessageItem>, VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            let items = chat::get_chat_msgs(&ctx, ChatId::new(chat_id)).await?;
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let CoreChatItem::Message { msg_id } = item else {
                    continue;
                };
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

    /// Blocks a chat (contact request or existing chat).
    pub async fn block_chat(&self, account_id: u32, chat_id: u32) -> Result<(), VmError> {
        let accounts = self.accounts.clone();
        on_rt(async move {
            let ctx = get_ctx(&accounts, account_id).await?;
            ChatId::new(chat_id).block(&ctx).await?;
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
            seed_demo_account(&ctx).await?;

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

/// Inject one incoming chat message via `receive_imf` (offline reception path).
async fn demo_incoming(
    ctx: &Context,
    from_name: &str,
    from_addr: &str,
    seq: u32,
    date: &str,
    body: &str,
    seen: bool,
) -> anyhow::Result<()> {
    let raw = format!(
        "From: {from_name} <{from_addr}>\r\n\
         To: {DEMO_ADDR}\r\n\
         Subject: demo\r\n\
         Message-ID: <demo.{from_addr}.{seq}@example.com>\r\n\
         Date: {date}\r\n\
         Chat-Version: 1.0\r\n\
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

    // --- Chat 1: Elena --------------------------------------------------
    let elena = Contact::create(ctx, "Elena", "elena@example.com").await?;
    let elena_chat = ChatId::create_for_contact(ctx, elena).await?;
    demo_incoming(
        ctx,
        "Elena",
        "elena@example.com",
        1,
        "Tue, 14 Jul 2026 09:12:00 +0000",
        "Hey! Did you get the photos from the coast trip?",
        true,
    )
    .await?;
    chat::send_text_msg(
        ctx,
        elena_chat,
        "Just did — they look amazing! The lighthouse one is my favorite.".to_string(),
    )
    .await?;
    demo_incoming(
        ctx,
        "Elena",
        "elena@example.com",
        2,
        "Tue, 14 Jul 2026 09:20:00 +0000",
        "Right? Let's print a few for grandma, she'll love them.",
        true,
    )
    .await?;
    chat::send_text_msg(
        ctx,
        elena_chat,
        "Good idea, I'll order prints tomorrow.".to_string(),
    )
    .await?;
    demo_incoming(
        ctx,
        "Elena",
        "elena@example.com",
        3,
        "Wed, 15 Jul 2026 18:41:00 +0000",
        "Don't forget the sunset panorama!",
        false, // stays fresh -> unread badge in the demo UI
    )
    .await?;

    // --- Chat 2: Marco ---------------------------------------------------
    let marco = Contact::create(ctx, "Marco", "marco@example.com").await?;
    let marco_chat = ChatId::create_for_contact(ctx, marco).await?;
    demo_incoming(
        ctx,
        "Marco",
        "marco@example.com",
        1,
        "Wed, 15 Jul 2026 08:02:00 +0000",
        "Are we still on for football on Saturday?",
        true,
    )
    .await?;
    chat::send_text_msg(ctx, marco_chat, "Yes! 10am at the usual field.".to_string()).await?;
    demo_incoming(
        ctx,
        "Marco",
        "marco@example.com",
        2,
        "Wed, 15 Jul 2026 08:15:00 +0000",
        "Perfect, I'll bring the drinks.",
        false,
    )
    .await?;

    // --- Saved Messages with a note ---------------------------------------
    let self_chat = ChatId::create_for_contact(ctx, ContactId::SELF).await?;
    chat::send_text_msg(ctx, self_chat, "Shopping list: bread, cheese, coffee".to_string())
        .await?;

    Ok(())
}
