//! Speech-to-text pipeline: decode voice-message audio to 16 kHz mono PCM
//! and (in later stages) run it through an on-device ASR engine.

pub mod decode;

pub use decode::{decode_to_pcm_16k, SttError};
