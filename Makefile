# deltachat-native build orchestration (dev profile everywhere; a release
# build of deltachat core takes 10+ minutes and is not pre-warmed).
#
# Build order matters: rust -> bindings -> swift.

BINDGEN = cargo run --features cli --bin uniffi-bindgen-swift -- \
          target/debug/libdcvm.a

# SPM's manifest sandbox (sandbox-exec) cannot nest inside the restricted dev
# shell this repo is developed in, so it is disabled by default. Override with
# `make SWIFT_FLAGS=` to keep SPM's own sandboxing on a normal machine.
SWIFT_FLAGS ?= --disable-sandbox

.PHONY: rust bindings swift-build run test check

rust:
	cd dcvm && cargo build

bindings: rust
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCore --swift-sources
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCoreFFI --headers
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCoreFFI --modulemap \
	    --modulemap-filename module.modulemap --module-name DeltaCoreFFI

# Build-only Swift check (non-interactive; works headless/CI, unlike `run`).
swift-build: bindings
	cd macos && swift build $(SWIFT_FLAGS)

run: bindings
	cd macos && swift run $(SWIFT_FLAGS) DeltaApp

test:
	cd dcvm && cargo test

# Full non-interactive verification: Rust tests + Swift compile/link.
check: test swift-build
