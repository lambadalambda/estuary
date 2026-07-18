import Foundation
import Testing

@testable import DeltaApp

// Guards the packaged-app resource lookup: SwiftPM's generated Bundle.module
// accessor only checks the app-bundle root and the build machine's absolute
// scratch path, so a shipped .app trapped on every other machine (see
// meta/issues/nightly-dmg-bundle-module-crash.md). AppResources.locate is the
// pure candidate-order search that fixes that; these tests pin its semantics.

@Suite struct AppResourcesTests {
    /// Fresh temp dir per call; caller cleans up.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-bundle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(named name: String, in dir: URL) throws -> URL {
        let bundle = dir.appendingPathComponent("\(name).bundle")
        try FileManager.default.createDirectory(
            at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    @Test func findsBundleInFirstCandidateDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = try makeBundle(named: "Fixture", in: dir)

        let found = AppResources.locate(named: "Fixture", in: [dir])
        #expect(found?.bundleURL.path == expected.path)
    }

    @Test func earlierCandidateWinsOverLater() throws {
        let first = try makeTempDir()
        let second = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let inFirst = try makeBundle(named: "Fixture", in: first)
        _ = try makeBundle(named: "Fixture", in: second)

        let found = AppResources.locate(named: "Fixture", in: [first, second])
        #expect(found?.bundleURL.path == inFirst.path)
    }

    @Test func skipsNilAndEmptyCandidates() throws {
        let empty = try makeTempDir()
        let hit = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: hit)
        }
        let expected = try makeBundle(named: "Fixture", in: hit)

        let found = AppResources.locate(named: "Fixture", in: [nil, empty, hit])
        #expect(found?.bundleURL.path == expected.path)
    }

    @Test func returnsNilWhenNoCandidateHasTheBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(AppResources.locate(named: "Fixture", in: [dir, nil]) == nil)
    }

    @Test func ignoresPlainFileMasqueradingAsBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Fixture.bundle")
        try Data().write(to: file)

        #expect(AppResources.locate(named: "Fixture", in: [dir]) == nil)
    }

    /// In the dev/test environment the packaged-app candidates miss and the
    /// generated accessor's build path serves the bundle — the fallback leg
    /// of AppResources.bundle. Reaching the real logo proves the wired-up
    /// chain works end to end here.
    @Test func appBundleServesKnownResource() {
        #expect(
            AppResources.bundle.url(
                forResource: "estuary-logo", withExtension: "png") != nil)
    }
}
