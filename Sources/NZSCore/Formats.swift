/// Atari-ST-format colour words: 3 bits per gun (0RGB, 0-7). The game converts
/// them with `add.w d0,d0` (palette routine $BEFE, launcher $7604A), giving
/// Amiga $0RGB values 0,2,..,E.  [verified: disassembly]
public struct STPalette: Sendable {
    public var amiga: [UInt16]
    public init(words: [UInt16]) { amiga = words.map { ($0 &* 2) & 0x0fff } }
    public init<C: Collection>(bytes: C, offset: Int, count: Int = 16) where C.Element == UInt8, C.Index == Int {
        self.init(words: (0..<count).map { bytes.be16(offset + $0 * 2) })
    }
    public static func rgb(_ amiga: UInt16) -> UInt32 {
        UInt32((amiga >> 8) & 15) * 17 << 16 | UInt32((amiga >> 4) & 15) * 17 << 8 | UInt32(amiga & 15) * 17
    }
    public var rgb: [UInt32] { amiga.map(STPalette.rgb) }
}

/// Decode ST interleaved 4-plane data: per 16-pixel group, 4 consecutive words
/// (plane 0..3).
public enum STPlanar {
    public static func decode(_ b: [UInt8], at offset: Int, groups: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: groups * 16)
        for g in 0..<groups {
            let o = offset + g * 8
            let p = (0..<4).map { b.be16(o + $0 * 2) }
            for x in 0..<16 {
                let bit = UInt16(0x8000) >> UInt16(x)
                var v: UInt8 = 0
                for k in 0..<4 where p[k] & bit != 0 { v |= 1 << UInt8(k) }
                out[g * 16 + x] = v
            }
        }
        return out
    }
}

/// Per-world graphics set ("trackA", RLE, loaded to $3CAA6).
/// Header: "01", 16 ST palette words at +2, parameters at +$22..+$7F
/// (meaning mostly UNKNOWN; +$3E looks like the tile count), tiles from +$80.
/// Tiles: 16x16, ST interleaved, 128 bytes each.  [format: inferred from data,
/// to be confirmed against the tile drawing code]
public struct GraphicsSet: Sendable {
    public let raw: [UInt8]
    public let palette: STPalette
    public static let tileBase = 0x80, tileBytes = 128

    public init(raw: [UInt8]) throws {
        guard raw.count > 0x80, raw[0] == 0x30, raw[1] == 0x31 else { throw NZSError.badData("graphics set header") }
        self.raw = raw
        palette = STPalette(bytes: raw, offset: 2)
    }

    public var headerTileCount: Int { Int(raw.be16(0x3e)) }
    public var tileCapacity: Int { (raw.count - GraphicsSet.tileBase) / GraphicsSet.tileBytes }

    /// 256 colour indices (0-15), row-major.
    public func tile(_ n: Int) -> [UInt8] {
        let o = GraphicsSet.tileBase + n * GraphicsSet.tileBytes
        guard n >= 0, o + GraphicsSet.tileBytes <= raw.count else { return [UInt8](repeating: 0, count: 256) }
        return STPlanar.decode(raw, at: o, groups: 16)
    }
}

/// Level map ("trackB", raw track loaded to $44AA6).
/// Header 128 bytes: "01", word width (+2), word height (+4); tile bytes from +$80,
/// `width` bytes per row, stored BOTTOM row first (the loader at $C5C0 starts at
/// row h-1 and walks backwards while filling the attribute grid top-down).
/// `tile(x, y)` uses screen orientation (y = 0 is the top).
/// [verified: disassembly of $C5C0 + rendered map matches the emulated original]
public struct LevelMap: Sendable {
    public let width: Int, height: Int
    public let tiles: [UInt8]
    public init(raw: ArraySlice<UInt8>) throws {
        let r = Array(raw)
        guard r[0] == 0x30, r[1] == 0x31 else { throw NZSError.badData("map header") }
        width = Int(r.be16(2)); height = Int(r.be16(4))
        guard width > 0, 0x80 + width * height <= r.count else { throw NZSError.badData("map size \(width)x\(height)") }
        tiles = Array(r[0x80 ..< 0x80 + width * height])
    }
    public func tile(_ x: Int, _ y: Int) -> UInt8 { tiles[(height - 1 - y) * width + x] }
}

