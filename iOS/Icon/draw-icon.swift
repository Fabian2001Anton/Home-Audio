// Draws the app icon drafts for HeimAudio.
//
// Usage:   swift draw-icon.swift <output folder>
// Result:  AppIcon-A.png, AppIcon-B.png, AppIcon-C.png (1024 × 1024 each) and vorschau.png
//
// Colors and shapes can be adjusted below in the functions drawVariantA/B/C.
// Coordinates: 1024 × 1024, origin at the top left.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func gradient(_ ctx: CGContext, _ from: UInt32, _ to: UInt32, _ start: CGPoint, _ end: CGPoint) {
    let g = CGGradient(colorsSpace: srgb, colors: [color(from), color(to)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Outline of a house: roof with overhang, the body of the house below it.
func housePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 512, y: 220))
    p.addLine(to: CGPoint(x: 800, y: 478))
    p.addLine(to: CGPoint(x: 728, y: 478))
    p.addLine(to: CGPoint(x: 728, y: 812))
    p.addLine(to: CGPoint(x: 296, y: 812))
    p.addLine(to: CGPoint(x: 296, y: 478))
    p.addLine(to: CGPoint(x: 224, y: 478))
    p.closeSubpath()
    return p
}

// Fills a shape with rounded corners.
func fillRounded(_ ctx: CGContext, _ path: CGPath, _ fill: CGColor, radius: CGFloat) {
    ctx.setFillColor(fill)
    ctx.setStrokeColor(fill)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setLineWidth(radius * 2)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

// A: blue house symbol with sound waves
func drawVariantA(_ ctx: CGContext) {
    gradient(ctx, 0x5B8CFF, 0x2B2FC2, CGPoint(x: 0, y: 0), CGPoint(x: 1024, y: 1024))
    fillRounded(ctx, housePath(), color(0xFFFFFF), radius: 22)

    let blue = color(0x3F5BEA)
    let source = CGPoint(x: 400, y: 650)
    ctx.setFillColor(blue)
    ctx.fillEllipse(in: CGRect(x: source.x - 36, y: source.y - 36, width: 72, height: 72))
    ctx.setStrokeColor(blue)
    ctx.setLineWidth(38)
    ctx.setLineCap(.round)
    let angle = 38 * CGFloat.pi / 180
    for radius in [100, 170, 240] as [CGFloat] {
        ctx.addArc(center: source, radius: radius, startAngle: -angle, endAngle: angle, clockwise: false)
        ctx.strokePath()
    }
}

// B: dark, house as a glowing line with equalizer bars
func drawVariantB(_ ctx: CGContext) {
    gradient(ctx, 0x2A2D3E, 0x111218, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1024))

    ctx.saveGState()
    ctx.addPath(housePath())
    ctx.setLineWidth(46)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    gradient(ctx, 0xFFB340, 0xFF2D6F, CGPoint(x: 512, y: 200), CGPoint(x: 512, y: 840))
    ctx.restoreGState()

    let heights: [CGFloat] = [100, 190, 250, 170, 110]
    let barWidth: CGFloat = 46
    let spacing: CGFloat = 76
    let centerY: CGFloat = 640
    let startX = 512 - spacing * 2 - barWidth / 2
    ctx.saveGState()
    for (i, h) in heights.enumerated() {
        let bar = CGRect(x: startX + CGFloat(i) * spacing, y: centerY - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    }
    ctx.clip()
    gradient(ctx, 0xFFB340, 0xFF2D6F, CGPoint(x: 512, y: 500), CGPoint(x: 512, y: 800))
    ctx.restoreGState()
}

// C: green house symbol with a play triangle
func drawVariantC(_ ctx: CGContext) {
    gradient(ctx, 0x3EDBC8, 0x1FA85A, CGPoint(x: 0, y: 0), CGPoint(x: 1024, y: 1024))
    fillRounded(ctx, housePath(), color(0xFFFFFF), radius: 22)

    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 448, y: 548))
    triangle.addLine(to: CGPoint(x: 448, y: 752))
    triangle.addLine(to: CGPoint(x: 624, y: 650))
    triangle.closeSubpath()
    fillRounded(ctx, triangle, color(0x2BBE8C), radius: 18)
}

// Draws one icon: 1024 × 1024, without transparency (as Apple requires).
func render(_ variant: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    variant(ctx)
    return ctx.makeImage()!
}

func save(_ image: CGImage, _ url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Konnte \(url.path) nicht schreiben") }
}

// Preview: all drafts side by side, with rounded corners as on the home screen.
func preview(_ images: [(String, CGImage)]) -> CGImage {
    let side: CGFloat = 300, margin: CGFloat = 60
    let width = Int(CGFloat(images.count) * side + CGFloat(images.count + 1) * margin)
    let height = Int(side + margin + 110)
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.setFillColor(color(0xF2F2F7))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for (i, (name, image)) in images.enumerated() {
        let x = margin + CGFloat(i) * (side + margin)
        let frame = CGRect(x: x, y: CGFloat(height) - margin - side, width: side, height: side)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: side * 0.2237, cornerHeight: side * 0.2237, transform: nil))
        ctx.clip()
        ctx.draw(image, in: frame)
        ctx.restoreGState()

        let text = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: x + side / 2 - CGFloat(textWidth) / 2, y: 45)
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fatalError("Aufruf: swift draw-icon.swift <Ausgabeordner>") }
let outputFolder = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

let drafts: [(String, CGImage)] = [
    ("A", render(drawVariantA)),
    ("B", render(drawVariantB)),
    ("C", render(drawVariantC)),
]
for (name, image) in drafts {
    save(image, outputFolder.appendingPathComponent("AppIcon-\(name).png"))
}
save(preview(drafts), outputFolder.appendingPathComponent("vorschau.png"))
print("Gespeichert in \(outputFolder.path)")
