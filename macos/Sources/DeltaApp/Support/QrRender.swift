import AppKit
import CoreImage

/// Renders a QR code for `payload` (securejoin invite links etc.,
/// issue: qr-invite-contact-flow). Kept at NATIVE module scale (1px per
/// module): displaying larger with `Image.interpolation(.none)` then
/// only ever UPSCALES, which preserves every module. A pre-enlarged
/// bitmap shown in a smaller frame would nearest-neighbor DOWNSCALE and
/// drop whole module rows on 1x displays — phones stop scanning it.
func qrImage(for payload: String, moduleScale: CGFloat = 1) -> NSImage? {
    guard !payload.isEmpty,
        let data = payload.data(using: .utf8),
        let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(
        by: CGAffineTransform(scaleX: moduleScale, y: moduleScale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}
