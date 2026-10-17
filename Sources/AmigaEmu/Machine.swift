import M68K

/// A minimal PAL Amiga 500 (OCS, 512K chip RAM) built only to run New Zealand
/// Story's original code as a reference. Granularity is one scan line: the copper,
/// display, sprites, CIA timers and Paula are advanced at line boundaries.
///
/// Timing constants (verified hardware facts): CPU 7,093,790 Hz; a PAL line is
/// 227 colour clocks = 454 CPU cycles (long/short lines averaged away); 313 lines
/// per frame (interlace not modelled); E clock = CPU / 10.
/// Everything that depends on CPU cycle counts (how much work fits in a frame)
/// is an ESTIMATE: no DMA contention or wait states are modelled.
public final class Machine: M68KBus {
    public static let cpuClock = 7_093_790
    public static let cyclesPerLine = 454
    public static let linesPerFrame = 313

    public let chip: UnsafeMutablePointer<UInt8>
    public static let chipSize = 0x80000
    public var custom = [UInt16](repeating: 0, count: 256)
    public lazy var cpu = CPU(bus: self)
    public let ciaA = CIA(), ciaB = CIA()
    public let paula = Paula()
    public let video = Video()

    public var vpos = 0
    public var frame = 0
    var lineStartCycle = 0
    var eClockRemainder = 0
    var blitBusyUntil = 0
    var blitZero = true
    public var blitCount = 0
    public var blitLog: ((BlitRecord) -> Void)?
    /// Execution coverage: 1 byte per word address of chip RAM (bit0 executed,
    /// bit1 call target, bit2 jump target via JMP/indexed).
    public var coverage: [UInt8]?
    var copper = Copper()

    /// Set when the CPU jumps into ROM ($F80000) — the game's "reset" exit.
    public var resetRequested = false
    public var faults: [String] = []
    /// Joystick in port 2: up/down/left/right/fire.
    public var joyUp = false, joyDown = false, joyLeft = false, joyRight = false, joyFire = false
    public var mouseButton = false
    /// Amiga raw key events (keycode | $80 for key-up) waiting for the keyboard
    /// serial line. Delivered one per frame (the real keyboard waits for the
    /// handshake; one per 20 ms is an APPROXIMATION of that pacing).
    public var keyQueue: [UInt8] = []
    /// Logged writes (e.g. for tests): (frame, line, address, value)
    public var writeWatch: ((UInt32, UInt32, Int) -> Void)?

    public init() {
        chip = .allocate(capacity: Machine.chipSize)
        chip.initialize(repeating: 0, count: Machine.chipSize)
        ciaA.irqChanged = { [unowned self] in updateIPL() }
        ciaB.irqChanged = { [unowned self] in updateIPL() }
        ciaA.portAIn = 0xff
        cpu.addressErrors = true
    }
    deinit { chip.deallocate() }

    // MARK: chip RAM helpers
    @inline(__always) public func chipRead16(_ a: UInt32) -> UInt16 {
        let i = Int(a) & (Machine.chipSize - 2)
        return UInt16(chip[i]) << 8 | UInt16(chip[i + 1])
    }
    @inline(__always) public func chipWrite16(_ a: UInt32, _ v: UInt16) {
        let i = Int(a) & (Machine.chipSize - 2)
        chip[i] = UInt8(v >> 8); chip[i + 1] = UInt8(v & 0xff)
    }
    public func load(_ bytes: [UInt8], at addr: Int) {
        for (i, b) in bytes.enumerated() { chip[(addr + i) & (Machine.chipSize - 1)] = b }
    }
    public func readBytes(_ addr: Int, _ count: Int) -> [UInt8] {
        (0..<count).map { chip[(addr + $0) & (Machine.chipSize - 1)] }
    }

    // MARK: M68KBus
    public func read8(_ a: UInt32) -> UInt8 {
        switch a {
        case 0..<0x20_0000: return chip[Int(a) & (Machine.chipSize - 1)]
        case 0xbf_0000..<0xc0_0000:
            if a & 0x1001 == 0x0001 { return ciaARead(Int(a >> 8) & 15) }
            if a & 0x2001 == 0x0000 { return ciaB.read(Int(a >> 8) & 15) }
            return 0xff
        case 0xdf_f000..<0xe0_0000:
            let w = customRead(Int(a & 0x1fe))
            return a & 1 == 0 ? UInt8(w >> 8) : UInt8(w & 0xff)
        default:
            if a >= 0xf8_0000 { resetRequested = true }
            return 0
        }
    }

