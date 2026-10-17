/// Paula audio, DMA mode. Per channel: on DMA enable the location/length
/// registers are latched and an audio interrupt is requested; each time a block
/// finishes, the latches reload and the interrupt is requested again (HRM
/// behaviour). Samples advance every PERIOD colour clocks (3,546,895 Hz PAL).
/// Output: 44.1 kHz stereo (channels 0+3 left, 1+2 right), zero-order hold,
/// no low-pass/LED filter — so it sounds harsher than a real A500. Volume is
/// linear 0..64. AUDxDAT (non-DMA) playback only raises the interrupt (no sound); ADKCON
/// modulation is not modelled.
public final class Paula {
    public static let colourClock = 3_546_895
    public static let outputRate = 44_100

    struct Channel {
        var on = false
        var pt: UInt32 = 0, len = 0
        var counter = 0           // colour clocks until next sample
        var word: UInt16 = 0, half = 0
        var sample: Int8 = 0
        var started = false
    }
    var ch = [Channel](repeating: Channel(), count: 4)
    var outAcc = 0
    public var capture = false
    /// Live output (app): called for every 44.1 kHz stereo sample pair.
    public var sink: ((Int16, Int16) -> Void)?
    public var samplesL = [Int16](), samplesR = [Int16]()
    /// Log of register writes (frame, channel, reg offset, value) for driver analysis.
    public var log: [(Int, Int, Int, UInt16)] = []
    public var logging = false

    public init() {}

    func dmaChanged(_ m: Machine) {
        let dmacon = m.custom[0x96 >> 1]
        for i in 0..<4 {
            let on = dmacon & 0x200 != 0 && dmacon & (1 << UInt16(i)) != 0
            if on && !ch[i].on {
                ch[i].on = true
                latch(m, i)
                ch[i].counter = 0
                ch[i].half = 2
            } else if !on && ch[i].on {
                ch[i].on = false
                ch[i].sample = 0
            }
        }
    }

    func latch(_ m: Machine, _ i: Int) {
        let base = 0xa0 + i * 16
        ch[i].pt = m.ptr(base)
        var l = Int(m.custom[(base + 4) >> 1]); if l == 0 { l = 65536 }
        ch[i].len = l
        m.requestInterrupt(UInt16(0x80 << i))
    }

    func registerWritten(_ m: Machine, _ reg: Int) {
        let i = (reg - 0xa0) >> 4
        if logging { log.append((m.frame, i, reg & 15, m.custom[reg >> 1])) }
        // Non-DMA mode: writing AUDxDAT with the channel's DMA off makes Paula take
        // the word and request the channel interrupt (HRM "direct" playback). The
        // two samples themselves are not mixed into the output.
        if reg & 15 == 0xa && !ch[i].on { m.requestInterrupt(UInt16(0x80 << i)) }
    }

    var ccCarry = 0

    func advance(_ m: Machine, cycles: Int) {
        var cc = (cycles + ccCarry) / 2
        ccCarry = (cycles + ccCarry) % 2
        while cc > 0 {
            let need = (Paula.colourClock - outAcc + Paula.outputRate - 1) / Paula.outputRate
            let step = max(1, min(cc, need))
            stepChannels(m, step)
            cc -= step
            outAcc += step * Paula.outputRate
            if outAcc >= Paula.colourClock {
                outAcc -= Paula.colourClock
                if capture || sink != nil { emit(m) }
            }
        }
    }

    func stepChannels(_ m: Machine, _ cc: Int) {
        for i in 0..<4 where ch[i].on {
            var per = Int(m.custom[(0xa6 + i * 16) >> 1]); if per < 124 { per = 124 }
            var t = cc
            while t > 0 {
                if ch[i].counter > t { ch[i].counter -= t; break }
                t -= ch[i].counter
                ch[i].counter = per
                if ch[i].half >= 2 {
                    ch[i].word = m.chipRead16(ch[i].pt)
                    ch[i].pt &+= 2
                    ch[i].half = 0
                    ch[i].len -= 1
                    if ch[i].len == 0 { latch(m, i) }
                }
                ch[i].sample = Int8(bitPattern: ch[i].half == 0 ? UInt8(ch[i].word >> 8) : UInt8(ch[i].word & 0xff))
                ch[i].half += 1
            }
        }
    }

    func emit(_ m: Machine) {
        var l = 0, r = 0
        for i in 0..<4 where ch[i].on {
            var vol = Int(m.custom[(0xa8 + i * 16) >> 1] & 0x7f); if vol > 64 { vol = 64 }
            let s = Int(ch[i].sample) * vol
            if i == 0 || i == 3 { l += s } else { r += s }
        }
        let sl = Int16(clamping: l * 2), sr = Int16(clamping: r * 2)
        if capture { samplesL.append(sl); samplesR.append(sr) }
        sink?(sl, sr)
    }
}
