// Draws Parley's app icon: a speech bubble whose middle line carries the
// reader-player's follow-along highlight (the sentence band and the current
// word). Writes the three 1024-pt appearances the asset catalog uses.
//
//   swift ios/tools/make-app-icon.swift ios/Parley/Assets.xcassets/AppIcon.appiconset
//
// macOS only (CoreGraphics, ImageIO). The PNGs are committed; run this again
// only to change the icon.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024

struct Palette {
    var backgroundTop: CGColor
    var backgroundBottom: CGColor
    var bubble: CGColor
    var line: CGColor
    var band: CGColor
    var word: CGColor
    var opaque: Bool
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: white, green: white, blue: white, alpha: alpha)
}

let palettes: [(file: String, palette: Palette)] = [
    ("AppIcon.png", Palette(
        backgroundTop: rgb(0x3D7BFF), backgroundBottom: rgb(0x1B3FC4),
        bubble: rgb(0xFFFFFF), line: rgb(0xC9D3E6),
        band: rgb(0xDCE8FF), word: rgb(0x1F5BFF), opaque: true)),
    ("AppIcon-Dark.png", Palette(
        backgroundTop: rgb(0x1A2140), backgroundBottom: rgb(0x080B18),
        bubble: rgb(0x2A3352), line: rgb(0x55607F),
        band: rgb(0x34497F), word: rgb(0x5B8CFF), opaque: true)),
    // Tinted: grayscale on black; the system applies the user's tint.
    ("AppIcon-Tinted.png", Palette(
        backgroundTop: gray(0), backgroundBottom: gray(0),
        bubble: gray(0.92), line: gray(0.55),
        band: gray(0.75), word: gray(0.25), opaque: true)),
]

func roundedRect(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

func draw(_ p: Palette) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = p.opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: info.rawValue)!
    // Top-left origin, y down, so the numbers below read like the design.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)

    let gradient = CGGradient(
        colorsSpace: space, colors: [p.backgroundTop, p.backgroundBottom] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])

    // The bubble, lifted a little so the bubble and its tail sit centred.
    let dy: CGFloat = -34
    let bubble = CGRect(x: 172, y: 220 + dy, width: 680, height: 500)
    roundedRect(ctx, bubble, 132, p.bubble)

    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 300, y: bubble.maxY - 40))
    tail.addLine(to: CGPoint(x: 444, y: bubble.maxY - 40))
    tail.addQuadCurve(
        to: CGPoint(x: 252, y: bubble.maxY + 108),
        control: CGPoint(x: 360, y: bubble.maxY + 70))
    tail.addQuadCurve(
        to: CGPoint(x: 300, y: bubble.maxY - 40),
        control: CGPoint(x: 300, y: bubble.maxY + 40))
    tail.closeSubpath()
    ctx.addPath(tail)
    ctx.setFillColor(p.bubble)
    ctx.fillPath()

    // Three lines of text; the middle one is being spoken.
    let lineHeight: CGFloat = 60
    let left: CGFloat = 262
    let mid = bubble.midY
    let gap: CGFloat = 122

    roundedRect(ctx, CGRect(x: left, y: mid - gap - lineHeight / 2, width: 500, height: lineHeight),
                lineHeight / 2, p.line)

    roundedRect(ctx, CGRect(x: left - 34, y: mid - 56, width: 568, height: 112), 56, p.band)
    roundedRect(ctx, CGRect(x: left, y: mid - lineHeight / 2, width: 120, height: lineHeight),
                lineHeight / 2, p.line)
    roundedRect(ctx, CGRect(x: left + 146, y: mid - 44, width: 210, height: 88), 44, p.word)
    roundedRect(ctx, CGRect(x: left + 382, y: mid - lineHeight / 2, width: 118, height: lineHeight),
                lineHeight / 2, p.line)

    roundedRect(ctx, CGRect(x: left, y: mid + gap - lineHeight / 2, width: 330, height: lineHeight),
                lineHeight / 2, p.line)

    return ctx.makeImage()!
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-app-icon.swift <AppIcon.appiconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (file, palette) in palettes {
    let url = outDir.appendingPathComponent(file)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, draw(palette), nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("could not write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(url.path)")
}
