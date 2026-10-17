/// Blitter. Each blit is performed in full the moment BLTSIZE is written; the
/// busy flag stays set for an estimated duration so CPU polling loops see a
/// plausible delay. Area mode (shifts, masks, minterms, descending, fill) follows
/// the Hardware Reference Manual. Line mode follows the HRM / UAE algorithm and
/// is UNVERIFIED for this game.
public struct BlitRecord: Sendable {
    public let frame: Int
    public let pc: UInt32
    public let con0, con1: UInt16
    public let width, height: Int
    public let a, b, c, d: UInt32
    public let amod, bmod, cmod, dmod, fwm, lwm: UInt16
}

extension Machine {
    func startBlit() {
        let con0 = Int(custom[0x40 >> 1]), con1 = Int(custom[0x42 >> 1])
        let size = Int(custom[0x58 >> 1])
        var h = size >> 6; if h == 0 { h = 1024 }
        var w = size & 63; if w == 0 { w = 64 }
        blitCount += 1
        if let log = blitLog {
            log(BlitRecord(frame: frame, pc: cpu.lastOpPC, con0: UInt16(con0), con1: UInt16(con1), width: w, height: h,
                           a: ptr(0x50), b: ptr(0x4c), c: ptr(0x48), d: ptr(0x54),
                           amod: custom[0x64 >> 1], bmod: custom[0x62 >> 1], cmod: custom[0x60 >> 1], dmod: custom[0x66 >> 1],
                           fwm: custom[0x44 >> 1], lwm: custom[0x46 >> 1]))
        }
        if con1 & 1 != 0 { blitLine(con0, con1, h) } else { blitArea(con0, con1, w, h) }
        let channels = (con0 >> 8 & 1) + (con0 >> 9 & 1) + (con0 >> 10 & 1) + (con0 >> 11 & 1)
        let words = con1 & 1 != 0 ? h : w * h
        let duration = 8 + words * max(2, channels) * 2   // estimate (HRM cycle counts, no DMA contention)
        // The CPU runs from chip RAM, so it is held off the bus while the blitter
        // works: fully in "blitter nasty" mode (DMACON BLTPRI), otherwise roughly
        // every other cycle. ESTIMATE.
        let stall = dmacon & 0x0400 != 0 ? duration : duration / 2
        blitBusyUntil = cpu.busTime + stall
        cpu.cycles += stall
    }

    @inline(__always) func minterm(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ lf: Int) -> UInt32 {
        var d: UInt32 = 0
        if lf & 0x80 != 0 { d |= a & b & c }
        if lf & 0x40 != 0 { d |= a & b & ~c }
        if lf & 0x20 != 0 { d |= a & ~b & c }
        if lf & 0x10 != 0 { d |= a & ~b & ~c }
        if lf & 0x08 != 0 { d |= ~a & b & c }
        if lf & 0x04 != 0 { d |= ~a & b & ~c }
        if lf & 0x02 != 0 { d |= ~a & ~b & c }
        if lf & 0x01 != 0 { d |= ~a & ~b & ~c }
        return d & 0xffff
    }

