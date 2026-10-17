/// OCS display: bitplanes (lowres/hires, 1-6 planes, dual playfield, EHB; HAM is
/// not implemented), BPLCON1 scroll, display window, and DMA sprites with
/// attach and BPLCON2 priorities. Rendering is per line using the register state
/// at the end of that line (mid-line register changes are not modelled).
///
/// Canvas: lowres pixel columns from beam hpos $71 (352 wide) and lines $1C..$12C
/// (272 high). Playfield pixel at DIW hpos H lands in canvas column H - $71.
/// Sprite HSTART h is drawn at hpos h + 1 — standard hardware relationship, but
/// UNVERIFIED in this emulator against a real machine.
public final class Video {
    public static let width = 352, height = 272
    public static let x0 = 0x71, y0 = 0x1c
    public var pixels = [UInt32](repeating: 0, count: Video.width * Video.height)   // 0x00RRGGBB
    public private(set) var lastFrame = [UInt32](repeating: 0, count: Video.width * Video.height)
    /// Raw colour indices (0-63 playfield/sprite colour register numbers), for tests.
    public var indices = [UInt8](repeating: 0, count: Video.width * Video.height)
    public private(set) var lastIndices = [UInt8](repeating: 0, count: Video.width * Video.height)

    struct Sprite {
        var pos: UInt16 = 0, ctl: UInt16 = 0, dataA: UInt16 = 0, dataB: UInt16 = 0
        var armed = false
        var dmaState = 0        // 0 = need control words, 1 = waiting for vstart, 2 = displaying, 3 = done
        var vstart: Int { Int(pos >> 8) | Int(ctl & 4) << 6 }
        var vstop: Int { Int(ctl >> 8) | Int(ctl & 2) << 7 }
        var hstart: Int { Int(pos & 0xff) << 1 | Int(ctl & 1) }
        var attached: Bool { ctl & 0x80 != 0 }
    }
    var sprites = [Sprite](repeating: Sprite(), count: 8)
    var lineBuf = [UInt8](repeating: 0, count: 1024)     // playfield colour index per hpos (lowres)
    var pfMask = [UInt8](repeating: 0, count: 1024)      // bit0 = PF1 opaque, bit1 = PF2 opaque
    var sprBuf = [UInt8](repeating: 0, count: 1024)      // sprite colour index (0 = none)
    var sprPair = [UInt8](repeating: 0, count: 1024)

    func colourChanged(_ m: Machine) {}

    func spriteRegisterWritten(_ m: Machine, _ reg: Int) {
        let n = (reg - 0x140) >> 3
        switch reg & 7 {
        case 0: sprites[n].pos = m.custom[reg >> 1]
        case 2: sprites[n].ctl = m.custom[reg >> 1]; sprites[n].armed = false
        case 4: sprites[n].dataA = m.custom[reg >> 1]; sprites[n].armed = true
        default: sprites[n].dataB = m.custom[reg >> 1]
        }
    }

    @inline(__always) func rgb(_ c: UInt16) -> UInt32 {
        let r = UInt32((c >> 8) & 15) * 17, g = UInt32((c >> 4) & 15) * 17, b = UInt32(c & 15) * 17
        return r << 16 | g << 8 | b
    }

    func spriteDMA(_ m: Machine, _ line: Int) {
        guard m.dmacon & 0x0220 == 0x0220 else { return }
        for n in 0..<8 {
            var s = sprites[n]
            let ptrReg = 0x120 + n * 4
            var p = m.ptr(ptrReg)
            if line < 25 { if line == 0 { s.dmaState = 0 }; sprites[n] = s; continue }
            if s.dmaState == 0 {
                s.pos = m.chipRead16(p); s.ctl = m.chipRead16(p + 2); p &+= 4
                s.armed = false
                s.dmaState = (s.pos == 0 && s.ctl == 0) ? 3 : 1
            }
            if s.dmaState == 1 && line == s.vstart { s.dmaState = 2 }
            if s.dmaState == 2 {
                if line == s.vstop {
                    s.pos = m.chipRead16(p); s.ctl = m.chipRead16(p + 2); p &+= 4
                    s.armed = false
                    s.dmaState = (s.pos == 0 && s.ctl == 0) ? 3 : 1
                    if s.dmaState == 1 && line == s.vstart { s.dmaState = 2 }
                }
                if s.dmaState == 2 {
                    s.dataA = m.chipRead16(p); s.dataB = m.chipRead16(p + 2); p &+= 4
                    s.armed = true
                }
            }
            m.setPtr(ptrReg, p)
            sprites[n] = s
        }
    }

