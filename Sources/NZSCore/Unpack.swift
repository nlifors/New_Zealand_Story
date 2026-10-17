/// Escape-byte RLE used for the main image (launcher $7671E) and the per-world
/// graphics sets (game $564C — byte-identical routine).  [verified: disassembly]
/// Layout: long unpackedLen-1, long packedLen-1, then packed bytes: escape byte,
/// then literals; escape is followed by (value, count-1).
public enum EscapeRLE {
    public static func unpack<C: Collection>(_ src: C) throws -> [UInt8] where C.Element == UInt8, C.Index == Int {
        let s = Array(src)
        guard s.count >= 9 else { throw NZSError.badData("RLE header") }
        let outLen = Int(s.be32(0)) + 1
        let inLen = Int(s.be32(4)) + 1
        guard 8 + inLen <= s.count else { throw NZSError.badData("RLE packed length \(inLen)") }
        let esc = s[8]
        var i = 9
        let end = 8 + inLen
        var out = [UInt8]()
        out.reserveCapacity(outLen)
        while out.count < outLen {
            guard i < end else { throw NZSError.badData("RLE overrun") }
            let c = s[i]; i += 1
            if c != esc {
                out.append(c)
            } else {
                guard i + 1 < end else { throw NZSError.badData("RLE overrun") }
                let v = s[i], n = Int(s[i + 1]) + 1; i += 2
                // The 68k writes the whole run even past the end (dbf loop, length is only
                // tested afterwards); we clip, which only drops bytes beyond the output.
                out.append(contentsOf: repeatElement(v, count: min(n, outLen - out.count)))
            }
        }
        return out
    }
}
