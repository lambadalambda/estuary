# deltachat-native build orchestration (dev profile everywhere; a release
# build of deltachat core takes 10+ minutes and is not pre-warmed).
#
# Build order matters: rust -> bindings -> swift.

BINDGEN = cargo run --features cli --bin uniffi-bindgen-swift -- \
          target/debug/libdcvm.a

.PHONY: rust bindings run test

rust:
	cd dcvm && cargo build

bindings: rust
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCore --swift-sources
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCoreFFI --headers
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCoreFFI --modulemap \
	    --modulemap-filename module.modulemap --module-name DeltaCoreFFI

run: bindings
	cd macos && swift run DeltaApp

test:
	cd dcvm && cargo test
