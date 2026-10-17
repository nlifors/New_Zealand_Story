/// MOS 8520 CIA. Timers run on the E clock (CPU clock / 10).
/// Modelled: ports, both timers (continuous/one-shot, force load, timer B
/// counting timer A underflows), TOD counter with alarm, SDR input, ICR.
/// Not modelled: serial output, TOD latching on read, PB6/PB7 timer outputs.
public final class CIA {
    public var pra: UInt8 = 0xff, prb: UInt8 = 0xff, ddra: UInt8 = 0, ddrb: UInt8 = 0
    public var portAIn: UInt8 = 0xff, portBIn: UInt8 = 0xff
    var ta: UInt16 = 0xffff, tb: UInt16 = 0xffff
    var taLatch: UInt16 = 0xffff, tbLatch: UInt16 = 0xffff
    var cra: UInt8 = 0, crb: UInt8 = 0
    var icrMask: UInt8 = 0
    public var icrData: UInt8 = 0
    var tod: UInt32 = 0, alarm: UInt32 = 0, todHalted = false
    var sdr: UInt8 = 0
    public var irqChanged: (() -> Void)?

    public var interruptPending: Bool { icrData & 0x80 != 0 }

    func raise(_ bit: UInt8) {
        icrData |= bit
        if icrMask & bit != 0 { icrData |= 0x80; irqChanged?() }
    }

    /// Advance timers by `ticks` E-clock cycles.
    public func tick(_ ticks: Int) {
        var underflowsA = 0
        if cra & 1 != 0 && cra & 0x20 == 0 {
            var t = Int(ta) - ticks
            while t < 0 {
                underflowsA += 1
                raise(0x01)
                if cra & 0x08 != 0 { cra &= ~1; t = Int(taLatch); break }
                t += Int(taLatch) + 1
            }
            ta = UInt16(clamping: t)
        }
        if crb & 1 != 0 {
            let mode = (crb >> 5) & 3
            let n = mode == 0 ? ticks : (mode == 2 ? underflowsA : 0)
            if n > 0 {
                var t = Int(tb) - n
                while t < 0 {
                    raise(0x02)
                    if crb & 0x08 != 0 { crb &= ~1; t = Int(tbLatch); break }
                    t += Int(tbLatch) + 1
                }
                tb = UInt16(clamping: t)
            }
        }
    }

    public func todPulse() {
        if todHalted { return }
        tod = (tod + 1) & 0xff_ffff
        if tod == alarm { raise(0x04) }
    }

    /// A byte arriving on the serial port (keyboard on CIA-A).
    public func serialIn(_ b: UInt8) {
        sdr = b
        raise(0x08)
    }

    public func read(_ reg: Int) -> UInt8 {
        switch reg & 15 {
        case 0: return (pra & ddra) | (portAIn & ~ddra)
        case 1: return (prb & ddrb) | (portBIn & ~ddrb)
        case 2: return ddra
        case 3: return ddrb
        case 4: return UInt8(ta & 0xff)
        case 5: return UInt8(ta >> 8)
        case 6: return UInt8(tb & 0xff)
        case 7: return UInt8(tb >> 8)
        case 8: return UInt8(tod & 0xff)
        case 9: return UInt8((tod >> 8) & 0xff)
        case 10: return UInt8((tod >> 16) & 0xff)
        case 12: return sdr
        case 13:
            let v = icrData
            icrData = 0
            irqChanged?()
            return v
        case 14: return cra & ~0x10
        case 15: return crb & ~0x10
        default: return 0xff
        }
    }

    public func write(_ reg: Int, _ v: UInt8) {
        switch reg & 15 {
        case 0: pra = v
        case 1: prb = v
        case 2: ddra = v
        case 3: ddrb = v
        case 4: taLatch = (taLatch & 0xff00) | UInt16(v)
        case 5:
            taLatch = (taLatch & 0x00ff) | UInt16(v) << 8
            if cra & 1 == 0 { ta = taLatch }
            if cra & 0x08 != 0 { ta = taLatch; cra |= 1 }      // one-shot starts on high-byte write
        case 6: tbLatch = (tbLatch & 0xff00) | UInt16(v)
        case 7:
            tbLatch = (tbLatch & 0x00ff) | UInt16(v) << 8
            if crb & 1 == 0 { tb = tbLatch }
            if crb & 0x08 != 0 { tb = tbLatch; crb |= 1 }
        case 8:
            if crb & 0x80 != 0 { alarm = (alarm & 0xffff00) | UInt32(v) } else { tod = (tod & 0xffff00) | UInt32(v); todHalted = false }
        case 9:
            if crb & 0x80 != 0 { alarm = (alarm & 0xff00ff) | UInt32(v) << 8 } else { tod = (tod & 0xff00ff) | UInt32(v) << 8; todHalted = true }
        case 10:
            if crb & 0x80 != 0 { alarm = (alarm & 0x00ffff) | UInt32(v) << 16 } else { tod = (tod & 0x00ffff) | UInt32(v) << 16; todHalted = true }
        case 12: sdr = v
        case 13:
            if v & 0x80 != 0 { icrMask |= v & 0x7f } else { icrMask &= ~v }
            if icrData & icrMask & 0x7f != 0 { icrData |= 0x80 } else { icrData &= 0x7f }
            irqChanged?()
        case 14:
            if v & 0x10 != 0 { ta = taLatch }
            cra = v & ~0x10
        case 15:
            if v & 0x10 != 0 { tb = tbLatch }
            crb = v & ~0x10
        default: break
        }
    }
}
