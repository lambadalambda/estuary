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
use deltachat::contact::{Contact, ContactId};
use deltachat::context::Context;
use deltachat::login_param::{EnteredLoginParam, EnteredServerLoginParam};
use deltachat::message::Message;
use deltachat::receive_imf::receive_imf;
use tokio::sync::RwLock;

use crate::mapping::{color_to_hex, map_event, map_message_state, summary_preview};
use crate::types::{AccountInfo, ChatItem, MessageItem, VmError, VmEvent};

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

            RT.spawn(async move {
                while let Some(event) = emitter.recv().await {
                    if let Some(vm_event) = map_event(event.typ) {
                        // Listener errors are ignored by design; only a closed
                        // channel (None above) stops the pump.
                        let _ = listener.on_event(event.id, vm_event);
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
            let chatlist = Chatlist::try_load(&ctx, 0, None, None).await?;
            let mut out = Vec::with_capacity(chatlist.len());
            for index in 0..chatlist.len() {
                let chat_id = chatlist.get_chat_id(index)?;
                if chat_id.is_special() {
                    continue; // e.g. the "archived chats" pseudo-row
                }
                let chat = Chat::load_from_db(&ctx, chat_id).await?;
                let summary = chatlist.get_summary(&ctx, index, Some(&chat)).await?;
                out.push(ChatItem {
                    id: chat_id.to_u32(),
                    name: chat.get_name().to_string(),
                    preview: summary_preview(summary.prefix.as_ref(), &summary.text),
                    timestamp: summary.timestamp,
                    fresh_count: chat_id.get_fresh_msg_cnt(&ctx).await? as u32,
                    is_self_talk: chat.is_self_talk(),
                    is_pinned: chat.visibility == ChatVisibility::Pinned,
                    is_muted: chat.is_muted(),
                    is_contact_request: chat.is_contact_request(),
                    color: color_to_hex(chat.get_color(&ctx).await?),
                });
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
                let from_id = msg.get_from_id();
                let sender = Contact::get_by_id(&ctx, from_id).await?;
                out.push(MessageItem {
                    id: msg_id.to_u32(),
                    chat_id: msg.get_chat_id().to_u32(),
                    text: msg.get_text(),
                    timestamp: msg.get_timestamp(),
                    is_outgoing: from_id == ContactId::SELF,
                    is_info: msg.is_info(),
                    sender_name: sender.get_display_name().to_string(),
                    sender_color: color_to_hex(sender.get_color()),
                    state: map_message_state(msg.get_state()),
                });
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
