import Foundation
// A plain MC68000 interpreter used as the reference ("emulated original") for tests
// and for reverse engineering. It is not used by the game port itself.
//
// Accuracy: instruction semantics aim to be exact (checked against the
// SingleStepTests/m68000 suite). Cycle counts are the documented base timings
// plus effective-address times; prefetch, bus-wait states and DMA contention are
// NOT modelled, so all timing derived from this core is an estimate.

public protocol M68KBus: AnyObject {
    func read8(_ addr: UInt32) -> UInt8
    func read16(_ addr: UInt32) -> UInt16
    func write8(_ addr: UInt32, _ value: UInt8)
    func write16(_ addr: UInt32, _ value: UInt16)
}

public enum Size: Int, Sendable {
    case byte = 1, word = 2, long = 4
    @inline(__always) public var mask: UInt32 { self == .byte ? 0xff : self == .word ? 0xffff : 0xffff_ffff }
    @inline(__always) public var msb: UInt32 { self == .byte ? 0x80 : self == .word ? 0x8000 : 0x8000_0000 }
}

public struct CPUFault: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public final class CPU {
    public var d = [UInt32](repeating: 0, count: 8)
    public var a = [UInt32](repeating: 0, count: 8)   // a[7] is the active stack pointer
    public var pc: UInt32 = 0
    public var sr: UInt16 = 0x2700
    public var usp: UInt32 = 0
    public var ssp: UInt32 = 0          // inactive copy while in user mode
    public var cycles: Int = 0          // running total (estimate)
    /// Cycle count at the start of the current instruction. Hardware that
    /// depends on time (beam position, blitter busy) uses this, so the
    /// interpreter and translated code (which adds cycles after the
    /// instruction's effects) observe identical values. APPROXIMATION: real
    /// bus accesses happen part-way through an instruction.
    public var instructionStart: Int = 0
    /// Translated code sets this: `cycles` itself is the instruction start.
    public var translatedMode = false
    @inline(__always) public var busTime: Int { translatedMode ? cycles : instructionStart }
    public var stopped = false
    public var ipl: Int = 0             // interrupt priority level requested by hardware
    public var addressErrors = true     // raise exception 3 on odd word/long access
    public var lastOpPC: UInt32 = 0
    /// Description of the last address error / illegal instruction, for diagnostics.
    public var lastFault: String?
    /// Called before each instruction; return true to skip executing it (HLE hooks).
    public var hook: ((CPU) -> Bool)?

    public unowned let bus: M68KBus

    public init(bus: M68KBus) { self.bus = bus }

    // MARK: flags
    public static let C: UInt16 = 1, V: UInt16 = 2, Z: UInt16 = 4, N: UInt16 = 8, X: UInt16 = 16
    @inline(__always) public func flag(_ f: UInt16) -> Bool { sr & f != 0 }
    @inline(__always) public func setFlag(_ f: UInt16, _ on: Bool) { if on { sr |= f } else { sr &= ~f } }
    public var supervisor: Bool { sr & 0x2000 != 0 }

    public func setSR(_ v: UInt16) {
        let wasS = supervisor
        sr = v & 0xa71f
        let isS = supervisor
        if wasS != isS {
            if isS { usp = a[7]; a[7] = ssp } else { ssp = a[7]; a[7] = usp }
        }
    }

    public func reset() {
        sr = 0x2700
        a[7] = read32(0)
        ssp = a[7]
        pc = read32(4)
        stopped = false
    }

    // MARK: memory
    struct AddressError: Error { let addr: UInt32; let write: Bool; let instr: Bool }
    var pendingAddressError: AddressError?
    public var hasPendingAddressError: Bool { pendingAddressError != nil }

