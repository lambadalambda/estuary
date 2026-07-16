//! Pure mapping functions from deltachat core types to FFI types.
//!
//! Everything here is side-effect free and unit-tested; the async glue in
//! `app` only composes these.

use deltachat::message::MessageState as CoreMessageState;
use deltachat::summary::SummaryPrefix;
use deltachat::EventType;

use crate::types::{MessageState, VmEvent};

/// Core colors are `0x00rrggbb` u32s; the UI wants CSS `#rrggbb`.
pub fn color_to_hex(color: u32) -> String {
    format!("#{:06x}", color & 0x00ff_ffff)
}

/// Collapse core's fine-grained message states into the four the UI renders.
pub fn map_message_state(state: CoreMessageState) -> MessageState {
    use CoreMessageState::*;
    match state {
        Undefined | InFresh | InNoticed | InSeen => MessageState::NoState,
        OutPreparing | OutDraft | OutPending => MessageState::Pending,
        OutFailed => MessageState::Failed,
        OutDelivered => MessageState::Delivered,
        OutMdnRcvd => MessageState::Read,
    }
}

/// Chat list preview line: `"<prefix>: <text>"`, or just `<text>` without prefix.
pub fn summary_preview(prefix: Option<&SummaryPrefix>, text: &str) -> String {
    match prefix {
        Some(prefix) => format!("{prefix}: {text}"),
        None => text.to_string(),
    }
}

