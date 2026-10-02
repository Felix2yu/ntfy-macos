import AppKit
import CoreGraphics
import ImageIO

// Rasterizes the geometry in Resources/ntfy-icon.svg (same 1024 coordinate space)
// into the PNGs that `iconutil` packs into Resources/ntfy-macos.icns.
// Usage: swiftc -O tools/render-icon.swift -o /tmp/render-icon && /tmp/render-icon /tmp/ntfy.iconset && iconutil -c icns /tmp/ntfy.iconset -o Resources/ntfy-macos.icns

func renderIcon(size: Int, to url: URL) {
    let s = CGFloat(size) / 1024.0
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (1024 - y) * s) }
    let bg = CGPath(roundedRect: CGRect(x: 64*s, y: 64*s, width: 896*s, height: 896*s),
                    cornerWidth: 210*s, cornerHeight: 210*s, transform: nil)
    ctx.saveGState(); ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0x3B/255, green: 0x97/255, blue: 0x85/255, alpha: 1),
        CGColor(red: 0x50/255, green: 0xB7/255, blue: 0xA2/255, alpha: 1)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024*s), end: CGPoint(x: 1024*s, y: 0), options: [])
    ctx.restoreGState()
    ctx.setLineJoin(.miter); ctx.setLineCap(.butt)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    // bubble outline centered at x=512, tail as part of the stroke
    let bubble = CGMutablePath()
    bubble.move(to: P(277, 285)); bubble.addLine(to: P(747, 285))
    bubble.addQuadCurve(to: P(777, 315), control: P(777, 285))
    bubble.addLine(to: P(777, 665))
    bubble.addQuadCurve(to: P(747, 695), control: P(777, 695))
    bubble.addLine(to: P(340, 695)); bubble.addLine(to: P(247, 748))
    bubble.addLine(to: P(247, 315))
    bubble.addQuadCurve(to: P(277, 285), control: P(247, 285))
    bubble.closeSubpath()
    ctx.setLineWidth(52 * s); ctx.addPath(bubble); ctx.strokePath()
    // > and _ share one bottom edge (y=605.8): the chevron's lower-arm butt cap
    // reaches 585 + 0.8 * 26, so the underscore center sits at 605.8 - 26.
    let chev = CGMutablePath()
    chev.move(to: P(335, 405)); chev.addLine(to: P(455, 495)); chev.addLine(to: P(335, 585))
    ctx.setLineWidth(52 * s); ctx.addPath(chev); ctx.strokePath()
    let und = CGMutablePath()
    und.move(to: P(540, 579.8)); und.addLine(to: P(690, 579.8))
    ctx.addPath(und); ctx.strokePath()

    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    renderIcon(size: px, to: URL(fileURLWithPath: outDir + "/" + name))
}
print("done")
