import AppKit
import CoreImage

/// QR decoding for the "add second device" flow: the other device shows a
/// DCBACKUP QR; on a Mac without a camera flow the user drops in a photo,
/// screenshot, or clipboard image instead. Pure functions over CoreImage.
enum QrDecode {
    /// Returns the payload of the first QR code found in the image, if any.
    static func payload(in image: CIImage) -> String? {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?
            .features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }

    static func payload(inFileAt url: URL) -> String? {
        CIImage(contentsOf: url).flatMap(payload(in:))
    }

    /// Checks the general pasteboard for either a QR image or a pasted
    /// QR payload string (e.g. "DCBACKUP2:...").
    static func payloadFromPasteboard(_ pasteboard: NSPasteboard = .general) -> String? {
        if let data = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
           let image = CIImage(data: data),
           let payload = payload(in: image) {
            return payload
        }
        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty {
            return text
        }
        return nil
    }
}
