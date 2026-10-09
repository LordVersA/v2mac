// Usage: swift Scripts/make-icon.swift docs/images/app-icon-source.jpg App/Resources/Assets.xcassets/AppIcon.appiconset [--probe]
// Crops the generated icon tile out of its dark surround, masks it with a
// squircle, places it on the standard 1024 macOS canvas and writes every size.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: make-icon <source> <outdir> [--probe]"); exit(1) }
let probe = args.contains("--probe")

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read source"); exit(1) }
let W = image.width, H = image.height

// RGBA pixels
var pixels = [UInt8](repeating: 0, count: W * H * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &pixels, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))

func lum(_ x: Int, _ y: Int) -> Double {
    let i = (y * W + x) * 4
    return 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
}

// Background reads ~8-12 luminance; the tile rim and body are well above that.
let threshold = 22.0
let cx = W / 2, cy = H / 2
func scan(dx: Int, dy: Int) -> Int {
    var d = 0
    var x = cx, y = cy
    var last = 0
    while x >= 0, x < W, y >= 0, y < H {
        if lum(x, y) > threshold { last = d }
        x += dx; y += dy; d += 1
    }
    return last
}
let left = scan(dx: -1, dy: 0), right = scan(dx: 1, dy: 0)
let up = scan(dx: 0, dy: -1), down = scan(dx: 0, dy: 1)
let detected = (minX: cx - left, maxX: cx + right, minY: cy - up, maxY: cy + down)
// The scan overshoots by a few pixels of soft glow, so the rim positions below were
// measured from luminance profiles of the chosen source image (2048 px square).
let tile = (minX: 288, maxX: 1756, minY: 288, maxY: 1750)
let tileW = Double(tile.maxX - tile.minX), tileH = Double(tile.maxY - tile.minY)
let midX = Double(tile.minX + tile.maxX) / 2, midY = Double(tile.minY + tile.maxY) / 2

// Fit the squircle exponent from the 45-degree point of the outline.
var dd = 0
var diag = 0
while true {
    let x = Int(midX) + dd, y = Int(midY) + dd
    if x >= W || y >= H { break }
    if lum(x, y) > threshold { diag = dd }
    dd += 1
}
let a = tileW / 2
let ratio = Double(diag) / a                     // = 2^(-1/n)
let n = ratio > 0 && ratio < 1 ? -log(2.0) / log(ratio) : 5.0
if probe {
    print("image \(W)x\(H)  scanned x \(detected.minX)-\(detected.maxX) y \(detected.minY)-\(detected.maxY)  used x \(tile.minX)-\(tile.maxX) y \(tile.minY)-\(tile.maxY)")
    print("diagonal \(diag)  fitted exponent n = \(n)")
    exit(0)
}

// --- Render master 1024 canvas ---
let canvas = 1024
let tileOut = 824.0
let margin = (Double(canvas) - tileOut) / 2
let exponent = 4.8   // fitted from the source outline (probe reports ~4.7)

func squirclePath(in rect: CGRect, n: Double) -> CGPath {
    let p = CGMutablePath()
    let steps = 720
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        let pt = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func render(size: Int) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let k = Double(size) / Double(canvas)
    c.scaleBy(x: k, y: k)

    let tileRect = CGRect(x: margin, y: margin, width: tileOut, height: tileOut)
    // Mask sits one source-pixel inside the detected edge so no dark fringe survives.
    let inset = 0.5 * (tileOut / tileW)
    let maskRect = tileRect.insetBy(dx: inset, dy: inset)

    // Soft contact shadow (standard macOS icon treatment).
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: CGColor(gray: 0, alpha: 0.35))
    c.addPath(squirclePath(in: maskRect, n: exponent))
    c.setFillColor(CGColor(gray: 0.04, alpha: 1))
    c.fillPath()
    c.restoreGState()

    // Source tile, scaled so its detected bounds land exactly on tileRect.
    c.saveGState()
    c.addPath(squirclePath(in: maskRect, n: exponent))
    c.clip()
    let scale = tileOut / tileW
    let drawW = Double(W) * scale, drawH = Double(H) * scale
    // CG origin is bottom-left; source midY is measured from the top.
    let originX = tileRect.midX - midX * scale
    let originY = tileRect.midY - (Double(H) - midY) * scale
    c.draw(image, in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
    c.restoreGState()
    return c.makeImage()!
}

func write(_ img: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(point: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var entries: [String] = []
for s in sizes {
    let px = s.point * s.scale
    let name = "icon_\(s.point)x\(s.point)@\(s.scale)x.png"
    write(render(size: px), to: outDir.appendingPathComponent(name))
    entries.append("""
        { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(s.scale)x", "size" : "\(s.point)x\(s.point)" }
    """)
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try contents.write(to: outDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(sizes.count) icons to \(outDir.path)")