/// Translate a core event into a UI event; `None` means "not interesting".
pub fn map_event(typ: EventType) -> Option<VmEvent> {
    match typ {
        EventType::AccountsChanged | EventType::AccountsItemChanged => {
            Some(VmEvent::AccountsChanged)
        }
        EventType::ChatlistChanged
        | EventType::ChatlistItemChanged { chat_id: None } => Some(VmEvent::ChatlistChanged),
        EventType::ChatlistItemChanged {
            chat_id: Some(chat_id),
        } => Some(VmEvent::ChatChanged {
            chat_id: chat_id.to_u32(),
        }),
        EventType::MsgsChanged { chat_id, .. }
        | EventType::MsgDelivered { chat_id, .. }
        | EventType::MsgRead { chat_id, .. }
        | EventType::MsgFailed { chat_id, .. }
        | EventType::MsgsNoticed(chat_id) => {
            if chat_id.is_unset() {
                // Core's "no specific chat" sentinel (chat_id 0), e.g. from
                // emit_msgs_changed_without_ids(). A ChatChanged { chat_id: 0 }
                // would be a phantom id outside the FFI contract; ask the UI
                // for a chat list refresh instead.
                Some(VmEvent::ChatlistChanged)
            } else {
                Some(VmEvent::ChatChanged {
                    chat_id: chat_id.to_u32(),
                })
            }
        }
        EventType::IncomingMsg { chat_id, msg_id } => Some(VmEvent::IncomingMessage {
            chat_id: chat_id.to_u32(),
            msg_id: msg_id.to_u32(),
        }),
        EventType::ConfigureProgress { progress, comment } => Some(VmEvent::ConfigureProgress {
            permille: u32::from(progress),
            comment,
        }),
        EventType::ConnectivityChanged => Some(VmEvent::ConnectivityChanged),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use deltachat::chat::ChatId;
    use deltachat::message::MsgId;

    #[test]
    fn color_to_hex_pads_and_lowercases() {
        assert_eq!(color_to_hex(0x00e56555), "#e56555");
        assert_eq!(color_to_hex(0x00000000), "#000000");
        assert_eq!(color_to_hex(0x0000ff00), "#00ff00");
        assert_eq!(color_to_hex(0x00ffffff), "#ffffff");
        // high byte (alpha junk) must be ignored
        assert_eq!(color_to_hex(0xff123abc), "#123abc");
    }

    #[test]
    fn message_states_collapse() {
        use CoreMessageState::*;
        assert_eq!(map_message_state(Undefined), MessageState::NoState);
        assert_eq!(map_message_state(InFresh), MessageState::NoState);
        assert_eq!(map_message_state(InNoticed), MessageState::NoState);
        assert_eq!(map_message_state(InSeen), MessageState::NoState);
        assert_eq!(map_message_state(OutPreparing), MessageState::Pending);
        assert_eq!(map_message_state(OutDraft), MessageState::Pending);
        assert_eq!(map_message_state(OutPending), MessageState::Pending);
        assert_eq!(map_message_state(OutFailed), MessageState::Failed);
        assert_eq!(map_message_state(OutDelivered), MessageState::Delivered);
        assert_eq!(map_message_state(OutMdnRcvd), MessageState::Read);
    }

    #[test]
    fn summary_preview_formats_prefix() {
        assert_eq!(summary_preview(None, "hi there"), "hi there");
        assert_eq!(
            summary_preview(Some(&SummaryPrefix::Username("Bob".into())), "yo"),
            "Bob: yo"
        );
        assert_eq!(
            summary_preview(Some(&SummaryPrefix::Me("Me".into())), "sent"),
            "Me: sent"
        );
        assert_eq!(
            summary_preview(Some(&SummaryPrefix::Draft("Draft".into())), "unsent"),
            "Draft: unsent"
        );
    }

    #[test]
    fn events_map_to_vm_events() {
        let chat = ChatId::new(7);
        let msg = MsgId::new(42);

        assert_eq!(
            map_event(EventType::AccountsChanged),
            Some(VmEvent::AccountsChanged)
        );
        assert_eq!(
            map_event(EventType::AccountsItemChanged),
            Some(VmEvent::AccountsChanged)
        );
        assert_eq!(
            map_event(EventType::ChatlistChanged),
            Some(VmEvent::ChatlistChanged)
        );
        assert_eq!(
            map_event(EventType::ChatlistItemChanged { chat_id: None }),
            Some(VmEvent::ChatlistChanged)
        );
        assert_eq!(
            map_event(EventType::ChatlistItemChanged {
                chat_id: Some(chat)
            }),
            Some(VmEvent::ChatChanged { chat_id: 7 })
        );
        assert_eq!(
            map_event(EventType::MsgsChanged {
                chat_id: chat,
                msg_id: msg
            }),
            Some(VmEvent::ChatChanged { chat_id: 7 })
        );
        assert_eq!(
            map_event(EventType::MsgsNoticed(chat)),
            Some(VmEvent::ChatChanged { chat_id: 7 })
        );
        // chat_id 0 is core's "unset" sentinel (emit_msgs_changed_without_ids):
        // never forward it as a phantom chat id, ask for a chatlist reload.
        assert_eq!(
            map_event(EventType::MsgsChanged {
                chat_id: ChatId::new(0),
                msg_id: MsgId::new(0)
            }),
            Some(VmEvent::ChatlistChanged)
        );
        assert_eq!(
            map_event(EventType::MsgsNoticed(ChatId::new(0))),
            Some(VmEvent::ChatlistChanged)
        );
        assert_eq!(
            map_event(EventType::MsgDelivered {
                chat_id: chat,
                msg_id: msg
            }),
            Some(VmEvent::ChatChanged { chat_id: 7 })
        );
        assert_eq!(
            map_event(EventType::MsgRead {
                chat_id: chat,
                msg_id: msg
            }),
            Some(VmEvent::ChatChanged { chat_id: 7 })
        );
        assert_eq!(
            map_event(EventType::MsgFailed {
                chat_id: chat,
                msg_id: msg
            }),
            Some(VmEvent::ChatChanged { chat_id: 7 })
        );
        assert_eq!(
            map_event(EventType::IncomingMsg {
                chat_id: chat,
                msg_id: msg
            }),
            Some(VmEvent::IncomingMessage {
                chat_id: 7,
                msg_id: 42
            })
        );
        assert_eq!(
            map_event(EventType::ConfigureProgress {
                progress: 600,
                comment: Some("connecting".into())
            }),
            Some(VmEvent::ConfigureProgress {
                permille: 600,
                comment: Some("connecting".into())
            })
        );
        assert_eq!(
            map_event(EventType::ConnectivityChanged),
            Some(VmEvent::ConnectivityChanged)
        );
        // noise is dropped
        assert_eq!(map_event(EventType::Info("hello".into())), None);
        assert_eq!(map_event(EventType::Warning("hm".into())), None);
    }
}