/// One row of the level table at $5DBA (20 entries x 16 bytes).
/// [verified: disassembly of $413C..$416C and $C5C0]
public struct LevelEntry: Sendable {
    public let attributeTable: UInt32   // word per tile: 4 nibbles = 8x8 collision codes
    public let pointer2: UInt32         // purpose not yet known
    public let pointer3: UInt32         // purpose not yet known
    public let graphicsTrack: Int       // 5 tracks, RLE -> $3CAA6
    public let mapTrack: Int            // 1 track -> $44AA6
}

/// Bytes as they sit at an Amiga address (e.g. a block loaded to $3CAA6).
public struct MemoryBlock: Sendable {
    public let base: Int
    public let bytes: [UInt8]
    public init(base: Int, bytes: [UInt8]) { self.base = base; self.bytes = bytes }
    public func u16(_ addr: Int) -> UInt16 { bytes.be16(addr - base) }
    public func u32(_ addr: Int) -> UInt32 { bytes.be32(addr - base) }
    public func slice(from addr: Int) -> ArraySlice<UInt8> { bytes[(addr - base)...] }
}

public struct MainImage: Sendable {
    public static let base = 0x400
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) { self.bytes = bytes }
    public init(disk: DiskImage) throws { bytes = try GameDisk.mainImage(disk) }
    public func u16(_ addr: Int) -> UInt16 { bytes.be16(addr - MainImage.base) }
    public func u32(_ addr: Int) -> UInt32 { bytes.be32(addr - MainImage.base) }

    public static let levelTable = 0x5dba, levelCount = 20
    public var levels: [LevelEntry] {
        (0..<MainImage.levelCount).map { i in
            let a = MainImage.levelTable + i * 16
            return LevelEntry(attributeTable: u32(a), pointer2: u32(a + 4), pointer3: u32(a + 8),
                              graphicsTrack: Int(u16(a + 12)), mapTrack: Int(u16(a + 14)))
        }
    }
    /// Boss graphics tracks for world w (bytes at $418C, 0 = none). [verified: $4180..$41A4]
    public func bossTrack(world: Int) -> Int { Int(bytes[0x418c - MainImage.base + world]) }
}

public struct GameData: Sendable {
    public let disk: DiskImage
    public let image: MainImage
    public init(disk: DiskImage) throws { self.disk = disk; image = try MainImage(disk: disk) }

    public func graphicsSet(level: Int) throws -> GraphicsSet {
        try GraphicsSet(raw: EscapeRLE.unpack(disk.tracks(image.levels[level].graphicsTrack, count: 5)))
    }
    public func map(level: Int) throws -> LevelMap {
        try LevelMap(raw: disk.tracks(image.levels[level].mapTrack, count: 1))
    }
}

/// Bob (blitter object) bank in ST format, converted in place to Amiga planar at
/// run time by $4E92.  [verified: disassembly of $4E08/$4E92 + blit log]
/// Table: 16-byte entries {u32 offset from data base, s16 hotX, s16 hotY,
/// u16 widthPx, u16 heightPx, u32 0}; a zero offset after the first entry ends it.
/// Image: u16 wordsPerLine, u16 lines, then per line per 16-pixel group 5 words:
/// mask, plane0..plane3 (mask = OR of the planes in the shipped data).
public struct SpriteBank: Sendable {
    public struct Entry: Sendable {
        public let offset: Int, hotX: Int, hotY: Int, width: Int, height: Int
        public let words: Int, lines: Int
    }
    public let name: String
    public let dataBase: Int, tableBase: Int
    public let entries: [Entry]
    let mem: MemoryBlock

    /// Banks found so far. [verified: pointers stored at $B6C6 by $402E and $4CEE]
    public static let known: [(String, Int, Int)] = [
        ("main", 0x22aa6, 0x39aa6),       // gameplay sprites, set up at $402E
        ("intro", 0x3caa6, 0x4caa6),      // title Tiki + intro story pictures, $4CEE
    ]

    public init(image: MainImage, name: String, dataBase: Int, tableBase: Int) {
        self.init(memory: MemoryBlock(base: MainImage.base, bytes: image.bytes), name: name, dataBase: dataBase, tableBase: tableBase)
    }

