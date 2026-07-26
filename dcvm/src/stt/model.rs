//! Parakeet model acquisition: download to `<data_dir>/stt-models/` with
//! progress, verify sha256, and rename into place atomically.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use super::decode::SttError;

/// A download that stops making progress for this long is dead (Wi-Fi drop
/// without RST, black-holing middlebox). Connect gets a tighter bound.
const STALL_TIMEOUT: Duration = Duration::from_secs(60);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

/// Distinguishes concurrent in-process downloads' temp files (pid guards
/// against a stale part from a killed sibling process colliding).
static PART_SEQ: AtomicU64 = AtomicU64::new(0);

/// Pinned model: NVIDIA Parakeet TDT 0.6B v3 (25 European languages),
/// Q8_0 GGUF published by the transcribe.cpp team (1.94% WER LibriSpeech
/// test-clean). Constants verified against the Hugging Face LFS metadata
/// on 2026-07-26.
pub const MODEL_FILE: &str = "parakeet-tdt-0.6b-v3-Q8_0.gguf";
pub const MODEL_URL: &str =
    "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/main/parakeet-tdt-0.6b-v3-Q8_0.gguf";
pub const MODEL_SIZE: u64 = 739_508_576;
pub const MODEL_SHA256: &str = "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7";

pub fn model_path(data_dir: &Path) -> PathBuf {
    data_dir.join("stt-models").join(MODEL_FILE)
}

/// True when the pinned model is fully present (size check only — the sha256
/// was verified at download time and hashing 700 MB on every call is waste).
pub fn model_ready(data_dir: &Path) -> bool {
    model_path(data_dir)
        .metadata()
        .map(|m| m.len() == MODEL_SIZE)
        .unwrap_or(false)
}

/// Ensure the pinned model exists, downloading it if needed.
/// `progress(done_bytes, total_bytes)` fires periodically during download.
/// Concurrent calls are safe (each verifies its own bytes in a private temp
/// file; the last rename wins) but wasteful — callers should serialize.
pub async fn ensure_model(
    data_dir: &Path,
    progress: impl FnMut(u64, u64),
) -> Result<PathBuf, SttError> {
    let target = model_path(data_dir);
    if model_ready(data_dir) {
        return Ok(target);
    }
    fetch_verified(
        MODEL_URL,
        &target,
        MODEL_SIZE,
        MODEL_SHA256,
        STALL_TIMEOUT,
        progress,
    )
    .await?;
    Ok(target)
}

