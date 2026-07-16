//! dcvm: headless DeltaChat viewmodel exposed over UniFFI.

uniffi::setup_scaffolding!();

pub mod app;
pub mod mapping;
pub mod types;

pub use app::{DcApp, EventListener};
pub use types::*;

// Re-exported so integration tests and debugging tools use the same core.
pub use deltachat;
