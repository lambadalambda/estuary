//! Seeds a data dir for the transcription end-to-end check: demo account
//! plus a real speech attachment (jfk.wav) in the first chat. Run:
//! `cargo run --example seed_stt_e2e -- <data_dir> <wav_path>`

use std::sync::Arc;

use dcvm::{DcApp, EventListener, VmError, VmEvent};

struct Quiet;
impl EventListener for Quiet {
    fn on_event(&self, _account_id: u32, _event: VmEvent) -> Result<(), VmError> {
        Ok(())
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let data_dir = args.next().expect("usage: seed_stt_e2e <data_dir> <wav>");
    let wav = args.next().expect("usage: seed_stt_e2e <data_dir> <wav>");

    let app = DcApp::new(data_dir, Arc::new(Quiet)).await?;
    let account = app.add_demo_account().await?;
    let chat = app
        .create_chat(account, "vera@example.org".into(), "Vera Voice".into())
        .await?;
    let msg = app
        .send_message(account, chat, None, Some(wav), None)
        .await?;
    // Filler below the voice note so the chat scrolls: reaching the audio
    // bubble requires scrolling up, which exercises paging, scroll memory,
    // and transcript persistence in one chat.
    for i in 1..=80 {
        app.send_message(account, chat, Some(format!("filler message {i}")), None, None)
            .await?;
    }
    println!("seeded: account={account} chat={chat} msg={msg}");
    Ok(())
}
