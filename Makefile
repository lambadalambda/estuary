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

.PHONY: rust bindings swift-build run app run-app icon test check

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

# Minimal .app bundle: camera permission (TCC) wants a bundle identifier and
# NSCameraUsageDescription; a bare `swift run` binary gets the prompt
# attributed to the terminal instead. Ad-hoc signed so TCC grants persist.
app: swift-build
	rm -rf macos/Estuary.app macos/DeltaApp.app
	mkdir -p macos/Estuary.app/Contents/MacOS macos/Estuary.app/Contents/Resources
	cp macos/Info.plist macos/Estuary.app/Contents/
	# Stamp the build so "which code am I running?" is answerable from the
	# app itself (Settings sheet) and Finder's Get Info.
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $$(git rev-parse --short HEAD)" \
	    macos/Estuary.app/Contents/Info.plist
	cp macos/.build/debug/DeltaApp macos/Estuary.app/Contents/MacOS/
	cp assets/brand/Estuary.icns macos/Estuary.app/Contents/Resources/AppIcon.icns
	# SPM resource bundle: without it Bundle.module traps at first access.
	cp -R macos/.build/debug/DeltaApp_DeltaApp.bundle \
	    macos/Estuary.app/Contents/Resources/
	codesign --force --sign - macos/Estuary.app

# Regenerate the icon pipeline from the brand source (checkerboard-removal
# + rounded-square composite + .icns). Only needed when the logo changes.
icon:
	swift dev/icon/gen-icon.swift assets/brand/logo-original.png /tmp/estuary-icon
	iconutil -c icns /tmp/estuary-icon/Estuary.iconset -o assets/brand/Estuary.icns
	cp /tmp/estuary-icon/logo.png assets/brand/logo.png
	sips -Z 512 /tmp/estuary-icon/logo.png \
	    --out macos/Sources/DeltaApp/Resources/estuary-logo.png

run-app: app
	open macos/Estuary.app

test:
	cd dcvm && cargo test
	cd macos && swift test $(SWIFT_FLAGS)

# Full non-interactive verification: Rust tests + Swift compile/link.
check: test swift-build
