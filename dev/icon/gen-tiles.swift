// Chat background tiles from the brand pattern (assets/brand/chat-pattern.png,
// near-white with faint teal doodles):
//   light: pattern multiplied onto warm ivory  -> ivory bg, faint doodles
//   dark:  pattern inverted, screened onto midnight -> midnight bg, faint doodles
//
//   swift dev/icon/gen-tiles.swift <chat-pattern.png> <outdir>
//
// Writes chat-tile-light.png and chat-tile-dark.png (512x512) to <outdir>.

import AppKit
import CoreGraphics

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    die("usage: gen-tiles.swift <chat-pattern.png> <outdir>")
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let src = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let pattern = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { die("cannot load pattern") }

let tile = 512

func hexColor(_ hex: String) -> CGColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return CGColor(
        srgbRed: CGFloat((v >> 16) & 0xff) / 255,
        green: CGFloat((v >> 8) & 0xff) / 255,
        blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func makeContext() -> CGContext {
    CGContext(
        data: nil, width: tile, height: tile, bitsPerComponent: 8,
        bytesPerRow: tile * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func writePNG(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        die("png encode failed")
    }
    try! png.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name)")
}

let full = CGRect(x: 0, y: 0, width: tile, height: tile)

// Light: multiply keeps ivory where the pattern is white and darkens it
// slightly along the doodle strokes.
let light = makeContext()
light.setFillColor(hexColor("#F6F4EF"))
light.fill(full)
light.setBlendMode(.multiply)
light.interpolationQuality = .high
light.draw(pattern, in: full)
writePNG(light.makeImage()!, "chat-tile-light.png")

// Dark: invert the pattern (white bg -> black, strokes -> light), then
// screen onto midnight so only the strokes lift the background. Extra
// alpha keeps them subtle.
let inverter = makeContext()
inverter.setFillColor(CGColor(gray: 1, alpha: 1))
inverter.fill(full)
inverter.setBlendMode(.difference)
inverter.interpolationQuality = .high
inverter.draw(pattern, in: full)
let inverted = inverter.makeImage()!

let dark = makeContext()
dark.setFillColor(hexColor("#0D1B2A"))
dark.fill(full)
dark.setBlendMode(.screen)
dark.setAlpha(0.5)
dark.draw(inverted, in: full)
writePNG(dark.makeImage()!, "chat-tile-dark.png")
