//! FFI data types (fixed contract shared with the Swift side).

/// Summary of one account for the account switcher / login screen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountInfo {
    pub id: u32,
    pub addr: Option<String>,
    pub display_name: Option<String>,
    pub is_configured: bool,
    /// Self-avatar image path, if set.
    pub avatar: Option<String>,
}

/// Message content kind (core `Viewtype`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageKind {
    Text,
    Image,
    Gif,
    Sticker,
    Audio,
    Voice,
    Video,
    Webxdc,
    File,
    Vcard,
    Unknown,
}

/// The quoted message shown above a reply bubble.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuoteInfo {
    pub text: String,
    pub sender_name: String,
    /// `#rrggbb`
    pub sender_color: String,
}

/// One aggregated reaction on a message.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ReactionItem {
    pub emoji: String,
    pub count: u32,
    pub is_from_self: bool,
}

/// One address-book contact.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ContactItem {
    pub id: u32,
    pub display_name: String,
    pub addr: String,
    /// `#rrggbb`
    pub color: String,
    pub avatar: Option<String>,
    pub is_verified: bool,
}

/// One row of the chat list.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatItem {
    pub id: u32,
    pub name: String,
    pub preview: String,
    /// Epoch seconds; 0 if none.
    pub timestamp: i64,
    pub fresh_count: u32,
    pub is_self_talk: bool,
    pub is_pinned: bool,
    pub is_muted: bool,
    pub is_contact_request: bool,
    /// `#rrggbb`
    pub color: String,
    pub is_group: bool,
    pub is_archived: bool,
    pub is_device_talk: bool,
    /// Chat profile image path, if any.
    pub avatar: Option<String>,
}

/// One message bubble.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MessageItem {
    pub id: u32,
    pub chat_id: u32,
    pub text: String,
    pub timestamp: i64,
    pub is_outgoing: bool,
    pub is_info: bool,
    pub sender_name: String,
    /// `#rrggbb`
    pub sender_color: String,
    /// Sender profile image path, if any (for in-chat avatars in groups).
    pub sender_avatar: Option<String>,
    pub state: MessageState,
    pub kind: MessageKind,
    /// Absolute path into the account's blobdir.
    pub file: Option<String>,
    pub file_name: Option<String>,
    /// Bytes; 0 if no file.
    pub file_size: u64,
    /// Pixels; 0 if not applicable.
    pub width: u32,
    pub height: u32,
    /// Milliseconds; 0 if not applicable.
    pub duration_ms: u32,
    pub quote: Option<QuoteInfo>,
    pub reactions: Vec<ReactionItem>,
}

/// Simplified message state for delivery ticks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageState {
    NoState,
    Pending,
    Delivered,
    Read,
    Failed,
}

/// Events pushed to the UI listener.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum VmEvent {
    AccountsChanged,
    ChatlistChanged,
    ChatChanged {
        chat_id: u32,
    },
    IncomingMessage {
        chat_id: u32,
        msg_id: u32,
    },
    ConfigureProgress {
        permille: u32,
        comment: Option<String>,
    },
    /// Import/export progress, e.g. receiving a second-device backup
    /// (permille 0 = error/canceled, 1 = started, 1000 = done).
    ImexProgress {
        permille: u32,
    },
    ConnectivityChanged,
}

/// Classification of a scanned/pasted QR payload (subset the UI cares about).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum QrKind {
    /// `DCACCOUNT:` — create an account on this chatmail relay.
    Account { domain: String },
    /// `DCBACKUP…` — receive an account from another device ("add second device").
    Backup,
    /// A backup QR from a newer Delta Chat than this client supports.
    BackupTooNew,
    /// `DCLOGIN:` — log in to an existing e-mail address.
    Login { address: String },
    /// Anything else (contact verification, proxies, urls, ...): not yet supported here.
    Unsupported,
}

/// Errors crossing the FFI boundary.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum VmError {
    #[error("core error: {msg}")]
    Core { msg: String },
    #[error("callback error: {msg}")]
    Callback { msg: String },
}

impl From<anyhow::Error> for VmError {
    fn from(e: anyhow::Error) -> Self {
        Self::Core {
            msg: format!("{e:#}"),
        }
    }
}

impl From<uniffi::UnexpectedUniFFICallbackError> for VmError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback { msg: e.reason }
    }
}