    /// `count` limits the table (the caller at $4432 converts a fixed 5 entries).
    public init(memory: MemoryBlock, name: String, dataBase: Int, tableBase: Int, count: Int? = nil) {
        mem = memory; self.name = name; self.dataBase = dataBase; self.tableBase = tableBase
        var es = [Entry]()
        var a = tableBase
        while es.count < (count ?? 1000) {
            let off = Int(memory.u32(a))
            if count == nil && !es.isEmpty && off == 0 { break }
            let hdr = memory.u32(dataBase + off)
            es.append(Entry(offset: off, hotX: Int(Int16(bitPattern: memory.u16(a + 4))), hotY: Int(Int16(bitPattern: memory.u16(a + 6))),
                            width: Int(memory.u16(a + 8)), height: Int(memory.u16(a + 10)),
                            words: Int(hdr >> 16), lines: Int(hdr & 0xffff)))
            a += 16
        }
        entries = es
    }

    /// Pixels: 0..15 colour index, 0xFF = transparent (mask bit clear).
    public func pixels(_ i: Int) -> (width: Int, height: Int, data: [UInt8]) {
        let e = entries[i]
        let w = e.words * 16
        var out = [UInt8](repeating: 0xff, count: w * e.lines)
        var o = dataBase + e.offset + 4
        for y in 0..<e.lines {
            for g in 0..<e.words {
                let mask = mem.u16(o), p = (1...4).map { mem.u16(o + $0 * 2) }
                o += 10
                for x in 0..<16 {
                    let bit = UInt16(0x8000) >> UInt16(x)
                    guard mask & bit != 0 else { continue }
                    var v: UInt8 = 0
                    for k in 0..<4 where p[k] & bit != 0 { v |= 1 << UInt8(k) }
                    out[y * w + g * 16 + x] = v
                }
            }
        }
        return (w, e.lines, out)
    }
}

/// IFF 8SVX instruments embedded in the main image. The sound driver's init
/// ($F10E) parses FORM/CAT chunks for the music instruments; effects are the
/// remaining FORMs. Names come from the files' NAME chunks.  [verified: data]
public struct Sample8SVX: Sendable {
    public let address: Int
    public let name: String
    public let oneShot: Int, repeatLength: Int, rate: Int, volume: Int
    public let body: [Int8]

    public static func scan(_ image: MainImage) -> [Sample8SVX] {
        let b = image.bytes
        var out = [Sample8SVX]()
        var i = 0
        while i + 12 < b.count {
            guard b[i] == 0x46, b[i+1] == 0x4f, b[i+2] == 0x52, b[i+3] == 0x4d,
                  b[i+8] == 0x38, b[i+9] == 0x53, b[i+10] == 0x56, b[i+11] == 0x58 else { i += 2; continue }
            let len = Int(b.be32(i + 4))
            var j = i + 12
            var name = "", oneShot = 0, rep = 0, rate = 0, vol = 0, body = [Int8]()
            while j + 8 <= min(b.count, i + 8 + len) {
                let id = String(decoding: b[j..<j+4], as: UTF8.self)
                let cl = Int(b.be32(j + 4))
                switch id {
                case "VHDR": oneShot = Int(b.be32(j + 8)); rep = Int(b.be32(j + 12)); rate = Int(b.be16(j + 20)); vol = Int(b.be32(j + 24))
                case "NAME": name = String(decoding: b[j+8 ..< j+8+cl].prefix { $0 != 0 }, as: UTF8.self)
                case "BODY": body = b[j+8 ..< min(b.count, j+8+cl)].map { Int8(bitPattern: $0) }
                default: break
                }
                j += 8 + cl + (cl & 1)
            }
            out.append(Sample8SVX(address: i + MainImage.base, name: name, oneShot: oneShot, repeatLength: rep, rate: rate, volume: vol, body: body))
            i += 8 + len
        }
        return out
    }
}

/// Degas Elite .PC1 picture (ST low res, 320x200x16): word resolution, 16 ST
/// palette words, then PackBits per scan line per plane (40 bytes each).
/// Unpacked by the launcher ($766AC) and by the game ($507E) with identical code.
/// [verified: disassembly + rendered output]
public struct DegasPicture: Sendable {
    public static let width = 320, height = 200
    public let palette: STPalette
    public let pixels: [UInt8]     // colour indices, row-major

    /// A full PC1 file (header + palette + data).
    public init<C: Collection>(_ src: C) throws where C.Element == UInt8, C.Index == Int {
        let s = Array(src)
        try self.init(packed: s[0x22...], palette: STPalette(bytes: s, offset: 2))
    }