    @inline(__always) public func read8(_ addr: UInt32) -> UInt32 { UInt32(bus.read8(addr & 0xff_ffff)) }
    @inline(__always) public func read16(_ addr: UInt32) -> UInt32 {
        if addr & 1 != 0 && addressErrors { flagAddressError(addr, write: false); return 0 }
        return UInt32(bus.read16(addr & 0xff_ffff))
    }
    @inline(__always) public func read32(_ addr: UInt32) -> UInt32 {
        if addr & 1 != 0 && addressErrors { flagAddressError(addr, write: false); return 0 }
        return UInt32(bus.read16(addr & 0xff_ffff)) << 16 | UInt32(bus.read16((addr &+ 2) & 0xff_ffff))
    }
    @inline(__always) public func write8(_ addr: UInt32, _ v: UInt32) { bus.write8(addr & 0xff_ffff, UInt8(truncatingIfNeeded: v)) }
    @inline(__always) public func write16(_ addr: UInt32, _ v: UInt32) {
        if addr & 1 != 0 && addressErrors { flagAddressError(addr, write: true); return }
        bus.write16(addr & 0xff_ffff, UInt16(truncatingIfNeeded: v))
    }
    @inline(__always) public func write32(_ addr: UInt32, _ v: UInt32) {
        if addr & 1 != 0 && addressErrors { flagAddressError(addr, write: true); return }
        bus.write16(addr & 0xff_ffff, UInt16(truncatingIfNeeded: v >> 16))
        bus.write16((addr &+ 2) & 0xff_ffff, UInt16(truncatingIfNeeded: v))
    }
    func flagAddressError(_ addr: UInt32, write: Bool) {
        if pendingAddressError == nil { pendingAddressError = AddressError(addr: addr, write: write, instr: false) }
    }
    @inline(__always) public func read(_ addr: UInt32, _ s: Size) -> UInt32 {
        switch s { case .byte: return read8(addr); case .word: return read16(addr); case .long: return read32(addr) }
    }
    @inline(__always) public func write(_ addr: UInt32, _ s: Size, _ v: UInt32) {
        switch s { case .byte: write8(addr, v); case .word: write16(addr, v); case .long: write32(addr, v) }
    }

    @inline(__always) public func fetch16() -> UInt32 {
        let v = read16(pc); pc &+= 2; return v
    }
    @inline(__always) public func fetch32() -> UInt32 {
        let v = read32(pc); pc &+= 4; return v
    }

    @inline(__always) public func push32(_ v: UInt32) { a[7] &-= 4; write32(a[7], v) }
    @inline(__always) public func push16(_ v: UInt32) { a[7] &-= 2; write16(a[7], v) }
    @inline(__always) public func pop32() -> UInt32 { let v = read32(a[7]); a[7] &+= 4; return v }
    @inline(__always) public func pop16() -> UInt32 { let v = read16(a[7]); a[7] &+= 2; return v }

    // MARK: effective addresses
    enum Operand {
        case dreg(Int)
        case areg(Int)
        case mem(UInt32)
        case imm(UInt32)
    }

    static let eaTimeBW = [0, 0, 4, 4, 6, 8, 10, 8, 12, 8, 10, 4]
    static let eaTimeL = [0, 0, 8, 8, 10, 12, 14, 12, 16, 12, 14, 8]

    @inline(__always) func eaIndex(_ mode: Int, _ reg: Int) -> Int { mode < 7 ? mode : 7 + reg }

