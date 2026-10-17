/// Locations on the disk and the boot chain, all traced from the code
/// (see docs/disk-layout.md).  [verified: disassembly + clean unpack]
public enum GameDisk {
    /// Bit-stream-packed file loaded raw to $30000 by the game's bootblock
    /// (ADF 0x400..0x1800). Decrunched by `BitDecruncher` to $5E900.
    public static let loaderFileOffset = 0x400, loaderFileLength = 0x1400
    public static let loaderBase: UInt32 = 0x30000
    /// Launcher: bytes $5EA04.. of the decrunched file, copied to $76000 ($2E3+1 longs).
    public static let launcherBase = 0x76000
    public static let launcherSourceOffset = 0x104, launcherLength = 0x2e4 * 4
    public static let pictureTrack = 0x5b, pictureTracks = 3
    public static let mainTrack = 0x5e, mainTracks = 0x32
    public static let mainBase = 0x400

    /// The launcher+intro file, decrunched (loads at $5E900).
    public static func launcherFile(_ disk: DiskImage) throws -> [UInt8] {
        let file = Array(disk.bytes[loaderFileOffset ..< loaderFileOffset + loaderFileLength])
        return try BitDecruncher.decrunch(file: file, fileBase: loaderBase)
    }

    public static func launcher(_ disk: DiskImage) throws -> [UInt8] {
        let f = try launcherFile(disk)
        return Array(f[launcherSourceOffset ..< launcherSourceOffset + launcherLength])
    }

    /// Main image as the launcher leaves it at $400 (before the kernel's own
    /// 4-byte self-relocation).
    public static func mainImage(_ disk: DiskImage) throws -> [UInt8] {
        try EscapeRLE.unpack(disk.tracks(mainTrack, count: mainTracks))
    }
}

/// Backward bit-stream decruncher at $30024 (ported from work/disasm/loader_30000.lst).
public enum BitDecruncher {
    public static func decrunch(file: [UInt8], fileBase: UInt32) throws -> [UInt8] {
        // a3 = $30158 table: +4 destination, +8 packed length; packed data at +$C
        let table = 0x158
        let dest = Int(file.be32(table + 4))
        let srcLen = Int(file.be32(table + 8))
        var a0 = table + 0xc + srcLen
        func rdl() -> UInt32 { a0 -= 4; return file.be32(a0) }
        let outLen = Int(rdl())
        var out = [UInt8](repeating: 0, count: outLen)
        var d0 = rdl()
        func bit() -> UInt32 {
            var c = d0 & 1; d0 >>= 1
            if d0 == 0 { let v = rdl(); c = v & 1; d0 = (v >> 1) | 0x8000_0000 }
            return c
        }
        func get(_ n: Int) -> Int { var v = 0; for _ in 0..<n { v = v << 1 | Int(bit()) }; return v }
        var a2 = outLen
        while true {
            var n = get(3)
            if n != 0 {
                if n == 7 {
                    if bit() == 0 { n = get(4) + 7 } else { n = get(10); if n == 0 { n = get(18) } }
                }
                for _ in 0..<n { a2 -= 1; guard a2 >= 0 else { throw NZSError.badData("decrunch overrun") }; out[a2] = UInt8(get(8)) }
            }
            if a2 <= 0 { break }
            let k = get(2)
            var len: Int, bits: Int
            switch k {
            case 0: len = 2; bits = 8
            case 1: len = 3; bits = bit() != 0 ? 8 : 14
            default:
                if k == 2 { len = 4 } else {
                    let x = get(2)
                    len = x == 3 ? get(8) : (x == 2 ? get(2) + 7 : x + 5)
                }
                bits = bit() == 0 ? 16 : (bit() != 0 ? 8 : 12)
            }
            let off = get(bits)
            for _ in 0..<len {
                a2 -= 1
                guard a2 >= 0, a2 + off < outLen else { throw NZSError.badData("decrunch overrun") }
                out[a2] = out[a2 + off]
            }
        }
        guard a0 == table + 0xc else { throw NZSError.badData("decrunch did not consume input exactly") }
        _ = dest
        return out
    }
}
