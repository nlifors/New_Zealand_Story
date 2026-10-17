import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

public enum ImageFile {
    /// Write 0x00RRGGBB pixels as an RGB PNG, optionally scaled up by an integer factor.
    public static func writePNG(_ path: String, width: Int, height: Int, pixels: [UInt32], scale: Int = 1) throws {
        let w = width * scale, h = height * scale
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixels[(y / scale) * width + x / scale]
                let o = (y * w + x) * 4
                data[o] = UInt8(p >> 16 & 0xff); data[o + 1] = UInt8(p >> 8 & 0xff); data[o + 2] = UInt8(p & 0xff)
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NZSError.badData("cannot create PNG \(path)") }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw NZSError.badData("cannot write PNG \(path)") }
    }
}

public enum WAVFile {
    public static func write(_ path: String, rate: Int, left: [Int16], right: [Int16]) throws {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let n = min(left.count, right.count)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 4)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 4)
        var pcm = [Int16](); pcm.reserveCapacity(n * 2)
        for i in 0..<n { pcm.append(left[i].littleEndian); pcm.append(right[i].littleEndian) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: URL(fileURLWithPath: path))
    }
}