    func indexed(_ base: UInt32) -> UInt32 {
        let ext = fetch16()
        let r = Int(ext >> 12) & 7
        var x = ext & 0x8000 != 0 ? a[r] : d[r]
        if ext & 0x800 == 0 { x = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: x))) }
        return base &+ x &+ UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: ext)))
    }

    /// Decode an effective address, performing increments/decrements and fetching
    /// extension words. Adds EA calculation time to `cycles`.
    func ea(_ mode: Int, _ reg: Int, _ s: Size, time: Bool = true) -> Operand {
        if time { cycles += s == .long ? CPU.eaTimeL[eaIndex(mode, reg)] : CPU.eaTimeBW[eaIndex(mode, reg)] }
        switch mode {
        case 0: return .dreg(reg)
        case 1: return .areg(reg)
        case 2: return .mem(a[reg])
        case 3:
            let addr = a[reg]
            a[reg] &+= (s == .byte && reg == 7) ? 2 : UInt32(s.rawValue)
            return .mem(addr)
        case 4:
            a[reg] &-= (s == .byte && reg == 7) ? 2 : UInt32(s.rawValue)
            return .mem(a[reg])
        case 5:
            let disp = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: fetch16())))
            return .mem(a[reg] &+ disp)
        case 6:
            return .mem(indexed(a[reg]))
        default:
            switch reg {
            case 0: return .mem(UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: fetch16()))))
            case 1: return .mem(fetch32())
            case 2:
                let base = pc
                let disp = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: fetch16())))
                return .mem(base &+ disp)
            case 3:
                return .mem(indexed(pc))
            case 4:
                if s == .long { return .imm(fetch32()) }
                let w = fetch16()
                return .imm(s == .byte ? w & 0xff : w)
            default:
                illegalPending = true
                return .imm(0)
            }
        }
    }
    var illegalPending = false

    @inline(__always) func get(_ op: Operand, _ s: Size) -> UInt32 {
        switch op {
        case .dreg(let r): return d[r] & s.mask
        case .areg(let r): return a[r] & s.mask
        case .mem(let addr): return read(addr, s)
        case .imm(let v): return v & s.mask
        }
    }

    @inline(__always) func put(_ op: Operand, _ s: Size, _ v: UInt32) {
        switch op {
        case .dreg(let r): d[r] = (d[r] & ~s.mask) | (v & s.mask)
        case .areg(let r): a[r] = v   // only via MOVEA etc. (already sign-extended)
        case .mem(let addr): write(addr, s, v)
        case .imm: break
        }
    }

    @inline(__always) func address(_ op: Operand) -> UInt32 {
        if case .mem(let addr) = op { return addr }
        illegalPending = true
        return 0
    }

    // MARK: condition codes
    public func cond(_ c: Int) -> Bool {
        let C = flag(CPU.C), V = flag(CPU.V), Z = flag(CPU.Z), N = flag(CPU.N)
        switch c {
        case 0: return true
        case 1: return false
        case 2: return !C && !Z
        case 3: return C || Z
        case 4: return !C
        case 5: return C
        case 6: return !Z
        case 7: return Z
        case 8: return !V
        case 9: return V
        case 10: return !N
        case 11: return N
        case 12: return N == V
        case 13: return N != V
        case 14: return !Z && N == V
        default: return Z || N != V
        }
    }

    @inline(__always) public func setNZ(_ v: UInt32, _ s: Size) {
        sr &= ~(CPU.N | CPU.Z | CPU.V | CPU.C)
        if v & s.mask == 0 { sr |= CPU.Z }
        if v & s.msb != 0 { sr |= CPU.N }
    }

    // MARK: exceptions
    public func exception(_ vector: Int, pcToPush: UInt32? = nil) {
        let oldSR = sr
        if !supervisor { usp = a[7]; a[7] = ssp }
        sr = (sr | 0x2000) & ~0x8000
        push32(pcToPush ?? pc)
        push16(UInt32(oldSR))
        pc = read32(UInt32(vector * 4))
        cycles += 34
        stopped = false
    }

    func addressErrorException(_ e: AddressError, opcode: UInt32) {
        lastFault = String(format: "address error at PC $%06X accessing $%06X", lastOpPC, e.addr)
        let oldSR = sr
        if !supervisor { usp = a[7]; a[7] = ssp }
        sr = (sr | 0x2000) & ~0x8000
        push32(pc)
        push16(UInt32(oldSR))
        push16(opcode)
        push32(e.addr)
        let info: UInt32 = (e.write ? 0 : 0x10) | (e.instr ? 0 : 0x08) | (oldSR & 0x2000 != 0 ? 0x4 : 0) | (e.instr ? 2 : 1)
        push16(info)
        pc = read32(12)
        cycles += 50
    }

    public func checkInterrupts() {
        let mask = Int(sr >> 8) & 7
        if ipl > mask {
            let level = ipl
            let oldSR = sr
            if !supervisor { usp = a[7]; a[7] = ssp }
            sr = (sr | 0x2000) & ~0x8000
            sr = (sr & ~0x0700) | UInt16(level << 8)
            push32(pc)
            push16(UInt32(oldSR))
            pc = read32(UInt32((24 + level) * 4))
            cycles += 44
            stopped = false
        }
    }

    // MARK: run
    /// Execute one instruction (or service an interrupt). Returns cycles used.
    @discardableResult
    public func step() -> Int {
        let start = cycles
        checkInterrupts()
        if stopped { cycles += 4; return cycles - start }
        if let h = hook, h(self) { return max(4, cycles - start) }
        lastOpPC = pc
        pendingAddressError = nil
        illegalPending = false
        if pc & 1 != 0 {
            let e = AddressError(addr: pc, write: false, instr: true)
            addressErrorException(e, opcode: 0)
            return cycles - start
        }
        instructionStart = cycles
        let op = fetch16()
        execute(op)
        if let e = pendingAddressError {
            pendingAddressError = nil
            addressErrorException(e, opcode: op)
        } else if illegalPending {
            lastFault = String(format: "illegal instruction $%04X at PC $%06X", op, lastOpPC)
            pc = lastOpPC
            exception(4)
        }
        return cycles - start
    }
}
