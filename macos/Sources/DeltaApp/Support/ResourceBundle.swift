import Foundation

/// Locates the SwiftPM resource bundle for the app target. `Bundle.module`'s
/// generated accessor only checks the app-bundle ROOT and the build machine's
/// absolute scratch path — in an installed .app neither exists, so first
/// access trapped on every machine except the one that built the DMG (see
/// meta/issues/nightly-dmg-bundle-module-crash.md). App code goes through
/// `AppResources.bundle` instead of `Bundle.module`.
enum AppResources {
    static let bundleName = "DeltaApp_DeltaApp"

    /// First `<dir>/<name>.bundle` directory among the ordered candidates,
    /// loaded as a Bundle. Pure candidate search — nil when nothing matches,
    /// never traps.
    static func locate(
        named name: String, in directories: [URL?],
        fileManager: FileManager = .default
    ) -> Bundle? {
        for directory in directories {
            guard let url = directory?.appendingPathComponent("\(name).bundle")
            else { continue }
            var isDirectory: ObjCBool = false
            guard
                fileManager.fileExists(
                    atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }
        return nil
    }

    /// The app's resource bundle. A packaged .app serves it from
    /// Contents/Resources (where `make app` copies it); the bare `swift run`
    /// binary finds it next to the executable. Only when both miss — the dev
    /// test runner — does this consult the generated accessor, whose baked
    /// build path works there (and whose trap-on-miss then reports a
    /// genuinely broken install instead of a packaging layout mismatch).
    static let bundle: Bundle =
        locate(
            named: bundleName,
            in: [Bundle.main.resourceURL, Bundle.main.bundleURL]
        ) ?? .module
}