    func renderLine(_ m: Machine, _ line: Int) {
        let c = m.custom
        let bplcon0 = c[0x100 >> 1], bplcon1 = c[0x102 >> 1], bplcon2 = c[0x104 >> 1]
        let nplanes = min(6, Int(bplcon0 >> 12) & 7)
        let hires = bplcon0 & 0x8000 != 0
        let dpf = bplcon0 & 0x400 != 0
        let diwstrt = Int(c[0x8e >> 1]), diwstop = Int(c[0x90 >> 1])
        let vstart = diwstrt >> 8
        let vstop = (diwstop >> 8) | (diwstop & 0x8000 == 0 ? 0x100 : 0)
        let hstart = diwstrt & 0xff, hstop = (diwstop & 0xff) | 0x100
        let vActive = line >= vstart && line < vstop

        spriteDMA(m, line)

        let canvasLine = line - Video.y0
        let drawing = canvasLine >= 0 && canvasLine < Video.height

        for i in 0..<lineBuf.count { lineBuf[i] = 0; pfMask[i] = 0; sprBuf[i] = 0 }

        if vActive && m.dmacon & 0x0300 == 0x0300 && nplanes > 0 {
            let ddfstrt = Int(c[0x92 >> 1]) & 0xfc, ddfstop = Int(c[0x94 >> 1]) & 0xfc
            let words = hires ? ((ddfstop - ddfstrt) / 4 + 2) : ((ddfstop - ddfstrt) / 8 + 1)
            let x0 = 2 * ddfstrt + 0x11
            for p in 0..<nplanes {
                let reg = 0xe0 + p * 4
                var ptr = m.ptr(reg)
                var delay = p & 1 == 0 ? Int(bplcon1 & 15) : Int(bplcon1 >> 4 & 15)
                // Lowres: fetched words are loaded into the shifter where the beam
                // position (on a 16-pixel grid fixed to the standard $38 fetch)
                // matches the delay, not simply `delay` pixels after the fetch.
                // Same thing for aligned DDFSTRT; for an unaligned start like this
                // game's $34, delays 8-15 land 16 pixels earlier. Required for the
                // game's fine scroll ((7 - x) & 15 with 16-pixel columns) to be
                // smooth. Inferred from the game, not measured on hardware.
                if !hires { delay = (2 * 0x38 + 0x11 + delay - x0) & 15 }
                for w in 0..<max(0, words) {
                    let data = m.chipRead16(ptr); ptr &+= 2
                    if data == 0 || !drawing { continue }
                    for b in 0..<16 where data & (0x8000 >> UInt16(b)) != 0 {
                        // hires pixels are folded onto lowres columns (left pixel of each pair wins)
                        let px = hires ? (x0 + delay + (w * 16 + b) / 2) : (x0 + delay + w * 16 + b)
                        if px >= 0 && px < lineBuf.count { lineBuf[px] |= UInt8(1 << p) }
                    }
                }
                let mod = p & 1 == 0 ? m.sext(c[0x108 >> 1]) : m.sext(c[0x10a >> 1])
                m.setPtr(reg, ptr &+ mod)
            }
        }
        guard drawing else { return }

        // sprites
        do {
            for n in stride(from: 7, through: 0, by: -1) {
                let s = sprites[n]
                guard s.armed else { continue }
                if n & 1 == 1 && s.attached { continue }    // drawn with its even partner
                let x0 = s.hstart + 1
                let odd = n & 1 == 0 ? sprites[n + 1] : s
                let attach = n & 1 == 0 && odd.attached && odd.armed
                for b in 0..<16 {
                    let bit = UInt16(0x8000) >> UInt16(b)
                    var v = (s.dataA & bit != 0 ? 1 : 0) | (s.dataB & bit != 0 ? 2 : 0)
                    var col: Int
                    if attach {
                        v |= (odd.dataA & bit != 0 ? 4 : 0) | (odd.dataB & bit != 0 ? 8 : 0)
                        col = v == 0 ? 0 : 16 + v
                    } else {
                        col = v == 0 ? 0 : 16 + (n >> 1) * 4 + v
                    }
                    let px = x0 + b
                    if col != 0 && px >= 0 && px < sprBuf.count {
                        sprBuf[px] = UInt8(col); sprPair[px] = UInt8(n >> 1)
                    }
                }
            }
        }

        let pf1p = Int(bplcon2 & 7), pf2p = Int(bplcon2 >> 3 & 7)
        let pf2pri = bplcon2 & 0x40 != 0
        let ehb = nplanes == 6 && !dpf && bplcon0 & 0x800 == 0
        let base = canvasLine * Video.width
        for x in 0..<Video.width {
            let h = x + Video.x0
            var idx = 0
            if h >= hstart && h < hstop && vActive {
                let bits = Int(lineBuf[h])
                var pfIdx = 0, pfNum = 0      // pfNum: 0 none, 1 PF1, 2 PF2
                if dpf {
                    let p1 = (bits & 1) | (bits >> 1 & 2) | (bits >> 2 & 4)
                    let p2 = (bits >> 1 & 1) | (bits >> 2 & 2) | (bits >> 3 & 4)
                    if pf2pri {
                        if p2 != 0 { pfIdx = 8 + p2; pfNum = 2 } else if p1 != 0 { pfIdx = p1; pfNum = 1 }
                    } else {
                        if p1 != 0 { pfIdx = p1; pfNum = 1 } else if p2 != 0 { pfIdx = 8 + p2; pfNum = 2 }
                    }
                } else {
                    pfIdx = bits; pfNum = bits != 0 ? 1 : 0
                }
                idx = pfIdx
                let sc = Int(sprBuf[h])
                if sc != 0 {
                    let pair = Int(sprPair[h])
                    // sprite pair in front of a playfield if pair < PFxP
                    let inFront = pfNum == 0 || (pfNum == 1 ? pair < pf1p : pair < pf2p)
                    if inFront { idx = sc }
                }
            }
            indices[base + x] = UInt8(idx)
            let colour: UInt32
            if ehb && idx >= 32 {
                let v = c[(0x180 >> 1) + (idx - 32)]
                colour = rgb((v >> 1) & 0x777)
            } else {
                colour = rgb(c[(0x180 >> 1) + (idx & 31)])
            }
            pixels[base + x] = colour
        }
    }

    func endFrame(_ m: Machine) {
        lastFrame = pixels
        lastIndices = indices
    }
}
