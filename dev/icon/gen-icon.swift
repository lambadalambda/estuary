// Estuary icon pipeline. The logo source (assets/brand/logo-original.png) is
// an AI export with a fake-transparency checkerboard BAKED IN (no alpha), so
// step 1 recovers real transparency before compositing.
//
//   swift dev/icon/gen-icon.swift <logo-original.png> <outdir>
//
// Writes to <outdir>:
//   logo.png          — extracted logo, transparent background, cropped+padded
//   icon-1024.png     — macOS icon composite (rounded warm-ivory square)
//   Estuary.iconset/  — all sizes, ready for `iconutil -c icns`
//
// Extraction: flood fill from the borders, absorbing pixels near either
// checker color. The white wave inside the logo is also near checker-white,
// so the fill is NOT allowed to cross where it would leave via a smooth
// (anti-aliased) boundary — in practice the tight tolerance plus seeding
// only from the true border keeps it out of the logo; verify visually.

import AppKit
import CoreGraphics

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    die("usage: gen-icon.swift <logo-original.png> <outdir>")
}
let srcPath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let srcImage = NSImage(contentsOfFile: srcPath),
      let cg = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { die("cannot load \(srcPath)") }

let w = cg.width, h = cg.height

// Draw into a known RGBA8 layout so pixel math is deterministic.
let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let data = ctx.data else { die("no bitmap data") }
var px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

@inline(__always) func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * w + x) * 4
    return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
}

// Checker colors from two corner samples a half-period apart. Sample a few
// pixels in from the corner to dodge edge artifacts.
let c1 = rgb(4, 4)
var c2 = c1
for offset in stride(from: 8, to: min(w, 200), by: 4) {
    let candidate = rgb(offset, 4)
    if abs(candidate.0 - c1.0) + abs(candidate.1 - c1.1) + abs(candidate.2 - c1.2) > 12 {
        c2 = candidate
        break
    }
}
if c2 == c1 {
    // Legitimate for a plain/truly-transparent export, but on a
    // checkerboard export it means detection failed (period > scan range
    // or artwork covering the top rows) and half the checker survives.
    print("WARNING: only one background color detected — if the source has",
          "a checkerboard, the output will be corrupt. Inspect it.")
}
print("checker colors: \(c1) / \(c2)")

let tolerance = 14
@inline(__always) func isChecker(_ x: Int, _ y: Int) -> Bool {
    let p = rgb(x, y)
    for c in [c1, c2] {
        if abs(p.0 - c.0) <= tolerance, abs(p.1 - c.1) <= tolerance,
           abs(p.2 - c.2) <= tolerance { return true }
    }
    return false
}

// Border-seeded flood fill over checker-colored pixels.
var background = [Bool](repeating: false, count: w * h)
var queue: [Int] = []
for x in 0..<w {
    for y in [0, h - 1] where isChecker(x, y) {
        let i = y * w + x
        if !background[i] { background[i] = true; queue.append(i) }
    }
}
for y in 0..<h {
    for x in [0, w - 1] where isChecker(x, y) {
        let i = y * w + x
        if !background[i] { background[i] = true; queue.append(i) }
    }
}
var head = 0
while head < queue.count {
    let i = queue[head]; head += 1
    let x = i % w, y = i / w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
        guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
        let ni = ny * w + nx
        if !background[ni], isChecker(nx, ny) {
            background[ni] = true
            queue.append(ni)
        }
    }
}
print("background pixels: \(queue.count) of \(w * h)")

// Punch out the background; soften the 1px rim left by anti-aliasing by
// making any foreground pixel that touches background semi-transparent.
// The context is PREMULTIPLIED — RGB must scale with alpha, or transparent
// pixels still add their color when composited (white-box artifact).
for i in 0..<(w * h) where background[i] {
    px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
}
for y in 0..<h {
    for x in 0..<w {
        let i = y * w + x
        guard !background[i] else { continue }
        var touches = false
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
            if background[ny * w + nx] { touches = true; break }
        }
        if touches {
            for c in 0..<4 {
                px[i * 4 + c] = UInt8(Int(px[i * 4 + c]) / 2)
            }
        }
    }
}

