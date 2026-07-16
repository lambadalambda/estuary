//! Offline integration tests for DcApp. No network: start_io is never called.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use dcvm::{DcApp, EventListener, MessageState, VmError, VmEvent};

/// Test listener collecting every event the pump forwards.
#[derive(Default)]
struct Collector {
    events: Mutex<Vec<(u32, VmEvent)>>,
}

impl EventListener for Collector {
    fn on_event(&self, account_id: u32, event: VmEvent) -> Result<(), VmError> {
        self.events.lock().unwrap().push((account_id, event));
        Ok(())
    }
}

impl Collector {
    fn snapshot(&self) -> Vec<(u32, VmEvent)> {
        self.events.lock().unwrap().clone()
    }
}

/// Poll the collector until `pred` matches some received event, or panic after 10s.
async fn wait_for_event(
    collector: &Collector,
    what: &str,
    pred: impl Fn(u32, &VmEvent) -> bool,
) -> (u32, VmEvent) {
    for _ in 0..200 {
        if let Some(hit) = collector
            .snapshot()
            .iter()
            .find(|(id, ev)| pred(*id, ev))
            .cloned()
        {
            return hit;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!(
        "timed out waiting for event: {what}; got {:?}",
        collector.snapshot()
    );
}

async fn make_app() -> (Arc<DcApp>, Arc<Collector>, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("tempdir");
    let collector = Arc::new(Collector::default());
    let listener: Arc<dyn EventListener> = collector.clone();
    let app = DcApp::new(dir.path().to_string_lossy().into_owned(), listener)
        .await
        .expect("DcApp::new");
    (app, collector, dir)
}

/// Pseudo-configure per core-api.md section 9: setting Config::ConfiguredAddr
/// creates a pseudo transport; the account then behaves configured, offline.
async fn pseudo_configure(app: &DcApp, account_id: u32, addr: &str) {
    let ctx = app.context(account_id).await.expect("context");
    ctx.set_config(dcvm::deltachat::config::Config::ConfiguredAddr, Some(addr))
        .await
        .expect("set ConfiguredAddr");
}

#[tokio::test(flavor = "multi_thread")]
async fn account_add_and_select() {
    let (app, collector, _dir) = make_app().await;

    assert_eq!(app.accounts().await.unwrap(), vec![]);
    assert_eq!(app.selected_account(), None);

    let id = app.add_account().await.expect("add_account");
    wait_for_event(&collector, "AccountsChanged", |_, ev| {
        *ev == VmEvent::AccountsChanged
    })
    .await;

    let infos = app.accounts().await.unwrap();
    assert_eq!(infos.len(), 1);
    assert_eq!(infos[0].id, id);
    assert!(!infos[0].is_configured);
    assert_eq!(infos[0].addr, None);

    app.select_account(id).await.expect("select_account");
    assert_eq!(app.selected_account(), Some(id));

    // configured flag flips after pseudo-configuration
    pseudo_configure(&app, id, "alice@example.org").await;
    let infos = app.accounts().await.unwrap();
    assert!(infos[0].is_configured);
    assert_eq!(infos[0].addr.as_deref(), Some("alice@example.org"));
}

#[tokio::test(flavor = "multi_thread")]
async fn create_chat_and_send_text() {
    let (app, collector, _dir) = make_app().await;
    let id = app.add_account().await.unwrap();
    app.select_account(id).await.unwrap();
    pseudo_configure(&app, id, "alice@example.org").await;

    let chat_id = app
        .create_chat(id, "bob@example.net".into(), "Bob".into())
        .await
        .expect("create_chat");

    let msg_id = app
        .send_text(id, chat_id, "hello bob".into())
        .await
        .expect("send_text");

    // sending emits MsgsChanged -> ChatChanged for that chat
    wait_for_event(&collector, "ChatChanged after send", |acc, ev| {
        acc == id && *ev == VmEvent::ChatChanged { chat_id }
    })
    .await;

    let msgs = app.messages(id, chat_id).await.unwrap();
    let sent = msgs
        .iter()
        .find(|m| m.id == msg_id)
        .expect("sent message visible");
    assert_eq!(sent.text, "hello bob");
    assert!(sent.is_outgoing);
    assert!(!sent.is_info);
    assert_eq!(sent.chat_id, chat_id);
    assert_eq!(sent.state, MessageState::Pending); // queued offline, never drains
    assert!(sent.timestamp > 0);

    // chat list shows the chat with the preview of the last message
    let chats = app.chat_list(id).await.unwrap();
    let row = chats
        .iter()
        .find(|c| c.id == chat_id)
        .expect("chat in chatlist");
    assert_eq!(row.name, "Bob");
    assert!(row.preview.contains("hello bob"));
    assert!(!row.is_self_talk);
    assert!(!row.is_contact_request);
    assert!(row.color.starts_with('#') && row.color.len() == 7);
    assert!(row.timestamp > 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn receive_imf_incoming_message() {
    let (app, collector, _dir) = make_app().await;
    let id = app.add_account().await.unwrap();
    app.select_account(id).await.unwrap();
    pseudo_configure(&app, id, "alice@example.org").await;

    // known contact so the message lands in a normal chat, not a request
    let chat_id = app
        .create_chat(id, "bob@example.net".into(), "Bob".into())
        .await
        .unwrap();

    let raw = b"From: Bob <bob@example.net>\r\n\
To: alice@example.org\r\n\
Subject: hi\r\n\
Message-ID: <incoming.1@example.net>\r\n\
Date: Wed, 15 Jul 2026 10:00:00 +0000\r\n\
Chat-Version: 1.0\r\n\
\r\n\
hi alice, got a minute?\r\n";

    let ctx = app.context(id).await.unwrap();
    dcvm::deltachat::receive_imf::receive_imf(&ctx, raw, false)
        .await
        .expect("receive_imf");

    let (_, ev) = wait_for_event(&collector, "IncomingMessage", |acc, ev| {
        acc == id && matches!(ev, VmEvent::IncomingMessage { .. })
    })
    .await;
    let VmEvent::IncomingMessage {
        chat_id: ev_chat,
        msg_id: ev_msg,
    } = ev
    else {
        unreachable!()
    };
    assert_eq!(ev_chat, chat_id);

    let msgs = app.messages(id, chat_id).await.unwrap();
    let incoming = msgs
        .iter()
        .find(|m| m.id == ev_msg)
        .expect("incoming message visible");
    assert!(!incoming.is_outgoing);
    assert_eq!(incoming.text, "hi alice, got a minute?");
    assert_eq!(incoming.sender_name, "Bob");
    assert!(incoming.sender_color.starts_with('#'));
    assert_eq!(incoming.state, MessageState::NoState);

    // unread badge, then mark_noticed clears it
    let row = app
        .chat_list(id)
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.id == chat_id)
        .unwrap();
    assert_eq!(row.fresh_count, 1);

    app.mark_noticed(id, chat_id).await.expect("mark_noticed");
    wait_for_event(&collector, "ChatChanged after mark_noticed", |acc, ev| {
        acc == id && *ev == VmEvent::ChatChanged { chat_id }
    })
    .await;
    let row = app
        .chat_list(id)
        .await
        .unwrap()
        .into_iter()
        .find(|c| c.id == chat_id)
        .unwrap();
    assert_eq!(row.fresh_count, 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn demo_account_seeds_conversations() {
    let (app, collector, _dir) = make_app().await;

    let id = app.add_demo_account().await.expect("add_demo_account");
    assert_eq!(app.selected_account(), Some(id));

    let infos = app.accounts().await.unwrap();
    let info = infos.iter().find(|a| a.id == id).unwrap();
    assert!(info.is_configured);
    assert!(info.addr.is_some());

    // demo seeding produced incoming messages
    wait_for_event(&collector, "IncomingMessage from demo seed", |acc, ev| {
        acc == id && matches!(ev, VmEvent::IncomingMessage { .. })
    })
    .await;

    let chats = app.chat_list(id).await.unwrap();
    let real_chats: Vec<_> = chats.iter().filter(|c| !c.is_self_talk).collect();
    assert!(
        real_chats.len() >= 2,
        "expected >= 2 demo chats, got {chats:?}"
    );

    // each demo chat holds a back-and-forth conversation
    let mut checked = 0;
    for chat in &real_chats {
        let msgs = app.messages(id, chat.id).await.unwrap();
        if msgs.is_empty() {
            continue;
        }
        assert!(
            msgs.iter().any(|m| m.is_outgoing),
            "chat {} has no outgoing messages",
            chat.name
        );
        assert!(
            msgs.iter().any(|m| !m.is_outgoing),
            "chat {} has no incoming messages",
            chat.name
        );
        assert!(msgs.len() >= 3, "chat {} too short", chat.name);
        checked += 1;
    }
    assert!(checked >= 2, "fewer than 2 populated demo chats");

    // at least one chat shows unread messages for the badge demo
    assert!(real_chats.iter().any(|c| c.fresh_count > 0));
}