/// Download `url` to `target` (via a private `.part.*` sibling), verifying
/// length and sha256 before the final rename so a torn download can never be
/// mistaken for a model.
async fn fetch_verified(
    url: &str,
    target: &Path,
    expected_size: u64,
    expected_sha256: &str,
    stall_timeout: Duration,
    mut progress: impl FnMut(u64, u64),
) -> Result<(), SttError> {
    let net_err = |e: &dyn std::fmt::Display| SttError::Engine(format!("model download: {e}"));
    let parent = target
        .parent()
        .ok_or_else(|| SttError::Engine("model path has no parent".into()))?;
    tokio::fs::create_dir_all(parent)
        .await
        .map_err(|e| net_err(&e))?;
    let part = target.with_extension(format!(
        "part.{}.{}",
        std::process::id(),
        PART_SEQ.fetch_add(1, Ordering::Relaxed)
    ));

    let result = async {
        let client = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .map_err(|e| net_err(&e))?;
        let response = client.get(url).send().await.map_err(|e| net_err(&e))?;
        if !response.status().is_success() {
            return Err(SttError::Engine(format!(
                "model download: HTTP {}",
                response.status()
            )));
        }
        let mut file = tokio::fs::File::create(&part).await.map_err(|e| net_err(&e))?;
        let mut hasher = Sha256::new();
        let mut done: u64 = 0;
        let mut stream = response.bytes_stream();
        loop {
            let chunk = match tokio::time::timeout(stall_timeout, stream.next()).await {
                Ok(Some(chunk)) => chunk.map_err(|e| net_err(&e))?,
                Ok(None) => break,
                Err(_) => return Err(SttError::Engine("model download: stalled".into())),
            };
            hasher.update(&chunk);
            file.write_all(&chunk).await.map_err(|e| net_err(&e))?;
            done += chunk.len() as u64;
            if done > expected_size {
                return Err(SttError::Engine(
                    "model download: larger than expected".into(),
                ));
            }
            progress(done, expected_size);
        }
        // Force pages to disk before the rename: a size-correct file of
        // unwritten pages would pass model_ready() forever after power loss.
        file.sync_all().await.map_err(|e| net_err(&e))?;
        drop(file);
        if done != expected_size {
            return Err(SttError::Engine(format!(
                "model download: got {done} of {expected_size} bytes"
            )));
        }
        let digest = hex::encode(hasher.finalize());
        if digest != expected_sha256 {
            return Err(SttError::Engine("model download: checksum mismatch".into()));
        }
        tokio::fs::rename(&part, target).await.map_err(|e| net_err(&e))?;
        Ok(())
    }
    .await;

    if result.is_err() {
        let _ = tokio::fs::remove_file(&part).await;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    /// Test-tuned stall timeout so stall tests don't take a minute.
    const TEST_STALL: Duration = Duration::from_millis(300);

    /// One-shot HTTP server handing out `body`, so download tests stay local.
    /// `claimed_len` lets a test lie about content-length; `then_hang` sends
    /// half the body and stops without closing (stall simulation).
    async fn serve_once_with(body: Vec<u8>, claimed_len: usize, then_hang: bool) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            // Drain the request head before answering.
            let mut buf = [0u8; 1024];
            let _ = tokio::io::AsyncReadExt::read(&mut sock, &mut buf).await;
            let head = format!(
                "HTTP/1.1 200 OK\r\ncontent-length: {claimed_len}\r\nconnection: close\r\n\r\n"
            );
            sock.write_all(head.as_bytes()).await.unwrap();
            if then_hang {
                sock.write_all(&body[..body.len() / 2]).await.unwrap();
                sock.flush().await.unwrap();
                // Keep the socket open but silent until the client gives up.
                tokio::time::sleep(Duration::from_secs(600)).await;
            } else {
                sock.write_all(&body).await.unwrap();
                sock.flush().await.unwrap();
            }
        });
        format!("http://{addr}/model.gguf")
    }

    async fn serve_once(body: Vec<u8>) -> String {
        let len = body.len();
        serve_once_with(body, len, false).await
    }

    fn sha256_hex(data: &[u8]) -> String {
        hex::encode(Sha256::digest(data))
    }

    #[tokio::test]
    async fn download_verifies_and_installs() {
        let body: Vec<u8> = (0..100_000u32).map(|i| (i % 251) as u8).collect();
        let url = serve_once(body.clone()).await;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("stt-models").join("model.gguf");

        let seen = Arc::new(AtomicU64::new(0));
        let seen2 = seen.clone();
        fetch_verified(
            &url,
            &target,
            body.len() as u64,
            &sha256_hex(&body),
            TEST_STALL,
            move |done, total| {
                assert_eq!(total, 100_000);
                seen2.store(done, Ordering::Relaxed);
            },
        )
        .await
        .unwrap();

        assert_eq!(std::fs::read(&target).unwrap(), body);
        assert_eq!(seen.load(Ordering::Relaxed), 100_000, "progress must reach total");
        assert_no_part_files(target.parent().unwrap());
    }

    #[tokio::test]
    async fn checksum_mismatch_rejects_and_cleans_up() {
        let body = vec![0xAAu8; 4096];
        let url = serve_once(body.clone()).await;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("stt-models").join("model.gguf");

        let err = fetch_verified(&url, &target, 4096, &sha256_hex(b"other"), TEST_STALL, |_, _| {})
            .await
            .unwrap_err();
        assert!(matches!(err, SttError::Engine(_)), "got {err:?}");
        assert!(!target.exists(), "corrupt model must not be installed");
        assert_no_part_files(target.parent().unwrap());
    }

    #[tokio::test]
    async fn truncated_download_rejects() {
        // Server claims 8192 bytes but the expectation is larger.
        let body = vec![0x55u8; 8192];
        let url = serve_once(body.clone()).await;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("model.gguf");

        let err = fetch_verified(&url, &target, 10_000, &sha256_hex(&body), TEST_STALL, |_, _| {})
            .await
            .unwrap_err();
        assert!(matches!(err, SttError::Engine(_)), "got {err:?}");
        assert!(!target.exists());
    }

    #[tokio::test]
    async fn oversized_response_rejects() {
        // Server sends 8192 bytes while we expect only 4096.
        let body = vec![0x77u8; 8192];
        let claimed = body.len();
        let url = serve_once_with(body.clone(), claimed, false).await;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("model.gguf");

        let err = fetch_verified(&url, &target, 4096, &sha256_hex(&body), TEST_STALL, |_, _| {})
            .await
            .unwrap_err();
        assert!(matches!(err, SttError::Engine(_)), "got {err:?}");
        assert!(!target.exists());
        assert_no_part_files(dir.path());
    }

    #[tokio::test]
    async fn stalled_download_times_out_and_cleans_up() {
        let body = vec![0x33u8; 8192];
        let claimed = body.len();
        let url = serve_once_with(body.clone(), claimed, true).await;
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("model.gguf");

        let start = std::time::Instant::now();
        let err = fetch_verified(&url, &target, 8192, &sha256_hex(&body), TEST_STALL, |_, _| {})
            .await
            .unwrap_err();
        assert!(matches!(err, SttError::Engine(_)), "got {err:?}");
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "stall must trip the timeout, not hang"
        );
        assert!(!target.exists());
        assert_no_part_files(dir.path());
    }

    fn assert_no_part_files(dir: &Path) {
        let leftovers: Vec<_> = std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".part"))
            .collect();
        assert!(leftovers.is_empty(), "part files left behind: {leftovers:?}");
    }

    #[test]
    fn model_ready_only_for_exact_size() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!model_ready(dir.path()));
        let path = model_path(dir.path());
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"stub").unwrap();
        assert!(!model_ready(dir.path()), "wrong-size file must not count");
    }
}
