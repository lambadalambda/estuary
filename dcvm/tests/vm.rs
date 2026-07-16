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

/// Poll collected events until `pred` matches one, or panic after 10s.
async fn wait_for_event(
    events: &Mutex<Vec<(u32, VmEvent)>>,
    what: &str,
    pred: impl Fn(u32, &VmEvent) -> bool,
) -> (u32, VmEvent) {
    let snapshot = || events.lock().unwrap().clone();
    for _ in 0..200 {
        if let Some(hit) = snapshot().iter().find(|(id, ev)| pred(*id, ev)).cloned() {
            return hit;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for event: {what}; got {:?}", snapshot());
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
    wait_for_event(&collector.events, "AccountsChanged", |_, ev| {
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
    wait_for_event(&collector.events, "ChatChanged after send", |acc, ev| {
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

    let (_, ev) = wait_for_event(&collector.events, "IncomingMessage", |acc, ev| {
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
    wait_for_event(&collector.events, "ChatChanged after mark_noticed", |acc, ev| {
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

/// Listener that blocks the event pump on its first callback until released,
/// so the test can deterministically overflow core's 10_000-event channel.
struct GatedCollector {
    events: Mutex<Vec<(u32, VmEvent)>>,
    gate: Mutex<Option<std::sync::mpsc::Receiver<()>>>,
    blocked: std::sync::atomic::AtomicBool,
}

impl EventListener for GatedCollector {
    fn on_event(&self, account_id: u32, event: VmEvent) -> Result<(), VmError> {
        if let Some(rx) = self.gate.lock().unwrap().take() {
            self.blocked.store(true, std::sync::atomic::Ordering::SeqCst);
            let _ = rx.recv_timeout(Duration::from_secs(30));
        }
        self.events.lock().unwrap().push((account_id, event));
        Ok(())
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn event_channel_overflow_synthesizes_refresh_events() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (release, gate_rx) = std::sync::mpsc::channel::<()>();
    let collector = Arc::new(GatedCollector {
        events: Mutex::new(Vec::new()),
        gate: Mutex::new(Some(gate_rx)),
        blocked: std::sync::atomic::AtomicBool::new(false),
    });
    let listener: Arc<dyn EventListener> = collector.clone();
    let app = DcApp::new(dir.path().to_string_lossy().into_owned(), listener)
        .await
        .expect("DcApp::new");

    // add_account emits AccountsChanged; the pump forwards it and blocks in
    // on_event until `release` fires.
    let id = app.add_account().await.expect("add_account");
    for _ in 0..200 {
        if collector.blocked.load(std::sync::atomic::Ordering::SeqCst) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(
        collector.blocked.load(std::sync::atomic::Ordering::SeqCst),
        "pump never reached the listener"
    );

    // With the pump stalled, flood the (capacity 10_000, drop-oldest) channel
    // past its capacity so the next recv() yields EventChannelOverflow.
    let ctx = app.context(id).await.expect("context");
    for i in 0..10_100u32 {
        ctx.emit_event(dcvm::deltachat::EventType::Info(format!("flood {i}")));
    }
    release.send(()).expect("release pump");

    // The pump must translate the overflow into a full-refresh hint:
    // AccountsChanged (manager-level) + ChatlistChanged for every account.
    wait_for_event(
        &collector.events,
        "AccountsChanged after overflow",
        |acc, ev| acc == 0 && *ev == VmEvent::AccountsChanged,
    )
    .await;
    wait_for_event(
        &collector.events,
        "ChatlistChanged after overflow",
        |acc, ev| acc == id && *ev == VmEvent::ChatlistChanged,
    )
    .await;
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
    wait_for_event(&collector.events, "IncomingMessage from demo seed", |acc, ev| {
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

#[tokio::test(flavor = "multi_thread")]
async fn qr_classification_offline() {
    let (app, _collector, _dir) = make_app().await;
    let id = app.add_account().await.unwrap();

    // DCACCOUNT classification is pure parsing — no relay is contacted.
    assert_eq!(
        app.check_qr(id, "DCACCOUNT:nine.testrun.org".into())
            .await
            .unwrap(),
        dcvm::QrKind::Account {
            domain: "nine.testrun.org".into()
        }
    );
    assert_eq!(
        app.check_qr(id, "DCACCOUNT:https://nine.testrun.org/new".into())
            .await
            .unwrap(),
        dcvm::QrKind::Account {
            domain: "nine.testrun.org".into()
        }
    );
    // An http url is a valid QR but not one onboarding supports.
    assert_eq!(
        app.check_qr(id, "https://delta.chat/some/page?x=1".into())
            .await
            .unwrap(),
        dcvm::QrKind::Unsupported
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn join_second_device_rejects_wrong_qr_kinds() {
    let (app, _collector, _dir) = make_app().await;
    let id = app.add_account().await.unwrap();

    // Not a backup QR at all -> friendly error, nothing configured.
    let err = app
        .join_second_device(id, "DCACCOUNT:nine.testrun.org".into())
        .await
        .unwrap_err();
    assert!(
        err.to_string().to_lowercase().contains("second device"),
        "unexpected error: {err}"
    );
    assert!(!app.accounts().await.unwrap()[0].is_configured);

    // Garbage input -> error, not a panic.
    app.join_second_device(id, "not a qr code at all".into())
        .await
        .unwrap_err();
}

#[tokio::test(flavor = "multi_thread")]
async fn join_second_device_rejects_configured_account() {
    let (app, _collector, _dir) = make_app().await;
    let id = app.add_account().await.unwrap();
    pseudo_configure(&app, id, "alice@example.org").await;

    let err = app
        .join_second_device(id, "DCACCOUNT:nine.testrun.org".into())
        .await
        .unwrap_err();
    assert!(
        err.to_string().contains("already configured"),
        "unexpected error: {err}"
    );
}

/// Rewrites the `direct_addresses` inside a `DCBACKUP…` QR payload to
/// loopback, keeping the advertised port. Format: `DCBACKUPn:token&{json}`.
fn loopback_qr(qr: &str) -> String {
    let (prefix, json) = qr.split_once('&').expect("DCBACKUP qr format");
    let mut node_addr: serde_json::Value = serde_json::from_str(json).expect("node_addr json");
    let port = node_addr["direct_addresses"][0]
        .as_str()
        .and_then(|addr| addr.rsplit(':').next())
        .expect("direct address with port")
        .to_string();
    node_addr["direct_addresses"] = serde_json::json!([format!("127.0.0.1:{port}")]);
    format!("{prefix}&{node_addr}")
}

/// Full second-device happy path, offline: the demo account acts as the
/// existing device (BackupProvider), a fresh account joins via the DCBACKUP
/// QR string. The transfer runs over a direct localhost iroh connection —
/// no mail server, no relay needed (same approach as core's own tests).
#[tokio::test(flavor = "multi_thread")]
async fn second_device_join_transfers_account_offline() {
    let (app, collector, _dir) = make_app().await;

    // "Existing device": pseudo-configured and seeded with chats.
    let provider_id = app.add_demo_account().await.unwrap();
    let provider_ctx = app.context(provider_id).await.expect("provider ctx");
    let provider = dcvm::deltachat::imex::BackupProvider::prepare(&provider_ctx)
        .await
        .expect("BackupProvider::prepare");
    let qr = dcvm::deltachat::qr::format_backup(&provider.qr()).expect("format_backup");
    assert!(qr.starts_with("DCBACKUP"), "unexpected qr: {qr}");
    // iroh advertises only external interface addresses (LAN/VPN), never
    // loopback — and connecting to the host's own LAN IP is blocked in some
    // sandboxes. Rewrite the QR to 127.0.0.1 so the transfer stays strictly
    // on loopback and the test is hermetic on any network.
    let qr = loopback_qr(&qr);
    let provider_task = tokio::spawn(provider);

    // "New device": fresh unconfigured account joins with the QR payload.
    let joiner_id = app.add_account().await.unwrap();
    app.join_second_device(joiner_id, qr)
        .await
        .expect("join_second_device");
    provider_task
        .await
        .expect("provider task")
        .expect("provider transfer");

    // The joiner received the complete account.
    let infos = app.accounts().await.unwrap();
    let joiner = infos.iter().find(|a| a.id == joiner_id).unwrap();
    assert!(joiner.is_configured, "joiner not configured: {joiner:?}");
    assert_eq!(joiner.addr.as_deref(), Some("demo@example.org"));

    let chats = app.chat_list(joiner_id).await.unwrap();
    assert!(
        chats.iter().any(|c| c.name == "Elena"),
        "transferred chats missing, got: {:?}",
        chats.iter().map(|c| &c.name).collect::<Vec<_>>()
    );
    let elena = chats.iter().find(|c| c.name == "Elena").unwrap();
    let msgs = app.messages(joiner_id, elena.id).await.unwrap();
    assert!(msgs.len() >= 3, "messages not transferred: {msgs:?}");

    // Joiner saw transfer progress up to 1000 (done).
    wait_for_event(&collector.events, "ImexProgress 1000 on joiner", |id, ev| {
        id == joiner_id && *ev == VmEvent::ImexProgress { permille: 1000 }
    })
    .await;
}

/// Opt-in network test against a local chatmail relay (dev/chatmail/run.sh).
/// Run with: DCVM_TEST_RELAY=DCACCOUNT:_cm.example cargo test -- --ignored
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a running local chatmail relay; set DCVM_TEST_RELAY"]
async fn instant_account_against_local_relay() {
    let relay = std::env::var("DCVM_TEST_RELAY")
        .expect("set DCVM_TEST_RELAY, e.g. DCACCOUNT:_cm.example");
    let (app, collector, _dir) = make_app().await;
    let id = app.add_account().await.unwrap();

    app.create_instant_account(id, "Relay Test".into(), Some(relay))
        .await
        .expect("create_instant_account against local relay");

    wait_for_event(&collector.events, "ConfigureProgress 1000", |aid, ev| {
        aid == id
            && matches!(ev, VmEvent::ConfigureProgress { permille: 1000, .. })
    })
    .await;

    let infos = app.accounts().await.unwrap();
    let acc = infos.iter().find(|a| a.id == id).unwrap();
    assert!(acc.is_configured);
    assert!(
        acc.addr.as_deref().unwrap_or("").contains('@'),
        "no addr: {acc:?}"
    );
}

/// Opt-in: full message round trip between two instant accounts on the local
/// relay — real SMTP submission and IMAP delivery, end to end.
///
/// Chatmail relays reject unencrypted outbound mail (filtermail), so a first
/// contact by bare address cannot deliver. Like the real clients, the
/// contact is established with a securejoin QR invite first; the text
/// message then goes out encrypted.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs a running local chatmail relay; set DCVM_TEST_RELAY"]
async fn message_roundtrip_on_local_relay() {
    use dcvm::deltachat::securejoin::{get_securejoin_qr, join_securejoin};
    use dcvm::deltachat::EventType as CoreEventType;

    let relay = std::env::var("DCVM_TEST_RELAY")
        .expect("set DCVM_TEST_RELAY, e.g. DCACCOUNT:_cm.example");
    let (app, _collector, _dir) = make_app().await;

    let alice = app.add_account().await.unwrap();
    let bob = app.add_account().await.unwrap();
    app.create_instant_account(alice, "Alice".into(), Some(relay.clone()))
        .await
        .expect("alice instant account");
    app.create_instant_account(bob, "Bob".into(), Some(relay))
        .await
        .expect("bob instant account");
    app.start_io().await.unwrap();

    // Key exchange first: bob shares an invite QR, alice joins. The
    // securejoin handshake messages are the one thing filtermail lets
    // through unencrypted.
    let alice_ctx = app.context(alice).await.unwrap();
    let bob_ctx = app.context(bob).await.unwrap();

    // Wait until both schedulers finished their initial post-configure inbox
    // scan (Connectivity::Connected). Mail arriving DURING that first scan is
    // treated as pre-existing and silently skipped (core's "don't download
    // old mail" behavior) — alice's invite must not race it.
    // (Connectivity's type lives in a private module; DC convention:
    // 4000 = Connected. jsonrpc does the same `as u32` cast.)
    for ctx in [&alice_ctx, &bob_ctx] {
        tokio::time::timeout(Duration::from_secs(60), async {
            while (ctx.get_connectivity() as u32) < 4000 {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        })
        .await
        .expect("account never reached Connected");
    }
    let invite = get_securejoin_qr(&bob_ctx, None).await.expect("invite qr");
    // Subscribe BEFORE joining: the receiver only sees events emitted after
    // its creation, and a fast handshake can finish before join returns.
    let mut raw_events = alice_ctx.get_event_emitter();
    let chat = join_securejoin(&alice_ctx, &invite)
        .await
        .expect("join_securejoin")
        .to_u32();

    // If IMAP IDLE/push misbehaves, core falls back to slow periodic polling
    // and the multi-roundtrip handshake stalls. maybe_network() forces an
    // immediate fetch — nudge while waiting, like push notifications would.
    let nudger = {
        let app = app.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(3)).await;
                let _ = app.maybe_network().await;
            }
        })
    };

    tokio::time::timeout(Duration::from_secs(180), async {
        loop {
            let ev = raw_events.recv().await.expect("core event stream closed");
            if matches!(
                ev.typ,
                CoreEventType::SecurejoinJoinerProgress { progress: 1000, .. }
            ) {
                break;
            }
        }
    })
    .await
    .expect("securejoin handshake timed out");

    app.send_text(alice, chat, "ping over the local relay".into())
        .await
        .unwrap();

    // Bob receives it via real IMAP delivery (poll; delivery is near-instant
    // on chatmail but the handshake may still be settling).
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    let received = loop {
        let mut found = None;
        for c in app.chat_list(bob).await.unwrap() {
            let msgs = app.messages(bob, c.id).await.unwrap();
            if let Some(m) = msgs
                .iter()
                .find(|m| m.text.contains("ping over the local relay"))
            {
                found = Some(m.clone());
                break;
            }
        }
        if let Some(m) = found {
            break m;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "bob never received the message"
        );
        tokio::time::sleep(Duration::from_millis(500)).await;
    };
    nudger.abort();
    assert!(!received.is_outgoing);
}