    public func read16(_ a: UInt32) -> UInt16 {
        switch a {
        case 0..<0x20_0000:
            let i = Int(a) & (Machine.chipSize - 1)
            return UInt16(chip[i]) << 8 | UInt16(chip[i + 1])
        case 0xdf_f000..<0xe0_0000: return customRead(Int(a & 0x1fe))
        case 0xbf_0000..<0xc0_0000: return UInt16(read8(a)) << 8 | UInt16(read8(a + 1))
        default:
            if a >= 0xf8_0000 { resetRequested = true }
            return 0
        }
    }

    public func write8(_ a: UInt32, _ v: UInt8) {
        switch a {
        case 0..<0x20_0000:
            chip[Int(a) & (Machine.chipSize - 1)] = v
            writeWatch?(a, UInt32(v), 1)
        case 0xbf_0000..<0xc0_0000:
            if a & 0x1001 == 0x0001 { ciaA.write(Int(a >> 8) & 15, v) }
            if a & 0x2001 == 0x0000 { ciaB.write(Int(a >> 8) & 15, v) }
        case 0xdf_f000..<0xe0_0000:
            // byte writes to custom registers put the byte on both halves
            customWrite(Int(a & 0x1fe), UInt16(v) << 8 | UInt16(v))
        default: break
        }
    }

    public func write16(_ a: UInt32, _ v: UInt16) {
        switch a {
        case 0..<0x20_0000:
            let i = Int(a) & (Machine.chipSize - 1)
            chip[i] = UInt8(v >> 8); chip[i + 1] = UInt8(v & 0xff)
            writeWatch?(a, UInt32(v), 2)
        case 0xdf_f000..<0xe0_0000: customWrite(Int(a & 0x1fe), v)
        case 0xbf_0000..<0xc0_0000: write8(a, UInt8(v >> 8)); write8(a + 1, UInt8(v & 0xff))
        default: break
        }
    }

    func ciaARead(_ reg: Int) -> UInt8 {
        if reg == 0 {
            // PA7 = /FIR1 (joystick port 2 fire), PA6 = /FIR0 (port 1 / left mouse button)
            // Floppy lines (disk access itself is HLE'd): PA5 /RDY low = ready,
            // PA4 /TK0 low = head on track 0, PA3 /WPRO low = write protected, PA2 /CHNG high = disk in.
            var v: UInt8 = 0xc7
            if joyFire { v &= ~0x80 }
            if mouseButton { v &= ~0x40 }
            ciaA.portAIn = v
        }
        return ciaA.read(reg)
    }

    // MARK: custom registers
    var dmacon: UInt16 { custom[0x96 >> 1] }
    var intena: UInt16 { custom[0x9a >> 1] }
    var intreq: UInt16 { custom[0x9c >> 1] }

    func customRead(_ reg: Int) -> UInt16 {
        switch reg {
        case 0x002:   // DMACONR
            var v = dmacon & 0x07ff
            if cpu.busTime < blitBusyUntil { v |= 0x4000 }
            if blitZero { v |= 0x2000 }
            return v
        case 0x004:   // VPOSR: LOF + V8, Agnus id 0 (OCS PAL)
            return UInt16((vpos >> 8) & 1) | 0x8000
        case 0x006:   // VHPOSR
            let h = min(0xe2, max(0, cpu.busTime - lineStartCycle) / 2)
            return UInt16((vpos & 0xff) << 8 | h)
        case 0x00a: return 0          // JOY0DAT (mouse not moved)
        case 0x00c: return joy1dat()
        case 0x010: return custom[0x9e >> 1]   // ADKCONR
        case 0x016: return 0xff00     // POTGOR: buttons released
        case 0x018: return 0          // SERDATR
        case 0x01a: return 0          // DSKBYTR
        case 0x01c: return intena
        case 0x01e: return intreq
        default: return 0xffff
        }
    }

