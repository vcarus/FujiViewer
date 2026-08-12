// Renders the FujiViewer app icon (heart sun over Mt. Fuji) as an AppIcon.iconset directory.
//
// Usage: swift make-icon.swift <output-iconset-dir>
//
// Everything is drawn from paths, so each size is rendered at its own resolution rather than
// resampled from one master bitmap. `build-app.sh` runs this and feeds the result to `iconutil`;
// the repository itself stays source-only.
import AppKit
import ImageIO

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func gradientFill(_ c: CGContext, _ rect: CGRect, top: UInt32, bottom: UInt32) {
    let grad = CGGradient(colorsSpace: srgb, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad,
                         start: CGPoint(x: rect.midX, y: rect.maxY),
                         end: CGPoint(x: rect.midX, y: rect.minY),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Clips to the macOS rounded-square plate, fills the background gradient, leaves the clip active.
func beginPlate(_ c: CGContext, side S: CGFloat, top: UInt32, bottom: UInt32) -> CGRect {
    let inset = S * 0.06
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = rect.width * 0.225
    c.saveGState()
    c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.clip()
    gradientFill(c, rect, top: top, bottom: bottom)
    return rect
}

func heartPath(center: CGPoint, size w: CGFloat) -> CGPath {
    let x = center.x - w / 2
    let y = center.y - w / 2
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x + w / 2, y: y))
    p.addCurve(to: CGPoint(x: x, y: y + w * 0.7),
               control1: CGPoint(x: x + w * 0.16, y: y + w * 0.24),
               control2: CGPoint(x: x, y: y + w * 0.46))
    p.addArc(center: CGPoint(x: x + w * 0.25, y: y + w * 0.7), radius: w * 0.25,
             startAngle: .pi, endAngle: 0, clockwise: true)
    p.addArc(center: CGPoint(x: x + w * 0.75, y: y + w * 0.7), radius: w * 0.25,
             startAngle: .pi, endAngle: 0, clockwise: true)
    p.addCurve(to: CGPoint(x: x + w / 2, y: y),
               control1: CGPoint(x: x + w, y: y + w * 0.46),
               control2: CGPoint(x: x + w * 0.84, y: y + w * 0.24))
    p.closeSubpath()
    return p
}

func fillHeart(_ c: CGContext, center: CGPoint, size: CGFloat, glow: Bool) {
    c.saveGState()
    if glow { c.setShadow(offset: .zero, blur: size * 0.45, color: rgb(0xE5484D, 0.55)) }
    c.addPath(heartPath(center: center, size: size))
    c.setFillColor(rgb(0xE5484D))
    c.fillPath()
    c.restoreGState()
}

/// Mt. Fuji silhouette with a zig-zag snow cap, filling `r` (base spans the full width of `r`).
func drawFuji(_ c: CGContext, in r: CGRect, bodyTop: UInt32 = 0x51617B, bodyBottom: UInt32 = 0x2A3444) {
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
    }
    let m = CGMutablePath()
    m.move(to: P(-0.02, 0))
    m.addQuadCurve(to: P(0.40, 0.97), control: P(0.28, 0.14))
    m.addLine(to: P(0.46, 0.90))
    m.addLine(to: P(0.52, 0.97))
    m.addLine(to: P(0.57, 0.91))
    m.addLine(to: P(0.62, 0.97))
    m.addQuadCurve(to: P(1.02, 0), control: P(0.74, 0.14))
    m.closeSubpath()

    c.saveGState()
    c.addPath(m)
    c.clip()
    gradientFill(c, r, top: bodyTop, bottom: bodyBottom)

    // Snow cap: a zig-zag polygon clipped by the mountain outline.
    let s = CGMutablePath()
    s.move(to: P(0.26, 0.68))
    s.addLine(to: P(0.36, 0.56))
    s.addLine(to: P(0.44, 0.68))
    s.addLine(to: P(0.51, 0.56))
    s.addLine(to: P(0.58, 0.68))
    s.addLine(to: P(0.66, 0.56))
    s.addLine(to: P(0.74, 0.68))
    s.addLine(to: P(0.74, 1.10))
    s.addLine(to: P(0.26, 1.10))
    s.closeSubpath()
    c.addPath(s)
    c.setFillColor(rgb(0xF2F6FA))
    c.fillPath()
    c.restoreGState()
}

/// Heart sun over Fuji, drawn at `side` × `side` pixels.
func renderIcon(side S: CGFloat) -> CGImage {
    let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let r = beginPlate(c, side: S, top: 0x232C3D, bottom: 0x0B0E13)
    drawFuji(c, in: CGRect(x: r.minX - r.width * 0.05, y: r.minY + r.height * 0.10,
                           width: r.width * 1.10, height: r.height * 0.52))
    fillHeart(c, center: CGPoint(x: r.minX + r.width * 0.295, y: r.minY + r.height * 0.745),
              size: r.width * 0.21, glow: true)
    c.restoreGState()
    return c.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("error: could not create \(url.lastPathComponent)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("error: could not write \(url.lastPathComponent)\n".utf8))
        exit(1)
    }
}

/// `iconutil` expects exactly these names; the pixel size is the point size times the scale.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// One render per distinct pixel size, shared by the entries that ask for the same bitmap.
var rendered: [Int: CGImage] = [:]
for variant in variants {
    let key = Int(variant.pixels)
    let image = rendered[key] ?? renderIcon(side: variant.pixels)
    rendered[key] = image
    write(image, to: outDir.appendingPathComponent(variant.name))
}
print("wrote \(variants.count) PNGs to \(outDir.lastPathComponent)")
