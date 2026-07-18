# deltachat-native build orchestration.
#
# Build order matters: rust -> bindings -> swift.
#
# Profiles: debug (default) for the local loop; `make app-release` (or
# `make PROFILE=release <target>`) for distributable builds. A release
# build of deltachat core takes 10+ minutes cold — CI caches it.

PROFILE ?= debug
ifeq ($(PROFILE),release)
CARGO_PROFILE_FLAG = --release
SWIFT_CONFIG_FLAG = -c release
# Separate scratch dir per profile: SPM caches the evaluated manifest,
# which bakes in the DCVM_PROFILE lib dir — sharing a scratch dir would
# link whichever profile's lib was cached first.
SWIFT_SCRATCH = .build-release
else
CARGO_PROFILE_FLAG =
SWIFT_CONFIG_FLAG =
SWIFT_SCRATCH = .build
endif
# Package.swift reads this to pick the rust lib dir.
export DCVM_PROFILE = $(PROFILE)

BINDGEN = cargo run --locked $(CARGO_PROFILE_FLAG) --features cli --bin uniffi-bindgen-swift -- \
          target/$(PROFILE)/libdcvm.a

# SPM's manifest sandbox (sandbox-exec) cannot nest inside the restricted dev
# shell this repo is developed in, so it is disabled by default. Override with
# `make SWIFT_FLAGS=` to keep SPM's own sandboxing on a normal machine.
SWIFT_FLAGS ?= --disable-sandbox
SWIFT_BUILD_FLAGS = $(SWIFT_FLAGS) $(SWIFT_CONFIG_FLAG) --scratch-path $(SWIFT_SCRATCH)

.PHONY: rust bindings swift-build run app app-release run-app icon tiles test check

rust:
	cd dcvm && cargo build --locked $(CARGO_PROFILE_FLAG)

bindings: rust
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCore --swift-sources
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCoreFFI --headers
	cd dcvm && $(BINDGEN) ../macos/Sources/DeltaCoreFFI --modulemap \
	    --modulemap-filename module.modulemap --module-name DeltaCoreFFI

# Build-only Swift check (non-interactive; works headless/CI, unlike `run`).
swift-build: bindings
	cd macos && swift build $(SWIFT_BUILD_FLAGS)

run: bindings
	cd macos && swift run $(SWIFT_BUILD_FLAGS) DeltaApp

# Minimal .app bundle: camera permission (TCC) wants a bundle identifier and
# NSCameraUsageDescription; a bare `swift run` binary gets the prompt
# attributed to the terminal instead. Ad-hoc signed so TCC grants persist.
app: swift-build
	rm -rf macos/Estuary.app macos/DeltaApp.app
	mkdir -p macos/Estuary.app/Contents/MacOS macos/Estuary.app/Contents/Resources
	cp macos/Info.plist macos/Estuary.app/Contents/
	# Stamp the build so "which code am I running?" is answerable from the
	# app itself (Settings sheet) and Finder's Get Info.
	/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $$(git rev-list --count HEAD)" \
	    macos/Estuary.app/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :EstuaryGitCommit string $$(git rev-parse --short HEAD)" \
	    macos/Estuary.app/Contents/Info.plist
	cp macos/$(SWIFT_SCRATCH)/$(PROFILE)/DeltaApp macos/Estuary.app/Contents/MacOS/
	cp assets/brand/Estuary.icns macos/Estuary.app/Contents/Resources/AppIcon.icns
	# SPM resource bundle: without it Bundle.module traps at first access.
	cp -R macos/$(SWIFT_SCRATCH)/$(PROFILE)/DeltaApp_DeltaApp.bundle \
	    macos/Estuary.app/Contents/Resources/
	codesign --force --sign - macos/Estuary.app

# Distributable build: release-profile Rust core + release Swift.
app-release:
	$(MAKE) PROFILE=release app

# Regenerate the chat-background tiles from the brand pattern. Only needed
# when assets/brand/chat-pattern.png changes.
tiles:
	swift dev/icon/gen-tiles.swift assets/brand/chat-pattern.png /tmp/estuary-tiles
	cp /tmp/estuary-tiles/chat-tile-light.png /tmp/estuary-tiles/chat-tile-dark.png \
	    macos/Sources/DeltaApp/Resources/

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

test: bindings
	cd dcvm && cargo test --locked $(CARGO_PROFILE_FLAG)
	cd macos && swift test $(SWIFT_BUILD_FLAGS)

# Full non-interactive verification: Rust tests + Swift compile/link.
check: test swift-build
