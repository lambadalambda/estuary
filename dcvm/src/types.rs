//! FFI data types (fixed contract shared with the Swift side).

/// Summary of one account for the account switcher / login screen.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountInfo {
    pub id: u32,
    pub addr: Option<String>,
    pub display_name: Option<String>,
    pub is_configured: bool,
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
    pub state: MessageState,
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
    ChatChanged { chat_id: u32 },
    IncomingMessage { chat_id: u32, msg_id: u32 },
    ConfigureProgress { permille: u32, comment: Option<String> },
    ConnectivityChanged,
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