    /// Bare PackBits data with a palette from elsewhere (as $4DBE is called).
    public init(packed: ArraySlice<UInt8>, palette: STPalette) throws {
        let s = Array(packed)
        self.palette = palette
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: 40 * 200), count: 4)
        var i = 0, line = 0, plane = 0, pos = 0
        func put(_ b: UInt8) {
            guard line < 200 else { return }
            planes[plane][line * 40 + pos] = b; pos += 1
            if pos == 40 { pos = 0; plane += 1; if plane == 4 { plane = 0; line += 1 } }
        }
        while line < 200 {
            guard i < s.count else { throw NZSError.badData("PC1 truncated") }
            let c = s[i]; i += 1
            if c == 0x80 { continue }
            if c > 0x80 {
                let n = 257 - Int(c), v = s[i]; i += 1
                for _ in 0..<n { put(v) }
            } else {
                for k in 0...Int(c) { put(s[i + k]) }
                i += Int(c) + 1
            }
        }
        var px = [UInt8](repeating: 0, count: 320 * 200)
        for y in 0..<200 { for x in 0..<320 {
            let o = y * 40 + x >> 3, bit = UInt8(0x80) >> UInt8(x & 7)
            var v: UInt8 = 0
            for p in 0..<4 where planes[p][o] & bit != 0 { v |= 1 << UInt8(p) }
            px[y * 320 + x] = v
        } }
        pixels = px
    }

    public var rgb: [UInt32] { let pal = palette.rgb; return pixels.map { pal[Int($0)] } }
}

extension GameData {
    /// Pictures found so far. [verified: callers of $507E at $4D2E/$4412, launcher $7603A]
    /// Sprite bank in tracks 144..148: table at $3CAA6 (5 entries), data at $3CAF6 ($441C..$4434).
    public func track144Sprites() -> SpriteBank {
        SpriteBank(memory: MemoryBlock(base: 0x3caa6, bytes: Array(disk.tracks(0x90, count: 5))), name: "track144",
                   dataBase: 0x3caf6, tableBase: 0x3caa6, count: 5)
    }

    /// Boss bank for world w (2 tracks loaded to $6C000; table at +$2A00 terminated
    /// by a zero long, data base = load address).  [verified: $4192..$41E0]
    public func bossSprites(world: Int) -> SpriteBank? {
        let t = image.bossTrack(world: world)
        guard t != 0 else { return nil }
        return SpriteBank(memory: MemoryBlock(base: 0x6c000, bytes: Array(disk.tracks(t, count: 2))), name: "boss\(world)_track\(t)",
                          dataBase: 0x6c000, tableBase: 0x6c000 + 0x2a00)
    }

    public func pictures() throws -> [(String, DegasPicture)] {
        var out = [(String, DegasPicture)]()
        out.append(("loading", try DegasPicture(disk.tracks(GameDisk.pictureTrack, count: GameDisk.pictureTracks))))
        out.append(("zoo_intro", try DegasPicture(image.bytes[(0x4cca6 - MainImage.base)...])))
        // tracks 144..148 are loaded to $3CAA6 ($43F8); $4412 unpacks from $3FFFC and
        // $44E2 then sets the level palette $C1AA.
        let t144 = MemoryBlock(base: 0x3caa6, bytes: Array(disk.tracks(0x90, count: 5)))
        out.append(("track144", try DegasPicture(packed: t144.slice(from: 0x3fffc), palette: STPalette(bytes: image.bytes, offset: 0xc1aa - MainImage.base))))
        return out
    }
}

/// 8x8 1-bit font, characters $20..$7F, 8 bytes each, at $DA66 (address taken
/// from `lea (0x11da,PC)` in the print routine $C84C).  [verified: disassembly]
/// Strings (printer $C812): x column (8 px), y pixel row, then bytes:
/// 0 = new x,y follows; 1..5 = command + argument byte (2 = colour);
/// $20..$7E = character; bit 7 set = character & $7F, $FF = end.
/// [x/y units inferred from the emulated title screen]
public struct Font8x8: Sendable {
    public static let address = 0xda66
    public let glyphs: [[UInt8]]
    public init(image: MainImage) {
        glyphs = (0..<96).map { c in (0..<8).map { image.bytes[Font8x8.address - MainImage.base + c * 8 + $0] } }
    }
}