    func joy1dat() -> UInt16 {
        // bit1 = right, bit9 = left, bit0 = down xor right, bit8 = up xor left (HRM)
        var r: UInt16 = 0
        if joyRight { r |= 0x0002 }
        if joyLeft { r |= 0x0200 }
        let b0: UInt16 = (joyDown != joyRight) ? 1 : 0
        let b8: UInt16 = (joyUp != joyLeft) ? 0x100 : 0
        return r | b0 | b8
    }

    func setClr(_ old: UInt16, _ v: UInt16) -> UInt16 {
        v & 0x8000 != 0 ? old | (v & 0x7fff) : old & ~v
    }

    public func customWrite(_ reg: Int, _ v: UInt16) {
        switch reg {
        case 0x058:
            custom[reg >> 1] = v
            startBlit()
            requestInterrupt(0x40)   // BLIT done (raised at start; the blit itself is instantaneous)
        case 0x088: copper.pc = ptr(0x80); copper.waiting = false; runCopper(final: false)
        case 0x08a: copper.pc = ptr(0x84); copper.waiting = false; runCopper(final: false)
        case 0x096: custom[reg >> 1] = setClr(dmacon, v) & 0x07ff; paula.dmaChanged(self)
        case 0x09a: custom[reg >> 1] = setClr(intena, v); updateIPL()
        case 0x09c: custom[reg >> 1] = setClr(intreq, v) & 0x7fff; updateIPL()
        case 0x09e: custom[reg >> 1] = setClr(custom[0x9e >> 1], v)
        case 0x0a0...0x0df:
            custom[reg >> 1] = v
            paula.registerWritten(self, reg)
        case 0x072:
            custom[reg >> 1] = v
        default:
            custom[reg >> 1] = v
            if reg >= 0x180 && reg < 0x1c0 { video.colourChanged(self) }
            if reg >= 0x140 && reg < 0x180 { video.spriteRegisterWritten(self, reg) }
        }
    }

    // MARK: interrupts
    public func updateIPL() {
        if ciaA.interruptPending { custom[0x9c >> 1] |= 0x0008 }
        if ciaB.interruptPending { custom[0x9c >> 1] |= 0x2000 }
        defer { if cpu.ipl > 0 { eventCycle = 0 } }
        let active = intena & intreq & 0x3fff
        var level = 0
        if intena & 0x4000 != 0 && active != 0 {
            if active & 0x2000 != 0 { level = 6 }
            else if active & 0x1800 != 0 { level = 5 }
            else if active & 0x0780 != 0 { level = 4 }
            else if active & 0x0070 != 0 { level = 3 }
            else if active & 0x0008 != 0 { level = 2 }
            else if active & 0x0007 != 0 { level = 1 }
        }
        cpu.ipl = level
    }

    public func requestInterrupt(_ bits: UInt16) {
        custom[0x9c >> 1] |= bits
        updateIPL()
    }

    // MARK: run loop
    /// Run until the end of the current frame (start of next vertical blank).
    public func runFrame() {
        repeat { runLine() } while vpos != 0 && !resetRequested
    }

    /// Interpreter mode: run one scan line of CPU + hardware.
    public func runLine() {
        beginLine()
        let end = lineEnd
        while cpu.cycles < end && !resetRequested {
            if coverage != nil { stepWithCoverage() } else { cpu.step() }
            if let f = cpu.lastFault { faults.append(f); cpu.lastFault = nil }
        }
        endLine()
    }

    /// Cycle at which the current line ends.
    public var lineEnd: Int { lineStartCycle + Machine.cyclesPerLine }
    /// For translated code: the cycle count at which `service` must run (line
    /// end, or 0 when an interrupt request may need taking).
    public var eventCycle: Int = Machine.cyclesPerLine
    public var frameEnded: (() -> Void)?

    /// Copper work that happens at the start of a line, before the CPU runs in it.
    public func beginLine() {
        runCopper(final: false)
    }

