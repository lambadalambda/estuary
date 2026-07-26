// swift-tools-version:6.0
import PackageDescription

// Which cargo profile's libdcvm.a to link — the Makefile exports
// DCVM_PROFILE (debug default; release for `make app-release`). NOTE: SPM
// caches the evaluated manifest, so a profile switch needs a separate
// scratch dir (the Makefile handles this) or the old lib dir sticks.
let rustProfile = Context.environment["DCVM_PROFILE"] ?? "debug"
let rustLibDir = "\(Context.packageDirectory)/../dcvm/target/\(rustProfile)"

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
            resources: [
                .copy("Resources/estuary-logo.png"),
                .copy("Resources/mock-sunset.jpg"),
                .copy("Resources/mock-voice.m4a"),
                .copy("Resources/chat-tile-light.png"),
                .copy("Resources/chat-tile-dark.png"),
            ],
            linkerSettings: [
                .linkedLibrary("dcvm"),
                .unsafeFlags(["-L\(rustLibDir)"]),
                // Required by the Rust dependency tree (added as linker
                // errors dictated): netwatch/system-configuration.
                .linkedFramework("SystemConfiguration"),
                // transcribe.cpp (GGML) in libdcvm.a: C++ runtime + Metal.
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate")
            ]
        ),

        .testTarget(
            name: "DeltaAppTests",
            dependencies: ["DeltaApp"],
            path: "Tests/DeltaAppTests",
            linkerSettings: [
                .linkedLibrary("dcvm"),
                .unsafeFlags(["-L\(rustLibDir)"]),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate")
            ]
        )
    ]
)
