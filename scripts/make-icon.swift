// Draws Vie's app icon and writes it as an .icns: the word "vie" with Vim's block cursor
// on the v, between two lines of code. Drawn in Core Graphics at every size the .icns
// holds (16 to 1024 px), then packed with iconutil.
//
// Usage: make icon  (compiles this file and writes App/AppIcon.icns)
//
// The art follows the macOS icon grid: an 824 px body with continuous corners on a 1024
// canvas. macOS 27 shows an .icns drawn on that grid as is, adding its own glass edge;
// art off the grid gets a gray background. The layered Icon Composer format would need
// Xcode's actool, which Command Line Tools doesn't include.

import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185.4

let navyTop = rgb(0x34425E), navyBottom = rgb(0x121725)
let mint = rgb(0x5EEAD4), textColor = rgb(0xE8EAF0)
let keyword = rgb(0xC792EA, 0.75), name = rgb(0x82AAFF, 0.75)
let comment = rgb(0x8B95AB, 0.75), string = rgb(0xC3E88D, 0.75)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A rounded rect with smoothed corners (Figma's corner smoothing, 60%), close to the
/// continuous corners of macOS icons.
func squircle(_ r: CGRect, radius R: CGFloat, smoothing s: CGFloat = 0.6) -> CGPath {
    let rad = { (degrees: CGFloat) in degrees * .pi / 180 }
    let p = (1 + s) * R
    let arcMeasure = 90 * (1 - s)
    let arcLength = sin(rad(arcMeasure / 2)) * R * sqrt(2)
    let c = R * tan(rad((90 - arcMeasure) / 4)) * cos(rad(45 * s))
    let d = c * tan(rad(45 * s))
    let b = (p - arcLength - c - d) / 3
    let a = 2 * b
    // Each corner: its point, the direction along the edge into it, and the direction out.
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    path.move(to: CGPoint(x: r.minX + p, y: r.maxY))
    for (corner, along, out) in corners {
        func at(_ o: CGPoint, _ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: o.x + u * along.dx + v * out.dx, y: o.y + u * along.dy + v * out.dy)
        }
        let p0 = at(corner, -p, 0)
        path.addLine(to: p0)
        let p1 = at(p0, a + b + c, d)
        path.addCurve(to: p1, control1: at(p0, a, 0), control2: at(p0, a + b, 0))
        let center = at(corner, -R, R)
        let p2 = at(p1, arcLength, arcLength)
        let a0 = atan2(p1.y - center.y, p1.x - center.x), a1 = atan2(p2.y - center.y, p2.x - center.x)
        var sweep = a1 - a0
        if sweep > .pi { sweep -= 2 * .pi } else if sweep < -.pi { sweep += 2 * .pi }
        path.addArc(center: center, radius: R, startAngle: a0, endAngle: a1, clockwise: sweep < 0)
        path.addCurve(to: at(p2, d, a + b + c), control1: at(p2, d, c), control2: at(p2, d, b + c))
    }
    path.closeSubpath()
    return path
}

/// Draws the icon on the 1024 canvas; `scale` maps it to the context's pixels (shadows
/// don't follow the transform, so their blur is scaled by hand).
func draw(_ ctx: CGContext, scale: CGFloat) {
    ctx.scaleBy(x: scale, y: scale)

    ctx.saveGState()
    ctx.addPath(squircle(body, radius: cornerRadius))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [navyBottom, navyTop] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
    ctx.restoreGState()

    let size: CGFloat = 290
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    func line(_ s: String, _ color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    }
    let v = line("v", navyBottom)
    let advance = CGFloat(CTLineGetTypographicBounds(v, nil, nil, nil))
    let x0 = canvas / 2 - advance * 1.5
    let baseline = canvas / 2 - size * 0.3

    // The block cursor, glowing, then "v" on it and "ie" after it.
    let cell = CGRect(x: x0 - size * 0.02, y: baseline - size * 0.26, width: advance + size * 0.04, height: size * 1.12)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.15 * scale, color: mint.copy(alpha: 0.65))
    ctx.addPath(CGPath(roundedRect: cell, cornerWidth: size * 0.06, cornerHeight: size * 0.06, transform: nil))
    ctx.setFillColor(mint)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.textPosition = CGPoint(x: x0, y: baseline)
    CTLineDraw(v, ctx)
    ctx.textPosition = CGPoint(x: x0 + advance, y: baseline)
    CTLineDraw(line("ie", textColor), ctx)

    // A line of code above and one below.
    func capsule(x: CGFloat, y: CGFloat, width: CGFloat, _ color: CGColor) {
        let h: CGFloat = 42
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y - h / 2, width: width, height: h),
                           cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    capsule(x: x0, y: 772, width: 120, keyword)
    capsule(x: x0 + 142, y: 772, width: 250, name)
    capsule(x: x0 + 60, y: 252, width: 190, comment)
    capsule(x: x0 + 272, y: 252, width: 170, string)
}

func png(pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, scale: CGFloat(pixels) / canvas)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("couldn't write \(url.path)") }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <output.icns>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Vie-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    png(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    png(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(output.path)")
