//! Durable transcript store: `<data_dir>/transcripts.json`, keys
//! `"<account_id>:<msg_id>"`. Transcripts are expensive to produce (engine
//! cold start) but always regenerable, so corruption tolerance beats
//! integrity: a missing or unparsable file simply starts empty.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct TranscriptStore {
    path: PathBuf,
    map: HashMap<(u32, u32), String>,
}

impl TranscriptStore {
    pub fn load(data_dir: &Path) -> Self {
        let path = data_dir.join("transcripts.json");
        let map = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str::<HashMap<String, String>>(&s).ok())
            .map(|raw| {
                raw.into_iter()
                    .filter_map(|(k, v)| parse_key(&k).map(|key| (key, v)))
                    .collect()
            })
            .unwrap_or_default();
        Self { path, map }
    }

    pub fn get(&self, account_id: u32, msg_id: u32) -> Option<String> {
        self.map.get(&(account_id, msg_id)).cloned()
    }

    /// Inserts and persists (write-to-temp + rename). A failed write keeps
    /// the in-memory value, so the running session still benefits.
    pub fn insert(&mut self, account_id: u32, msg_id: u32, text: String) -> std::io::Result<()> {
        self.map.insert((account_id, msg_id), text);
        self.persist()
    }

    fn persist(&self) -> std::io::Result<()> {
        let raw: HashMap<String, String> = self
            .map
            .iter()
            .map(|((a, m), v)| (format!("{a}:{m}"), v.clone()))
            .collect();
        let json = serde_json::to_string_pretty(&raw).map_err(std::io::Error::other)?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, json)?;
        std::fs::rename(&tmp, &self.path)
    }
}

fn parse_key(key: &str) -> Option<(u32, u32)> {
    let (account, msg) = key.split_once(':')?;
    Some((account.parse().ok()?, msg.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_across_reload() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = TranscriptStore::load(dir.path());
        assert_eq!(store.get(1, 29), None);
        store.insert(1, 29, "hello".into()).unwrap();
        store.insert(2, 5, "other account".into()).unwrap();

        let reloaded = TranscriptStore::load(dir.path());
        assert_eq!(reloaded.get(1, 29).as_deref(), Some("hello"));
        assert_eq!(reloaded.get(2, 5).as_deref(), Some("other account"));
        assert_eq!(reloaded.get(1, 5), None);
    }

    #[test]
    fn corrupt_or_alien_files_start_empty() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("transcripts.json"), b"{not json").unwrap();
        let store = TranscriptStore::load(dir.path());
        assert_eq!(store.get(1, 1), None);

        // Valid JSON with junk keys: junk is dropped, not fatal.
        std::fs::write(
            dir.path().join("transcripts.json"),
            br#"{"1:2": "kept", "weird": "dropped", "3:x": "dropped"}"#,
        )
        .unwrap();
        let store = TranscriptStore::load(dir.path());
        assert_eq!(store.get(1, 2).as_deref(), Some("kept"));
    }

    #[test]
    fn insert_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = TranscriptStore::load(dir.path());
        store.insert(1, 1, "first".into()).unwrap();
        store.insert(1, 1, "second".into()).unwrap();
        assert_eq!(TranscriptStore::load(dir.path()).get(1, 1).as_deref(), Some("second"));
    }
}
