import AppKit

private var pastedImagesDir: URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("EstuaryPasted", isDirectory: true)
}

/// Writes pasted image data to a temp file the send path can use
/// (issue: composer-image-paste). Pasteboard bitmaps arrive as TIFF as
/// often as PNG, so everything is normalized through NSBitmapImageRep to
/// a portable .png; the attachment then flows through the same staging
/// as dropped/picked files. Encode + write are synchronous on the caller
/// (the paste keypress): a 5K-screenshot paste hitches briefly — known
/// v1 trade-off, the swallow-the-event decision has to be synchronous.
func stagePastedImageData(_ data: Data) -> String? {
    guard let rep = NSBitmapImageRep(data: data),
        let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    try? FileManager.default.createDirectory(
        at: pastedImagesDir, withIntermediateDirectories: true)
    let url = pastedImagesDir.appendingPathComponent(UUID().uuidString + ".png")
    do {
        try png.write(to: url)
        return url.path
    } catch {
        return nil
    }
}

/// Deletes a no-longer-staged paste temp file. STRICTLY scoped to our
/// own temp dir — replace/remove must never touch a user's dropped or
/// picked file. Sent files are left alone (the mock renders from the
/// original path); macOS's tmp purge reclaims them.
func discardPastedTempFile(_ path: String) {
    guard URL(fileURLWithPath: path).standardizedFileURL.path
        .hasPrefix(pastedImagesDir.standardizedFileURL.path)
    else { return }
    try? FileManager.default.removeItem(atPath: path)
}
