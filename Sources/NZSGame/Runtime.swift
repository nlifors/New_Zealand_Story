import Foundation
import M68K
import AmigaEmu
import NZSCore

/// Execution environment for the translated original code (Generated/*.swift).
///
/// The original's 68000 state (registers, flags, cycle count) lives in a `CPU`
/// object used purely as a register file; memory and the custom chips are the
/// `Machine`. Translated code advances `c.cycles` exactly as the interpreter
/// does and calls `service` when hardware work or an interrupt is due, so both
/// run in lockstep (checked by ReferenceTests/LockstepTests).
///
/// Native (not translated) pieces — each replaces code the port cannot or
/// should not run:
///   $767C4  launcher track loader   -> copies tracks from the ADF
///   $0C24   kernel track loader     -> copies tracks from the ADF
///   $76694  launcher `jmp $400`     -> continues at the kernel's relocation loop $3218
public final class Runtime {
    public let machine: Machine
    public let disk: DiskImage
    public var c: CPU { machine.cpu }
    public var eventCycle: Int { machine.eventCycle }
    public var loads: [(frame: Int, track: Int, count: Int, dest: UInt32)] = []
    /// Called on the game thread at the end of every 50 Hz frame.
    public var onFrame: (() -> Void)?
    /// Test hooks: called when translated code is entered at these addresses
    /// via dispatch (used by the lockstep tool's level forcing).
    /// Per-instruction trace for lockstep debugging: (pc, cycles before the instruction).
    /// When set, translated code calls `trace` before every instruction.
    public var tracing = false
    public var recordTrace = false
    public var traceLog: [(UInt32, Int, UInt32)] = []
    public func trace(_ c: CPU, _ pc: UInt32) {
        if let h = pokeHooks[pc] { h(machine) }
        if recordTrace { traceLog.append((pc, c.cycles, c.d[0])) }
    }
    public var pokeHooks: [UInt32: (Machine) -> Void] = [:]

