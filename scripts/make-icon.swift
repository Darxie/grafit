// Renders the app icon (a revision graph on a dark squircle) into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a 1024 top-left based coordinate system.
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: s, y: -s)

    // Squircle body following the macOS icon grid (824pt body, 100pt margin).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1B2030))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil,
                              colors: [color(0x323A52), color(0x161A24)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Faint grid lines like commit rows.
    ctx.setStrokeColor(color(0xFFFFFF, 0.035))
    ctx.setLineWidth(4)
    for y in stride(from: 250.0, through: 800.0, by: 110.0) {
        ctx.move(to: CGPoint(x: 100, y: y))
        ctx.addLine(to: CGPoint(x: 924, y: y))
    }
    ctx.strokePath()
    ctx.restoreGState()

    let blue = color(0x4A86F0), red = color(0xE8584A), green = color(0x3DBB6A)
    let mainX: CGFloat = 332, branchX: CGFloat = 572, sideX: CGFloat = 692
    let lineWidth: CGFloat = 46

    func stroke(_ build: (CGMutablePath) -> Void, _ c: CGColor) {
        let path = CGMutablePath()
        build(path)
        ctx.addPath(path)
        ctx.setStrokeColor(c)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // Red feature branch: leaves main at the bottom, merges back near the top.
    stroke({ p in
        p.move(to: CGPoint(x: mainX, y: 700))
        p.addCurve(to: CGPoint(x: branchX, y: 560), control1: CGPoint(x: mainX, y: 620), control2: CGPoint(x: branchX, y: 640))
        p.addLine(to: CGPoint(x: branchX, y: 450))
        p.addCurve(to: CGPoint(x: mainX, y: 300), control1: CGPoint(x: branchX, y: 370), control2: CGPoint(x: mainX, y: 380))
    }, red)
    // Green side branch heading off to the right.
    stroke({ p in
        p.move(to: CGPoint(x: mainX, y: 810))
        p.addCurve(to: CGPoint(x: sideX, y: 700), control1: CGPoint(x: mainX, y: 740), control2: CGPoint(x: sideX - 160, y: 700))
    }, green)
    // Blue main line.
    stroke({ p in
        p.move(to: CGPoint(x: mainX, y: 860))
        p.addLine(to: CGPoint(x: mainX, y: 210))
    }, blue)

    func node(_ x: CGFloat, _ y: CGFloat, _ c: CGColor, hollow: Bool = false) {
        let r: CGFloat = 50
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        // Ring in the background color separates nodes from lines.
        ctx.setFillColor(color(0x1E2333))
        ctx.fillEllipse(in: rect.insetBy(dx: -16, dy: -16))
        if hollow {
            ctx.setStrokeColor(c)
            ctx.setLineWidth(26)
            ctx.strokeEllipse(in: rect.insetBy(dx: 13, dy: 13))
        } else {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: rect)
        }
    }
    node(mainX, 230, blue, hollow: true)  // HEAD
    node(mainX, 420, blue)
    node(branchX, 505, red)
    node(mainX, 590, blue)
    node(sideX, 700, green)
    node(mainX, 780, blue)

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
