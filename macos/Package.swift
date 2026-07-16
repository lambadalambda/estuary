// swift-tools-version:6.0
import PackageDescription

// NOTE for the core-integration stage: this package intentionally contains ONLY
// the executable target. The generated UniFFI targets are added later as:
//   .systemLibrary(name: "DeltaCoreFFI", path: "Sources/DeltaCoreFFI"),
//   .target(name: "DeltaCore", dependencies: ["DeltaCoreFFI"],
//           path: "Sources/DeltaCore", swiftSettings: [.swiftLanguageMode(.v5)]),
// plus linkerSettings on DeltaApp (see docs/specs/uniffi-recipe.md section 5).
let package = Package(
    name: "DeltaApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeltaApp",
            path: "Sources/DeltaApp"
        )
    ]
)
