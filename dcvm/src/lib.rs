//! dcvm: headless DeltaChat viewmodel exposed over UniFFI.

uniffi::setup_scaffolding!();

pub mod mapping;
pub mod types;

pub use types::*;