    public struct Fatal: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }
    struct Restart: Error {
        let pc: UInt32
        var serviceFirst = false     // after a state load: always service before resuming
        var tick = false             // after a stack reset: the instruction's normal tick
    }

    // MARK: high scores
    /// The high-score table is five 19-byte text records at $47E0 inside the
    /// main image (x, y, 6-digit score, "w_s" level reached, 3-letter name).
    public static let highScoreTable: UInt32 = 0x47e0, highScoreSize = 5 * 19
    /// Applied when the main image has been unpacked (the launcher's jump to $400).
    public var highScoreRestore: [UInt8]?

    public static func validHighScores(_ b: [UInt8]) -> Bool {
        guard b.count == highScoreSize else { return false }
        for k in 0..<5 {
            let e = Array(b[(k * 19)..<(k * 19 + 19)])
            guard e[0] == 0x0e, e[2...7].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), e[11] == 0x5f else { return false }
        }
        return true
    }
    public func currentHighScores() -> [UInt8] {
        machine.readBytes(Int(Runtime.highScoreTable), Runtime.highScoreSize)
    }

    // MARK: save states
    /// Set on the game thread; taken at the next safe point (main level, not in
    /// an interrupt, at an address translated code can be re-entered at).
    public var saveRequest: ((Data) -> Void)?
    public var pendingLoad: Data?
    static let stateMagic: UInt32 = 0x4e5a_5331   // "NZS1"

    func checkSaveLoad(_ c: CPU, _ pc: UInt32) throws {
        if let req = saveRequest, Int(c.sr >> 8) & 7 == 0, dispatchEntries.contains(pc) {
            saveRequest = nil
            var w = StateWriter()
            w.u32(Runtime.stateMagic); w.u32(pc)
            var d = w.data
            d.append(machine.saveState())
            req(d)
        }
        if let d = pendingLoad {
            pendingLoad = nil
            var r = StateReader(d)
            guard try r.u32() == Runtime.stateMagic else { throw Fatal(message: "not a save state") }
            let pc = try r.u32()
            try machine.loadState(d.subdata(in: (d.startIndex + 16)..<d.endIndex))
            throw Restart(pc: pc, serviceFirst: true)
        }
    }

    public init(disk: DiskImage) throws {
        self.disk = disk
        machine = Machine()
        machine.load(try GameDisk.launcher(disk), at: GameDisk.launcherBase)
        let c = machine.cpu
        c.sr = 0x2700
        c.a[7] = 0x7fff0
        c.pc = UInt32(GameDisk.launcherBase)
        c.translatedMode = true
        machine.frameEnded = { [unowned self] in onFrame?() }
    }

    /// Run the original from the launcher entry. Returns only on a fatal error
    /// or when the game requests a reset ($F80000).
    public func run() throws {
        var pc = c.pc
        while true {
            do {
                pc = try dispatch(c, pc)
            } catch let r as Restart {
                pc = r.pc
                if r.serviceFirst || (r.tick && c.cycles >= eventCycle) {
                    // resume exactly: the hardware/interrupt work due at this boundary first
                    if r.serviceFirst { machine.eventCycle = 0 }
                    do { try service(c, pc) } catch let r2 as Restart { pc = r2.pc }
                }
            }
        }
    }

    // MARK: called by generated code

    public func service(_ c: CPU, _ pc: UInt32) throws {
        let m = machine
        if saveRequest != nil || pendingLoad != nil { try checkSaveLoad(c, pc) }
        while c.cycles >= m.lineEnd {
            m.endLine()
            m.beginLine()
        }
        if m.resetRequested { throw Fatal(message: "game jumped to ROM (reset)") }
        while c.ipl > Int(c.sr >> 8) & 7 {
            try takeInterrupt(c, pc)
        }
        m.eventCycle = c.ipl > Int(c.sr >> 8) & 7 ? 0 : m.lineEnd
    }

    /// Mirrors CPU.checkInterrupts, then runs the handler until its RTE.
    func takeInterrupt(_ c: CPU, _ pc: UInt32) throws {
        let level = c.ipl
        let oldSR = c.sr
        if !c.supervisor { c.usp = c.a[7]; c.a[7] = c.ssp }
        c.sr = (c.sr | 0x2000) & ~0x8000
        c.sr = (c.sr & ~0x0700) | UInt16(level << 8)
        c.push32(pc)
        c.push16(UInt32(oldSR))
        let handler = c.read32(UInt32((24 + level) * 4))
        c.cycles += 44
        // (the interpreter executes the handler's first instruction before it
        // looks at hardware events again, so no service() here)
        machine.eventCycle = c.ipl > level ? 0 : machine.lineEnd
        let r = try dispatch(c, handler)
        if r != pc { throw Fatal(message: String(format: "interrupt handler returned to $%06X, expected $%06X", r, pc)) }
    }

    /// Mirrors CPU.exception (TRAP etc.), then runs the handler.
    public func exception(_ c: CPU, vector: Int, returnTo: UInt32) throws -> UInt32 {
        let oldSR = c.sr
        if !c.supervisor { c.usp = c.a[7]; c.a[7] = c.ssp }
        c.sr = (c.sr | 0x2000) & ~0x8000
        c.push32(returnTo)
        c.push16(UInt32(oldSR))
        let handler = c.read32(UInt32(vector * 4))
        c.cycles += 34
        if c.cycles >= eventCycle { try service(c, handler) }
        return try dispatch(c, handler)
    }

    public func dispatch(_ c: CPU, _ addr: UInt32) throws -> UInt32 {
        if let r = try dispatchOriginal(c, self, addr) { return r }
        switch addr {
        case 0x767c4, 0x00c24, 0x76694: return try native(c, addr)
        default: return try interpretFallback(c, addr)
        }
    }

    /// Addresses that had to be run by the interpreter (missing translations).
    public private(set) var fallbackLog: [UInt32: Int] = [:]
    public var allowFallback = true

    /// Safety net for code the translator did not reach: run it with the
    /// reference interpreter on the same state until it returns (RTS/RTE/RTR
    /// above the entry stack level) or reaches translated code. Logged so the
    /// entry can be added to the translation.
    /// Run original code at `addr` with the interpreter (self-modified opcodes).
    public func interpret(_ c: CPU, _ addr: UInt32) throws -> UInt32 {
        try interpretFallback(c, addr, force: true)
    }

    func interpretFallback(_ c: CPU, _ addr: UInt32, force: Bool = false) throws -> UInt32 {
        guard allowFallback || force, addr < 0x80000, addr & 1 == 0 else {
            throw Fatal(message: String(format: "no translated code at $%06X", addr))
        }
        fallbackLog[addr, default: 0] += 1
        let baseSP = c.a[7]
        c.pc = addr
        var first = true
        while true {
            if c.cycles >= eventCycle { try service(c, c.pc) }
            // back to translated code as soon as possible (guarded instructions
            // re-check themselves and come back here if still rewritten)
            if !first, let r = try dispatchOriginal(c, self, c.pc) { return r }
            first = false
            let pc = c.pc
            let op = machine.read16(pc)
            if tracing { trace(c, pc) }
            c.translatedMode = false
            c.step()
            c.translatedMode = true
            if let f = c.lastFault { throw Fatal(message: f) }
            let isReturn = op == 0x4e75 || op == 0x4e73 || op == 0x4e77
            if isReturn && c.a[7] > baseSP { return c.pc }
            let isCall = op & 0xffc0 == 0x4e80 || op & 0xff00 == 0x6100
            if isCall {
                let expected = c.read32(c.a[7])
                if let r = try dispatchOriginal(c, self, c.pc) {
                    if r != expected { return r }
                    c.pc = r
                }
            }
        }
    }

    public func native(_ c: CPU, _ addr: UInt32) throws -> UInt32 {
        switch addr {
        case 0x767c4, 0x00c24:
            // same effect and cost as OriginalGame.hleLoad in the reference harness
            let track = Int(c.d[0] & 0xffff), count = Int(c.d[1] & 0xffff), dest = c.a[0]
            loads.append((machine.frame, track, count, dest))
            if track + count <= DiskImage.trackCount {
                machine.load(Array(disk.tracks(track, count: count)), at: Int(dest))
            }
            c.d[0] = 0
            let ret = c.pop32()
            c.cycles += 1000
            if c.cycles >= eventCycle { try service(c, ret) }
            return ret
        case 0x76694:
            // (port addition) restore saved high scores into the freshly unpacked image
            if let hs = highScoreRestore, Runtime.validHighScores(hs) {
                // keep each record's screen position bytes; take score, level, name
                var cur = currentHighScores()
                for k in 0..<5 { for j in 2..<18 { cur[k * 19 + j] = hs[k * 19 + j] } }
                machine.load(cur, at: Int(Runtime.highScoreTable))
            }
            // jmp $400.w (10 cycles) lands on the pre-relocation `bra.w $3218` (10 cycles)
            c.cycles += 10
            if c.cycles >= eventCycle { try service(c, 0x400) }
            c.cycles += 10
            if c.cycles >= eventCycle { try service(c, 0x3218) }
            return try dispatch(c, 0x3218)
        default:
            throw Fatal(message: String(format: "no native routine for $%06X", addr))
        }
    }

    public func fatal(_ c: CPU, _ message: String) throws {
        throw Fatal(message: message)
    }

    /// SP was loaded with a constant: the original abandons its stack (main-loop
    /// restart). Unwind the Swift stack too and resume at `next`.
    public func stackReset(_ c: CPU, _ next: UInt32) throws {
        throw Restart(pc: next, tick: true)
    }
}