    /// Hardware work at the end of a line: copper, display, audio, CIAs, VBL.
    public func endLine() {
        runCopper(final: true)
        video.renderLine(self, vpos)
        paula.advance(self, cycles: Machine.cyclesPerLine)
        // CIA timers on the E clock
        let e = Machine.cyclesPerLine + eClockRemainder
        ciaA.tick(e / 10); ciaB.tick(e / 10); eClockRemainder = e % 10
        ciaB.todPulse()     // CIA-B TOD counts horizontal sync
        lineStartCycle += Machine.cyclesPerLine
        vpos += 1
        if vpos == Machine.linesPerFrame {
            vpos = 0
            frame += 1
            ciaA.todPulse() // CIA-A TOD counts vertical sync (50 Hz)
            video.endFrame(self)
            copper.pc = ptr(0x80); copper.waiting = false
            requestInterrupt(0x0020)   // VERTB
            if !keyQueue.isEmpty {
                let raw = keyQueue.removeFirst()
                // the keyboard sends bits 6..0 then 7, inverted: SDR = ~rol(raw, 1)
                ciaA.serialIn(~(raw << 1 | raw >> 7))
            }
            frameEnded?()
        }
        if eventCycle != 0 { eventCycle = lineEnd }
    }

    func stepWithCoverage() {
        let pc = cpu.pc
        let op = pc < 0x80000 ? read16(pc) : 0
        cpu.step()
        guard pc < 0x80000 else { return }
        coverage![Int(pc >> 1)] |= 1
        let npc = cpu.pc
        guard npc < 0x80000 else { return }
        // JSR (0100 1110 10xx xxxx), BSR (0110 0001 ...), JMP (0100 1110 11xx xxxx)
        if op & 0xffc0 == 0x4e80 || op & 0xff00 == 0x6100 { coverage![Int(npc >> 1)] |= 2 }
        else if op & 0xffc0 == 0x4ec0 { coverage![Int(npc >> 1)] |= 4 }
    }

    // MARK: copper (line granularity; WAIT horizontal positions are honoured
    // only as "before / after the visible part of the line")
    struct Copper {
        var pc: UInt32 = 0
        var waiting = false
        var waitV = 0, waitH = 0, waitMaskV = 0xff, waitMaskH = 0xfe
    }

    func runCopper(final: Bool) {
        guard dmacon & 0x0280 == 0x0280 else { return }
        // current beam position: start of line (h=0) or end of line (h=0xe2)
        let h = final ? 0xe2 : 0
        var guardCount = 0
        while guardCount < 1000 {
            guardCount += 1
            if copper.waiting {
                if !copperPositionReached(h) { return }
                copper.waiting = false
            }
            let w1 = chipRead16(copper.pc), w2 = chipRead16(copper.pc + 2)
            copper.pc &+= 4
            if w1 & 1 == 0 {
                let reg = Int(w1 & 0x1fe)
                // copper danger: registers below $40 need COPCON; below $20 never
                if reg < 0x40 && (reg < 0x20 || custom[0x2e >> 1] & 2 == 0) { copper.waiting = true; copper.waitV = 0x1ff; return }
                customWrite(reg, w2)
            } else {
                let v = Int(w1 >> 8), hh = Int(w1 & 0xfe)
                let mv = Int((w2 >> 8) & 0x7f) | 0x80, mh = Int(w2 & 0xfe)
                if w2 & 1 == 0 {
                    copper.waitV = v; copper.waitH = hh; copper.waitMaskV = mv; copper.waitMaskH = mh
                    if w1 == 0xffff && w2 == 0xfffe { copper.waiting = true; copper.waitV = 0x1ff; return }
                    copper.waiting = true
                } else {
                    // SKIP
                    copper.waitV = v; copper.waitH = hh; copper.waitMaskV = mv; copper.waitMaskH = mh
                    if copperPositionReached(h) { copper.pc &+= 4 }
                }
            }
        }
    }

    func copperPositionReached(_ h: Int) -> Bool {
        if copper.waitV == 0x1ff { return false }
        let cv = vpos & copper.waitMaskV, wv = copper.waitV & copper.waitMaskV
        // vertical compare uses only 8 bits; lines >= 256 compare as line & 0xff
        // unless the copper list waits for $FF first (standard PAL trick).
        if cv > wv { return true }
        if cv < wv { return false }
        return (h & copper.waitMaskH) >= (copper.waitH & copper.waitMaskH)
    }
}
