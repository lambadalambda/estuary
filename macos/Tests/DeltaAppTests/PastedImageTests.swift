import AppKit
import Testing

@testable import DeltaApp

/// Pasted-image temp-file helper (issue: composer-image-paste).
@Suite struct PastedImageTests {
    private func sampleTIFF(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image.tiffRepresentation!
    }

    @Test func pastedBitmapLandsAsLoadablePNGFile() throws {
        let path = try #require(stagePastedImageData(sampleTIFF(width: 20, height: 10)))
        #expect(path.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: path))
        let loaded = try #require(NSImage(contentsOfFile: path))
        #expect(loaded.size.width > 0)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func garbageDataStagesNothing() {
        #expect(stagePastedImageData(Data([0x00, 0x01, 0x02])) == nil)
    }

    @Test func distinctPastesGetDistinctFiles() throws {
        let data = sampleTIFF(width: 4, height: 4)
        let first = try #require(stagePastedImageData(data))
        let second = try #require(stagePastedImageData(data))
        #expect(first != second)
        try? FileManager.default.removeItem(atPath: first)
        try? FileManager.default.removeItem(atPath: second)
    }
}
