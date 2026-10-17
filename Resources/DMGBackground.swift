// Renders the disk-image window background: `swift Resources/DMGBackground.swift <out.png> <scale>`.
// Layout is in points, top-left origin, and must match Resources/dmg-settings.py.
import AppKit

let width: CGFloat = 640, height: CGFloat = 420
let appIcon = CGPoint(x: 170, y: 200)
let applicationsIcon = CGPoint(x: 470, y: 200)
let iconSize: CGFloat = 128

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// rep.size is in points, so the context already maps points to pixels at `scale`.
let ctx = NSGraphicsContext.current!.cgContext
// Work in top-left coordinates like Finder.
ctx.translateBy(x: 0, y: height)
ctx.scaleBy(x: 1, y: -1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Night sky, same palette as the app icon.
let sky = CGGradient(colorsSpace: space, colors: [color(0x2A3A7A), color(0x141B45), color(0x070B1E)] as CFArray,
                     locations: [0, 0.6, 1])!
ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])

// Soft moonlight behind the app icon.
let glow = CGGradient(colorsSpace: space, colors: [color(0xF6E7B8, 0.14), color(0xF6E7B8, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: appIcon, startRadius: 0, endCenter: appIcon, endRadius: 150, options: [])

// Stars.
let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (40, 40, 1.4, 0.8), (96, 118, 1.0, 0.6), (210, 30, 1.2, 0.7), (300, 124, 0.9, 0.5), (352, 24, 1.5, 0.8),
    (430, 70, 1.0, 0.6), (520, 34, 1.3, 0.7), (600, 96, 1.1, 0.6), (612, 260, 1.0, 0.5), (24, 300, 1.2, 0.5),
    (320, 330, 0.9, 0.4), (560, 380, 1.2, 0.5), (90, 392, 1.0, 0.4), (250, 300, 0.8, 0.4), (400, 140, 0.8, 0.45),
]
for (x, y, r, a) in stars {
    ctx.setFillColor(color(0xFFFFFF, a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

func sparkle(_ c: CGPoint, _ r: CGFloat, alpha: CGFloat) {
    let w = r * 0.28
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    ctx.addPath(p)
    ctx.setFillColor(color(0xFFF6DA, alpha))
    ctx.fillPath()
}
sparkle(CGPoint(x: 566, y: 70), 9, alpha: 0.85)
sparkle(CGPoint(x: 70, y: 76), 6, alpha: 0.7)

// Heading.
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, alpha: CGFloat, centerY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: color(hex, alpha))!,
    ]
    let s = NSAttributedString(string: string, attributes: attrs)
    let bounds = s.size()
    // Text draws in a flipped context; NSString drawing handles flipped graphics contexts.
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    s.draw(at: CGPoint(x: (width - bounds.width) / 2, y: centerY - bounds.height / 2))
}
text("Drag Nightwarden to Applications", size: 20, weight: .semibold, hex: 0xF6EBCB, alpha: 1, centerY: 58)
text("Then open it from Applications. It lives in your menu bar.", size: 12.5, weight: .regular, hex: 0xC9CFEA, alpha: 0.85, centerY: 86)

// Arrow from the app to Applications.
let start = CGPoint(x: appIcon.x + iconSize / 2 + 26, y: appIcon.y)
let end = CGPoint(x: applicationsIcon.x - iconSize / 2 - 26, y: appIcon.y)
let control = CGPoint(x: (start.x + end.x) / 2, y: appIcon.y - 34)
let arrow = CGMutablePath()
arrow.move(to: start)
arrow.addQuadCurve(to: end, control: control)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 10, color: color(0xF6E7B8, 0.45))
ctx.addPath(arrow)
ctx.setStrokeColor(color(0xF6EBCB, 0.95))
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [1, 11])
ctx.strokePath()
ctx.restoreGState()
// Arrowhead along the curve's final tangent.
let angle = atan2(end.y - control.y, end.x - control.x)
let head = CGMutablePath()
let len: CGFloat = 16, spread: CGFloat = .pi / 5.5
head.move(to: CGPoint(x: end.x - len * cos(angle - spread), y: end.y - len * sin(angle - spread)))
head.addLine(to: end)
head.addLine(to: CGPoint(x: end.x - len * cos(angle + spread), y: end.y - len * sin(angle + spread)))
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 10, color: color(0xF6E7B8, 0.45))
ctx.addPath(head)
ctx.setStrokeColor(color(0xF6EBCB, 0.95))
ctx.setLineWidth(4)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// Label plates. Finder draws icon labels black in Light Mode and white in Dark Mode; this mid-tone
// (luminance ≈ 0.18) keeps both at roughly 4.6:1 contrast.
for center in [appIcon, applicationsIcon] {
    let plate = CGRect(x: center.x - 70, y: center.y + iconSize / 2 + 7, width: 140, height: 26)
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.setFillColor(color(0x6E7392))
    ctx.fillPath()
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
