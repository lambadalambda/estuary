# UniFFI → Swift build recipe (macOS, arm64-only prototype, mid-2026)

Verified against the official UniFFI manual (mozilla.github.io/uniffi-rs), the uniffi-rs repo source (`uniffi/Cargo.toml`, `uniffi/src/cli/mod.rs`, Swift bindgen templates) and crates.io as of 2026-07-16.

**Version facts (verified):**
- Current `uniffi` crate: **0.32.0** (released 2026-06-30). Previous: 0.31.2 (2026-06-17). Pin `uniffi = "0.32"`. Bindgen and runtime come from the same crate in this recipe, so versions can't drift.
- Rust 1.97 / edition 2024 is fine (uniffi itself is edition 2021).
- `uniffi::uniffi_bindgen_main()` and `uniffi::uniffi_bindgen_swift()` both exist in the crate root, gated behind the `cli` cargo feature (`cli = ["bindgen", "dep:clap", "dep:camino"]`).
- Tokio support: cargo feature `tokio = ["uniffi_core/tokio"]`; the crate's own Cargo.toml comment confirms: *"Enable support for Tokio's futures. This must still be opted into on a per-function basis using `#[uniffi::export(async_runtime = "tokio")]`."*
- Callback interfaces (`#[uniffi::export(callback_interface)]`) are **soft-deprecated**; use foreign traits. `with_foreign` is a **deprecated alias**; current syntax is `#[uniffi::export(rust, foreign)]` (or `foreign` only).
- Generated Swift protocols are `public protocol X: AnyObject, Sendable` (verified in `Protocol.swift` template) — this is the Swift 6 strict-concurrency hook.

Proposed layout (adapt names; example uses crate `delta-core`, Swift module `DeltaCore`):

```
project/
  rust/
    Cargo.toml
    uniffi.toml
    uniffi-bindgen-swift.rs
    src/lib.rs
  swift/
    Package.swift
    Sources/
      DeltaCoreFFI/    # generated: module.modulemap + DeltaCoreFFI.h
      DeltaCore/       # generated: DeltaCore.swift
      DeltaApp/        # hand-written SwiftUI app
  Makefile
```

---

## 1. Cargo.toml (rust/Cargo.toml)

```toml
[package]
name = "delta-core"
version = "0.1.0"
edition = "2024"

[lib]
name = "delta_core"
# staticlib for SPM linking; keep "lib" so `cargo test` works.
# (cdylib works too, but staticlib avoids rpath/dylib-copying pain in SPM.)
crate-type = ["lib", "staticlib"]

[dependencies]
uniffi = { version = "0.32", features = ["tokio"] }
tokio = { version = "1", features = ["rt-multi-thread", "time", "sync", "macros"] }
thiserror = "2"

[[bin]]
# Swift-specific bindgen (recommended over generic `uniffi-bindgen` for Swift).
name = "uniffi-bindgen-swift"
path = "uniffi-bindgen-swift.rs"
```

`rust/uniffi-bindgen-swift.rs` (this is the current "bindgen main trick"; the generic variant is `uniffi::uniffi_bindgen_main()` in a bin named `uniffi-bindgen`, but for Swift use the dedicated entry point):

```rust
fn main() {
    uniffi::uniffi_bindgen_swift()
}
```

The `cli` feature is enabled only when running the bindgen, not in the library build:
`cargo run --features=uniffi/cli --bin uniffi-bindgen-swift -- <args>` (documented pattern).

`rust/uniffi.toml`:

```toml
[bindings.swift]
module_name = "DeltaCore"          # Swift module name; FFI module becomes DeltaCoreFFI
generate_immutable_records = true   # records use `let` (optional, nicer)
experimental_sendable_value_types = true  # records/enums w/o object refs become Sendable (helps Swift 6)
```

Proc-macro-only crates (no UDL) must call `uniffi::setup_scaffolding!();` once at the top of `lib.rs` (never together with `include_scaffolding!`).

## 2. Async