// Crop to content + 4% padding.
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w where !background[y * w + x] {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard minX < maxX else { die("extraction removed everything — tolerance wrong") }
let pad = max(maxX - minX, maxY - minY) / 25
let cropRect = CGRect(
    x: max(0, minX - pad), y: max(0, minY - pad),
    width: min(w, maxX + pad) - max(0, minX - pad),
    height: min(h, maxY + pad) - max(0, minY - pad))
print("content bbox: \(minX),\(minY) — \(maxX),\(maxY)")

guard let extracted = ctx.makeImage(),
      // CGImage cropping uses top-left origin like our pixel loop? No:
      // CGContext rows here are bottom-up when drawn via CGContext.draw, but
      // crop coordinates are in image space (top-left). Our x/y loop indexes
      // raw rows, which for this context match image rows top-to-bottom.
      let cropped = extracted.cropping(to: cropRect)
else { die("crop failed") }

func writePNG(_ image: CGImage, to url: URL, size: Int? = nil) {
    var out = image
    if let size, image.width != size {
        let scaleCtx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        scaleCtx.interpolationQuality = .high
        // Aspect-fit into the square.
        let ar = CGFloat(image.width) / CGFloat(image.height)
        let fitW = ar >= 1 ? CGFloat(size) : CGFloat(size) * ar
        let fitH = ar >= 1 ? CGFloat(size) / ar : CGFloat(size)
        scaleCtx.draw(image, in: CGRect(
            x: (CGFloat(size) - fitW) / 2, y: (CGFloat(size) - fitH) / 2,
            width: fitW, height: fitH))
        out = scaleCtx.makeImage()!
    }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        die("png encode failed")
    }
    try! png.write(to: url)
}

writePNG(cropped, to: outDir.appendingPathComponent("logo.png"), size: 1024)

// Icon composite: Apple's Big Sur grid — 1024 canvas, rounded square
// 824x824 centered, corner radius 185. Warm ivory background (the brand
// sheet's header lockup); the logo itself carries the teals.
func hexColor(_ hex: String) -> CGColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return CGColor(
        srgbRed: CGFloat((v >> 16) & 0xff) / 255,
        green: CGFloat((v >> 8) & 0xff) / 255,
        blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func makeIcon(canvas: Int) -> CGImage {
    let iconCtx = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
        bytesPerRow: canvas * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(canvas) / 1024
    let square = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(
        roundedRect: square, cornerWidth: 185 * s, cornerHeight: 185 * s,
        transform: nil)
    iconCtx.addPath(path)
    iconCtx.setFillColor(hexColor("#F6F4EF"))
    iconCtx.fillPath()
    // Logo at ~72% of the square, nudged up slightly: the speech-bubble tail
    // hangs low, so optical center sits above geometric center.
    let logoW = square.width * 0.78
    let ar = CGFloat(cropped.width) / CGFloat(cropped.height)
    let logoH = logoW / ar
    iconCtx.interpolationQuality = .high
    iconCtx.draw(cropped, in: CGRect(
        x: square.midX - logoW / 2,
        y: square.midY - logoH / 2 + square.height * 0.02,
        width: logoW, height: logoH))
    return iconCtx.makeImage()!
}

writePNG(makeIcon(canvas: 1024), to: outDir.appendingPathComponent("icon-1024.png"))

let iconsetURL = outDir.appendingPathComponent("Estuary.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                       (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = point * scale
    let name = scale == 1
        ? "icon_\(point)x\(point).png"
        : "icon_\(point)x\(point)@2x.png"
    writePNG(makeIcon(canvas: pixels), to: iconsetURL.appendingPathComponent(name))
}
print("done → \(outDir.path)")