    func blitArea(_ con0: Int, _ con1: Int, _ w: Int, _ h: Int) {
        let useA = con0 & 0x800 != 0, useB = con0 & 0x400 != 0, useC = con0 & 0x200 != 0, useD = con0 & 0x100 != 0
        let ash = UInt32(con0 >> 12), bsh = UInt32(con1 >> 12)
        let desc = con1 & 2 != 0
        let fillOn = desc && con1 & 0x18 != 0
        let efe = con1 & 0x10 != 0
        let fci: UInt32 = con1 & 4 != 0 ? 1 : 0
        let lf = con0 & 0xff
        let fwm = UInt32(custom[0x44 >> 1]), lwm = UInt32(custom[0x46 >> 1])
        var apt = ptr(0x50), bpt = ptr(0x4c), cpt = ptr(0x48), dpt = ptr(0x54)
        let amod = sext(custom[0x64 >> 1]), bmod = sext(custom[0x62 >> 1])
        let cmod = sext(custom[0x60 >> 1]), dmod = sext(custom[0x66 >> 1])
        var adat = UInt32(custom[0x74 >> 1]), bdat = UInt32(custom[0x72 >> 1]), cdat = UInt32(custom[0x70 >> 1])
        var aold: UInt32 = 0, bold: UInt32 = 0
        let step: UInt32 = desc ? 0xffff_fffe : 2
        var zero = true
        for _ in 0..<h {
            var fc = fci
            for x in 0..<w {
                if useA { adat = UInt32(chipRead16(apt)); apt = apt &+ step }
                if useB { bdat = UInt32(chipRead16(bpt)); bpt = bpt &+ step }
                if useC { cdat = UInt32(chipRead16(cpt)); cpt = cpt &+ step }
                var am = adat
                if x == 0 { am &= fwm }
                if x == w - 1 { am &= lwm }
                let ash16: UInt32, bsh16: UInt32
                if !desc {
                    ash16 = ((aold << 16 | am) >> ash) & 0xffff
                    bsh16 = ((bold << 16 | bdat) >> bsh) & 0xffff
                } else {
                    ash16 = ((am << 16 | aold) >> (16 - ash)) & 0xffff
                    bsh16 = ((bdat << 16 | bold) >> (16 - bsh)) & 0xffff
                }
                aold = am; bold = bdat
                var d = minterm(ash16, bsh16, cdat, lf)
                if fillOn {
                    var out: UInt32 = 0
                    for bit in 0..<16 {
                        let inb = (d >> UInt32(bit)) & 1
                        if efe { fc ^= inb; out |= fc << UInt32(bit) }
                        else { out |= (fc | inb) << UInt32(bit); fc ^= inb }
                    }
                    d = out
                }
                if d != 0 { zero = false }
                if useD { chipWrite16(dpt, UInt16(d)); dpt = dpt &+ step }
            }
            if useA { apt = desc ? apt &- amod : apt &+ amod }
            if useB { bpt = desc ? bpt &- bmod : bpt &+ bmod }
            if useC { cpt = desc ? cpt &- cmod : cpt &+ cmod }
            if useD { dpt = desc ? dpt &- dmod : dpt &+ dmod }
        }
        setPtr(0x50, apt); setPtr(0x4c, bpt); setPtr(0x48, cpt); setPtr(0x54, dpt)
        custom[0x74 >> 1] = UInt16(adat & 0xffff); custom[0x72 >> 1] = UInt16(bdat & 0xffff)
        custom[0x70 >> 1] = UInt16(cdat & 0xffff)
        blitZero = zero
    }

    func blitLine(_ con0: Int, _ con1: Int, _ h: Int) {
        var shift = con0 >> 12
        let lf = con0 & 0xff
        var cpt = ptr(0x48)
        var err = Int32(Int16(truncatingIfNeeded: ptr(0x50) & 0xffff))
        let amod = Int32(Int16(bitPattern: custom[0x64 >> 1])), bmod = Int32(Int16(bitPattern: custom[0x62 >> 1]))
        let cmod = sext(custom[0x60 >> 1])
        let texture = UInt32(custom[0x72 >> 1])
        var tshift = UInt32(con1 >> 12)
        let adat = UInt32(custom[0x74 >> 1]) & UInt32(custom[0x44 >> 1])
        let sing = con1 & 2 != 0
        var sign = con1 & 0x40 != 0
        var oneDot = false
        var zero = true
        for _ in 0..<h {
            let c = UInt32(chipRead16(cpt))
            var a = (adat >> UInt32(shift)) & 0xffff
            if sing && oneDot { a = 0 }
            oneDot = true
            let b: UInt32 = (texture >> tshift) & 1 != 0 ? 0xffff : 0
            let d = minterm(a, b, c, lf)
            if d != 0 { zero = false }
            chipWrite16(cpt, UInt16(d))
            tshift = (tshift &- 1) & 15
            func incx() { shift += 1; if shift == 16 { shift = 0; cpt &+= 2 } }
            func decx() { shift -= 1; if shift < 0 { shift = 15; cpt &-= 2 } }
            func incy() { cpt &+= cmod; oneDot = false }
            func decy() { cpt &-= cmod; oneDot = false }
            if !sign {
                if con1 & 0x10 != 0 { if con1 & 8 != 0 { decy() } else { incy() } }
                else { if con1 & 8 != 0 { decx() } else { incx() } }
            }
            if con1 & 0x10 != 0 { if con1 & 4 != 0 { decx() } else { incx() } }
            else { if con1 & 4 != 0 { decy() } else { incy() } }
            err += sign ? bmod : amod
            sign = Int16(truncatingIfNeeded: err) < 0
        }
        setPtr(0x48, cpt); setPtr(0x54, cpt)
        setPtr(0x50, UInt32(bitPattern: err) & 0xffff)
        blitZero = zero
    }

    @inline(__always) func sext(_ v: UInt16) -> UInt32 { UInt32(bitPattern: Int32(Int16(bitPattern: v))) & 0xffff_fffe }
    @inline(__always) func ptr(_ reg: Int) -> UInt32 {
        (UInt32(custom[reg >> 1]) << 16 | UInt32(custom[(reg >> 1) + 1])) & 0x1f_fffe
    }
    @inline(__always) func setPtr(_ reg: Int, _ v: UInt32) {
        custom[reg >> 1] = UInt16((v >> 16) & 0x1f); custom[(reg >> 1) + 1] = UInt16(v & 0xfffe)
    }
}
