// make-icon.swift <out.icns>
// Draws the app icon: an ORIGINAL 32x32 pixel-art kiwi (not taken from the
// game, so no game data ends up in the bundle), scaled up without smoothing
// into the standard macOS rounded-square shape, and packs it with iconutil.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let kiwi = [
    "......oooooooo................",
    "....oobbbbbbbboo..............",
    "...obbbllllbbbbbo...oooo......",
    "..obbllllbbbbbbbbo.obbbbo.....",
    ".obbllbbbbbbbbbbbboobbbbbo....",
    ".obbbbbbbbbbbbbbbbbbbbwebo....",
    "obbbbbbbbbbbbbbbbbbbbbbbbkk...",
    "obbdbbbbbbbbdbbbbbbbbbbbo.kk..",
    "obbbbbbdbbbbbbbbbbbbbbbo...kk.",
    "obbbbbbbbbbbbbbdbbbbbbo.....k.",
    ".obbdbbbbbbbbbbbbbbbbo........",
    ".obbbbbbbdbbbbbbbbbbo.........",
    "..obbbbbbbbbbbbbbboo..........",
    "...oobbbbbbbbbbboo............",
    ".....oooooooooo...............",
    ".......f....f.................",
    ".......f....f.................",
    ".....fff..fff.................",
]

typealias RGB = (UInt8, UInt8, UInt8)
let colours: [Character: RGB] = [
    "o": (0x3a, 0x22, 0x10), "b": (0x8a, 0x5a, 0x2c), "l": (0xb8, 0x84, 0x48),
    "d": (0x6a, 0x42, 0x1e), "e": (0x10, 0x10, 0x10), "w": (0xff, 0xff, 0xff),
    "k": (0xe8, 0xc8, 0x88), "f": (0xd8, 0x90, 0x30),
]

// 32x32 picture: sky bands, a cloud, grass, then the kiwi standing on the grass
var px = [RGB](repeating: (0, 0, 0), count: 32 * 32)
for y in 0..<32 {
    for x in 0..<32 {
        let sky: RGB = y < 6 ? (0x22, 0x66, 0xcc) : y < 12 ? (0x33, 0x88, 0xdd) : y < 18 ? (0x44, 0xaa, 0xee) : (0x77, 0xcc, 0xff)
        px[y * 32 + x] = sky
        if y >= 25 { px[y * 32 + x] = y == 25 ? (0x55, 0xcc, 0x33) : (y + x) % 5 == 0 ? (0x22, 0x88, 0x22) : (0x33, 0xaa, 0x22) }
    }
}
for (y, row) in ["..wwww....", ".wwwwwww..", "wwwwwwwwww"].enumerated() {
    for (x, c) in row.enumerated() where c == "w" { px[(3 + y) * 32 + 19 + x] = (0xff, 0xff, 0xff) }
}
for (y, row) in kiwi.enumerated() {
    for (x, c) in row.enumerated() { if let col = colours[c] { px[(7 + y) * 32 + 1 + x] = col } }
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func pixelImage() -> CGImage {
    var bytes = [UInt8](); bytes.reserveCapacity(32 * 32 * 4)
    for p in px { bytes += [p.0, p.1, p.2, 255] }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128, space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// One icon size: the rounded square fills 824/1024 of the canvas (Apple's grid).
func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.clip()
    ctx.interpolationQuality = .none
    ctx.draw(pixelImage(), in: rect)
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let dest = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(base * scale), nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("writing \(name) failed") }
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
