// swift-tools-version:6.0
import PackageDescription

// Dev profile: libdcvm.a comes out of `cargo build` (see root Makefile).
// A release build of deltachat core takes 10+ minutes, so we link debug.
let rustLibDir = "\(Context.packageDirectory)/../dcvm/target/debug"

let package = Package(
    name: "DeltaApp",
    platforms: [.macOS(.v15)],
    targets: [
        // C FFI module: generated module.modulemap + DeltaCoreFFI.h.
        .systemLibrary(name: "DeltaCoreFFI", path: "Sources/DeltaCoreFFI"),

        // Generated UniFFI bindings. Swift 5 language mode: UniFFI's Swift 6
        // support is partial (async code not Sendable-clean, uniffi-rs#2448).
        .target(
            name: "DeltaCore",
            dependencies: ["DeltaCoreFFI"],
            path: "Sources/DeltaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .executableTarget(
            name: "DeltaApp",
            dependencies: ["DeltaCore"],
            path: "Sources/DeltaApp",
            // Brand assets (Bundle.module). The Makefile `app` target must
            // copy the generated DeltaApp_DeltaApp.bundle into the .app's
            // Contents/Resources, or Bundle.module traps at runtime.
            resources: [.copy("Resources/estuary-logo.png")],
            linkerSettings: [
                .linkedLibrary("dcvm"),
                .unsafeFlags(["-L\(rustLibDir)"]),
                // Required by the Rust dependency tree (added as linker
                // errors dictated): netwatch/system-configuration.
                .linkedFramework("SystemConfiguration")
            ]
        ),

        .testTarget(
            name: "DeltaAppTests",
            dependencies: ["DeltaApp"],
            path: "Tests/DeltaAppTests",
            linkerSettings: [
                .linkedLibrary("dcvm"),
                .unsafeFlags(["-L\(rustLibDir)"]),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
