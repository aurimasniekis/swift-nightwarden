// Renders the Nightwarden app icon: `swift Resources/AppIcon.swift <out.png>` (1024×1024).
// `make icon` turns it into Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// macOS icon grid: 824 pt squircle centred on a 1024 canvas, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).cgPath

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(color(0x0B1026))
ctx.fillPath()
ctx.restoreGState()

// Night sky gradient.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let sky = CGGradient(colorsSpace: space, colors: [color(0x2A3A7A), color(0x141B45), color(0x070B1E)] as CFArray,
                     locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Moon glow.
let moonCenter = CGPoint(x: 470, y: 540)
let moonRadius: CGFloat = 250
let glow = CGGradient(colorsSpace: space, colors: [color(0xF6E7B8, 0.16), color(0xF6E7B8, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: moonCenter, startRadius: moonRadius * 0.8,
                       endCenter: moonCenter, endRadius: moonRadius * 1.6, options: [.drawsBeforeStartLocation])

// Stars: four-point sparkles.
func sparkle(_ c: CGPoint, _ r: CGFloat, alpha: CGFloat = 1) {
    let p = CGMutablePath()
    let w = r * 0.28
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
    ctx.addPath(p)
    ctx.setFillColor(color(0xFFF6DA, alpha))
    ctx.fillPath()
}
sparkle(CGPoint(x: 705, y: 735), 62)
sparkle(CGPoint(x: 790, y: 590), 34, alpha: 0.9)
sparkle(CGPoint(x: 615, y: 860), 22, alpha: 0.8)
for (x, y, r) in [(260.0, 790.0, 7.0), (350, 300, 6), (760, 330, 8), (230, 450, 5), (840, 450, 5), (820, 760, 5)] {
    ctx.setFillColor(color(0xFFFFFF, 0.7))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// Crescent: the moon disc with an offset disc cut away.
ctx.saveGState()
ctx.addRect(tile)
ctx.addEllipse(in: CGRect(x: moonCenter.x + 95 - moonRadius * 0.92, y: moonCenter.y + 70 - moonRadius * 0.92,
                          width: moonRadius * 1.84, height: moonRadius * 1.84))
ctx.clip(using: .evenOdd)
ctx.addEllipse(in: CGRect(x: moonCenter.x - moonRadius, y: moonCenter.y - moonRadius,
                          width: moonRadius * 2, height: moonRadius * 2))
ctx.clip()
let moon = CGGradient(colorsSpace: space, colors: [color(0xFFF4D2), color(0xF0D58C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(moon, start: CGPoint(x: moonCenter.x - moonRadius, y: moonCenter.y + moonRadius),
                       end: CGPoint(x: moonCenter.x + moonRadius * 0.3, y: moonCenter.y - moonRadius), options: [])
ctx.restoreGState()

// Subtle inner rim.
ctx.addPath(NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183).cgPath)
ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
