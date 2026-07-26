//! ASR engine abstraction. The real engine is transcribe.cpp running a
//! Parakeet GGUF; tests inject fakes so the suite stays offline and fast.

use std::path::Path;

use super::decode::SttError;

/// Turns 16 kHz mono f32 PCM into text.
pub trait SttEngine: Send + Sync {
    fn transcribe(&self, pcm: &[f32]) -> Result<String, SttError>;
}

/// transcribe.cpp-backed engine. The model stays loaded for the lifetime of
/// this value (~700 MB resident for Parakeet Q8_0); sessions are per-call
/// because they are `Send` but not `Sync`.
pub struct ParakeetEngine {
    model: transcribe_cpp::Model,
}

impl ParakeetEngine {
    pub fn load(model_path: &Path) -> Result<Self, SttError> {
        let model = transcribe_cpp::Model::load(model_path)
            .map_err(|e| SttError::Engine(format!("model load: {e}")))?;
        Ok(Self { model })
    }

    /// Resolved compute backend, e.g. "metal" or "cpu" — the way to detect
    /// a silent CPU fallback after Backend::Auto.
    pub fn backend_name(&self) -> String {
        self.model.backend()
    }
}

impl SttEngine for ParakeetEngine {
    fn transcribe(&self, pcm: &[f32]) -> Result<String, SttError> {
        let mut session = self
            .model
            .session()
            .map_err(|e| SttError::Engine(format!("session: {e}")))?;
        let transcript = session
            .run(pcm, &transcribe_cpp::RunOptions::default())
            .map_err(|e| SttError::Engine(format!("run: {e}")))?;
        Ok(transcript.text.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Opt-in real-model smoke test, mirroring the DCVM_TEST_RELAY pattern:
    /// `DCVM_TEST_STT=/path/to/parakeet.gguf cargo test -- --ignored stt`.
    /// Speech input comes from `DCVM_TEST_STT_AUDIO` (+ expected substring in
    /// `DCVM_TEST_STT_EXPECT`) when set; otherwise it is synthesized with the
    /// macOS `say` command. (`say` writes zero audio bytes in headless agent
    /// sessions — hence the file override.)
    #[test]
    #[ignore]
    fn real_model_transcribes_spoken_words() {
        let model_path = match std::env::var("DCVM_TEST_STT") {
            Ok(p) => p,
            Err(_) => panic!("set DCVM_TEST_STT=/path/to/model.gguf to run"),
        };
        let dir = tempfile::tempdir().unwrap();
        let (audio, expect) = match std::env::var("DCVM_TEST_STT_AUDIO") {
            Ok(p) => (
                std::path::PathBuf::from(p),
                std::env::var("DCVM_TEST_STT_EXPECT").unwrap_or_default(),
            ),
            Err(_) => {
                let wav = dir.path().join("utterance.wav");
                let status = std::process::Command::new("say")
                    .arg("-o")
                    .arg(&wav)
                    .args([
                        "--data-format=LEI16@22050",
                        "the quick brown fox jumps over the lazy dog",
                    ])
                    .status()
                    .expect("macOS `say` is required for this test");
                assert!(status.success(), "say failed");
                assert!(
                    wav.metadata().map(|m| m.len() > 10_000).unwrap_or(false),
                    "say produced no audio (headless session?) — \
                     set DCVM_TEST_STT_AUDIO=/path/to/speech.wav instead"
                );
                (wav, "quick brown fox".into())
            }
        };

        let pcm = super::super::decode::decode_to_pcm_16k(&audio).unwrap();
        let engine = ParakeetEngine::load(Path::new(&model_path)).unwrap();
        let text = engine.transcribe(&pcm).unwrap().to_lowercase();
        eprintln!("transcript: {text:?}");
        assert!(!text.is_empty(), "empty transcript");
        assert!(
            text.contains(&expect),
            "transcript {text:?} does not contain {expect:?}"
        );
    }
}