- Exported `async fn` surfaces in Swift as a native `async` function (`async throws` if it returns `Result`). No Rust event loop is required for the FFI itself: **the foreign side drives the future** — UniFFI's generated Swift uses its own continuation machinery to poll/complete Rust futures.
- BUT if your async body actually uses tokio APIs (`tokio::time::sleep`, tokio channels, reqwest, etc.) you need a reactor. Enable the `tokio` cargo feature on `uniffi` and annotate per fn / per impl block: `#[uniffi::export(async_runtime = "tokio")]`. Under the hood UniFFI wraps the future with async-compat so tokio APIs find a runtime. Without it you get the classic panic: "there is no reactor running, must be called from the context of a Tokio 1.x runtime".
- **Known bug (mozilla/uniffi-rs#2576):** `async_runtime = "tokio"` is ignored for async methods on **exported traits** (it works on plain fns and inherent impl blocks). Also, `tokio::spawn` from a *sync* exported fn has no runtime (#2811). Robust pattern for anything nontrivial: keep one explicit global runtime and bridge through it:

```rust
static RT: std::sync::LazyLock<tokio::runtime::Runtime> =
    std::sync::LazyLock::new(|| tokio::runtime::Runtime::new().unwrap());
// inside any exported async fn:  RT.spawn(fut).await.unwrap()
```

  For this prototype, `async_runtime = "tokio"` on impl blocks + the global `RT` for spawning background tasks is the sweet spot.
- Cancellation is NOT propagated: cancelling a Swift `Task` does not cancel the Rust future. Expose your own `cancel()`/flag if needed.

## 3. Callbacks / events Rust→Swift

- Use a **foreign trait**: `#[uniffi::export(with_foreign)]` still compiles but is a deprecated alias — write `#[uniffi::export(rust, foreign)]` (both sides may implement) or `#[uniffi::export(foreign)]` (Swift-only implementations; less unused scaffolding). Callback interfaces (`callback_interface`) are soft-deprecated (they surface as `Box<dyn T>` instead of `Arc<dyn T>` and may be removed).
- Trait requirements: `Send + Sync` bounds; parameters by value only (no references); methods *should* return `Result<T, E>` where `E: From<uniffi::UnexpectedUniFFICallbackError>` — otherwise any Swift-side throw/failure panics Rust.
- Async trait methods implemented in Swift are supported (Rust awaits a Swift `async` method), but for an event bus, fire-and-forget sync methods are simpler.
- **Threading:** Rust invokes the Swift implementation synchronously on whatever thread calls it — for events emitted from a tokio task, that is a **tokio worker thread**. The generated Swift protocol is `AnyObject, Sendable`, so under Swift 6 strict concurrency your implementation must itself be `Sendable`. Practical recipe: a `final class` that is stateless or lock-protected (declare `@unchecked Sendable` if needed) and immediately hops to the main actor:

```swift
final class UiListener: EventListener, @unchecked Sendable {
    let handler: @Sendable (CoreEvent) -> Void
    init(_ handler: @escaping @Sendable (CoreEvent) -> Void) { self.handler = handler }
    func onEvent(event: CoreEvent) throws {
        let h = handler
        Task { @MainActor in h(event) }   // never touch UI state on the tokio thread
    }
}
```
- Swift 6 status (official docs): "UniFFI has partial support for Swift 6. Most generated code will conform to Sendable … it is known that async code will not conform" (tracked in uniffi-rs#2448, see also #2274). Mitigation below: compile the *generated* target in Swift 5 language mode; your app target stays Swift 6.

## 4. Generating Swift bindings (library mode, proc-macro)

`uniffi-bindgen-swift` always runs in library mode (input = built library, so proc-macro metadata is read from the binary). Build first, then generate. Three invocations place files exactly where SPM wants them:

```sh
cd rust
cargo build --release

# Swift source -> DeltaCore.swift
cargo run --features=uniffi/cli --bin uniffi-bindgen-swift -- \
    target/release/libdelta_core.a ../swift/Sources/DeltaCore --swift-sources

# C header -> DeltaCoreFFI.h
cargo run --features=uniffi/cli --bin uniffi-bindgen-swift -- \
    target/release/libdelta_core.a ../swift/Sources/DeltaCoreFFI --headers

# modulemap, named module.modulemap for SPM systemLibrary
cargo run --features=uniffi/cli --bin uniffi-bindgen-swift -- \
    target/release/libdelta_core.a ../swift/Sources/DeltaCoreFFI \
    --modulemap --modulemap-filename module.modulemap
```

Outputs: `DeltaCore.swift` (high-level API; contains `#if canImport(DeltaCoreFFI) import DeltaCoreFFI #endif` — verified in the wrapper template), `DeltaCoreFFI.h`, `module.modulemap` (declares `module DeltaCoreFFI`). (The generic equivalent, `uniffi-bindgen generate --library target/release/libdelta_core.a --language swift --out-dir out`, also works but names the modulemap `DeltaCoreFFI.modulemap`.)

**Regenerate bindings after every exported-API change** — the generated Swift validates a contract version + per-fn checksums at init and hard-fails on mismatch.

## 5. Package.swift (SPM, simplest local-prototype wiring)

Static lib + `systemLibrary` target for the FFI module + `unsafeFlags` for `-L`. `unsafeFlags` is fine for a local root package (it only forbids consumption as a *remote* dependency; the "proper" distributable alternative is an XCFramework `.binaryTarget`, overkill here). arm64-only, so plain `target/release` — no lipo/xcframework.

`swift/Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let rustLibDir = "\(Context.packageDirectory)/../rust/target/release"

let package = Package(
    name: "DeltaApp",
    platforms: [.macOS(.v14)],
    targets: [
        // C FFI module: just module.modulemap + DeltaCoreFFI.h (both generated)
        .systemLibrary(name: "DeltaCoreFFI", path: "Sources/DeltaCoreFFI"),

        // Generated bindings. Swift 5 language mode: UniFFI's Swift 6 support is
        // partial (async code not yet Sendable-clean, uniffi-rs#2448).
        .target(
            name: "DeltaCore",
            dependencies: ["DeltaCoreFFI"],
            path: "Sources/DeltaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Your SwiftUI app (full Swift 6 mode is fine here).
        .executableTarget(
            name: "DeltaApp",
            dependencies: ["DeltaCore"],
            path: "Sources/DeltaApp",
            linkerSettings: [
                .linkedLibrary("delta_core"),          // -ldelta_core
                .unsafeFlags(["-L\(rustLibDir)"])      // where libdelta_core.a lives
            ]
        )
    ]
)
```

Notes:
- Put linker settings on the **executable** target (they take effect at final link).
- If the Rust crate pulls in macOS frameworks (keychain, networking), add `.linkedFramework("Security")` / `"SystemConfiguration"` as linker errors dictate; a plain crate needs nothing extra.
- `swift run DeltaApp` launches the SwiftUI app without a bundle. To get a focused window, add in `init()`: `NSApplication.shared.setActivationPolicy(.regular)` then `NSApp.activate(ignoringOtherApps: true)`. Minimal `.app` bundle later = copy binary to `DeltaApp.app/Contents/MacOS/` + trivial Info.plist.

## 6. Minimal end-to-end skeleton

`rust/src/lib.rs`:

```rust
use std::sync::Arc;

uniffi::setup_scaffolding!();

static RT: std::sync::LazyLock<tokio::runtime::Runtime> =
    std::sync::LazyLock::new(|| tokio::runtime::Runtime::new().expect("tokio runtime"));

#[derive(Debug, Clone, uniffi::Record)]
pub struct Message {
    pub id: u64,
    pub text: String,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum CoreEvent {
    Connected,
    MessageReceived { msg: Message },
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("network error: {reason}")]
    Network { reason: String },
    #[error("callback failed: {reason}")]
    Callback { reason: String },
}

// Required so a failing/throwing Swift listener maps to an error, not a Rust panic.
impl From<uniffi::UnexpectedUniFFICallbackError> for CoreError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Callback { reason: e.reason }
    }
}

// ---- Foreign trait: Swift implements this, Rust calls it (from tokio threads) ----
#[uniffi::export(with_foreign)] // deprecated alias; prefer: #[uniffi::export(rust, foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, event: CoreEvent) -> Result<(), CoreError>;
}

// ---- One exported async fn ----
#[uniffi::export(async_runtime = "tokio")]
pub async fn fetch_greeting(name: String) -> Result<String, CoreError> {
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    Ok(format!("Hello from Rust, {name}!"))
}

// ---- Object owning a background task that pushes events to Swift ----
#[derive(uniffi::Object)]
pub struct Session {
    listener: Arc<dyn EventListener>,
}

#[uniffi::export(async_runtime = "tokio")]
impl Session {
    #[uniffi::constructor]
    pub fn new(listener: Arc<dyn EventListener>) -> Arc<Self> {
        Arc::new(Self { listener })
    }

    pub async fn start(&self) -> Result<(), CoreError> {
        let listener = Arc::clone(&self.listener);
        // Explicit runtime handle: robust regardless of caller context (#2811).
        RT.spawn(async move {
            let _ = listener.on_event(CoreEvent::Connected);
            let mut id = 0u64;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                id += 1;
                let msg = Message { id, text: format!("tick {id}") };
                if listener.on_event(CoreEvent::MessageReceived { msg }).is_err() {
                    break;
                }
            }
        });
        Ok(())
    }
}
```

Swift surface this generates: `func fetchGreeting(name: String) async throws -> String`, `protocol EventListener: AnyObject, Sendable { func onEvent(event: CoreEvent) throws }`, `class Session { init(listener: EventListener); func start() async throws }`, `struct Message`, `enum CoreEvent`, `enum CoreError: Error`.

`swift/Sources/DeltaApp/DeltaApp.swift`:

```swift
import SwiftUI
import DeltaCore

@MainActor
final class Model: ObservableObject {
    @Published var greeting = "…"
    @Published var events: [String] = []
    var session: Session?

    func start() async {
        greeting = (try? await fetchGreeting(name: "Alice")) ?? "error"
        let listener = UiListener { [weak self] event in
            Task { @MainActor in self?.events.append("\(event)") }
        }
        let session = Session(listener: listener)
        self.session = session
        try? await session.start()
    }
}

final class UiListener: EventListener, @unchecked Sendable {
    let handler: @Sendable (CoreEvent) -> Void
    init(_ handler: @escaping @Sendable (CoreEvent) -> Void) { self.handler = handler }
    func onEvent(event: CoreEvent) throws { handler(event) }  // called on a tokio thread
}

@main
struct DeltaApp: App {
    @StateObject var model = Model()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup {
            List {
                Text(model.greeting)
                ForEach(model.events, id: \.self, content: Text.init)
            }
            .task { await model.start(); NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
```

`Makefile` (build order matters: lib → bindings → swift):

```make
BINDGEN = cargo run --features=uniffi/cli --bin uniffi-bindgen-swift -- \
          target/release/libdelta_core.a

.PHONY: rust bindings run clean
rust:
	cd rust && cargo build --release

bindings: rust
	cd rust && $(BINDGEN) ../swift/Sources/DeltaCore --swift-sources
	cd rust && $(BINDGEN) ../swift/Sources/DeltaCoreFFI --headers
	cd rust && $(BINDGEN) ../swift/Sources/DeltaCoreFFI --modulemap --modulemap-filename module.modulemap

run: bindings
	cd swift && swift run DeltaApp

clean:
	cd rust && cargo clean
	rm -f swift/Sources/DeltaCore/*.swift swift/Sources/DeltaCoreFFI/*
```

## Gotchas checklist
1. Regenerate bindings after ANY change to exported Rust API (checksum fatalError otherwise).
2. `async_runtime = "tokio"` doesn't apply to async methods on exported *traits* (#2576) — use the global-runtime bridge there.
3. Swift `Task` cancellation does not cancel Rust futures.
4. Listener callbacks arrive on tokio threads — always hop to `@MainActor` before touching UI state; listener class must be (`@unchecked`) `Sendable`.
5. Generated code in full Swift 6 language mode may error on async pieces (#2448/#2274) — keep the bindings target at `.swiftLanguageMode(.v5)`.
6. Avoid Rust↔Swift reference cycles through foreign traits (no cycle collector; e.g. `Session` holding the listener that holds `Session` would leak — the weak-self closure above avoids this).

Sources:
- [UniFFI user guide](https://mozilla.github.io/uniffi-rs/latest/) — [foreign bindings tutorial](https://mozilla.github.io/uniffi-rs/latest/tutorial/foreign_language_bindings.html), [futures](https://mozilla.github.io/uniffi-rs/latest/futures.html), [foreign traits](https://mozilla.github.io/uniffi-rs/latest/foreign_traits.html), [proc-macros](https://mozilla.github.io/uniffi-rs/latest/proc_macro/index.html), [Swift overview / Swift 6 notes](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html), [Swift configuration](https://mozilla.github.io/uniffi-rs/latest/swift/configuration.html), [Swift module compilation](https://mozilla.github.io/uniffi-rs/latest/swift/module.html), [uniffi-bindgen-swift](https://mozilla.github.io/uniffi-rs/next/swift/uniffi-bindgen-swift.html), [async internals](https://mozilla.github.io/uniffi-rs/latest/internals/async-overview.html)
- Repo source verified: [uniffi/Cargo.toml (features, bins)](https://github.com/mozilla/uniffi-rs/blob/main/uniffi/Cargo.toml), [proc_macro/traits.md (rust,foreign / with_foreign deprecation)](https://github.com/mozilla/uniffi-rs/blob/main/docs/manual/src/proc_macro/traits.md), [Swift Protocol template (Sendable)](https://github.com/mozilla/uniffi-rs/blob/main/uniffi_bindgen/src/bindings/swift/templates/Protocol.swift), [CHANGELOG](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md)
- Issues: [#2576 async_runtime ignored on trait methods](https://github.com/mozilla/uniffi-rs/issues/2576), [#2811 sync fn + tokio::spawn](https://github.com/mozilla/uniffi-rs/issues/2811), [#2274 Swift 6 data-race errors on async](https://github.com/mozilla/uniffi-rs/issues/2274)
- crates.io: [uniffi versions](https://crates.io/crates/uniffi); SPM linking discussion: [Swift Forums — linking a Rust staticlib](https://forums.swift.org/t/linking-a-rust-staticlib-with-c-header-in-a-swift-package/50298); alternative packagers: [cargo-swift](https://github.com/antoniusnaumann/cargo-swift)