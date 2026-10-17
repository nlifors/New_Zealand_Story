import AmigaEmu
import NZSCore
import M68K

/// Runs the original game code in the reference emulator, starting at the
/// crack's launcher ($76000) — the cracker intros are skipped.
/// High-level emulation (HLE) replaces only the two disk-read routines:
///   $767C4  launcher track loader  (D0 track, D1 count, A0 dest)
///   $0C24   kernel track loader    (via jump table $40C; D0 track, D1 count, D2 drive, A0 dest)
/// Both return D0 = 0 (success) immediately; real loading time is NOT modelled.
public final class OriginalGame {
    public let machine = Machine()
    public let disk: DiskImage
    public var loads: [(frame: Int, track: Int, count: Int, dest: UInt32)] = []
    /// Extra harness hooks keyed by PC; run before the instruction executes.
    /// Return true to skip the instruction (the hook must then set PC itself).
    public var pcHooks: [UInt32: (CPU) -> Bool] = [:]
    public static let globals: UInt32 = 0x641b8   // A6 base of the game's variables

    public init(disk: DiskImage) throws {
        self.disk = disk
        let m = machine
        m.load(try GameDisk.launcher(disk), at: GameDisk.launcherBase)
        let cpu = m.cpu
        cpu.sr = 0x2700
        cpu.a[7] = 0x7fff0
        cpu.pc = UInt32(GameDisk.launcherBase)
        cpu.hook = { [unowned self] c in self.hook(c) }
    }

    // MARK: calling original routines from the harness
    static let returnSentinel: UInt32 = 0xf0_0000
    var savedState: (d: [UInt32], a: [UInt32], pc: UInt32, sr: UInt16)?

    /// Start a call to an original subroutine as if by JSR, with the given data
    /// registers; the previous CPU state is restored when it returns (RTS).
    public func call(_ address: UInt32, d: [Int: UInt32] = [:]) {
        let c = machine.cpu
        savedState = (c.d, c.a, c.pc, c.sr)
        for (k, v) in d { c.d[k] = v }
        c.a[7] &-= 4
        machine.write16(c.a[7], UInt16(OriginalGame.returnSentinel >> 16))
        machine.write16(c.a[7] + 2, UInt16(OriginalGame.returnSentinel & 0xffff))
        c.pc = address
        c.stopped = false
    }

    public var callInProgress: Bool { savedState != nil }

    public var tracing = false
    public var traceLog: [(UInt32, Int, UInt32)] = []

    func hook(_ c: CPU) -> Bool {
        if tracing { traceLog.append((c.pc, c.cycles, c.d[0])) }
        if c.pc == OriginalGame.returnSentinel, let s = savedState {
            c.d = s.d; c.a = s.a; c.pc = s.pc; c.sr = s.sr
            savedState = nil
            return true
        }
        if let h = pcHooks[c.pc], h(c) { return true }
        switch c.pc {
        case 0x767c4: return hleLoad(c)
        case 0x00c24 where kernelLoaderPresent: return hleLoad(c)
        default: return false
        }
    }

    /// The kernel occupies $400.. only after the launcher has jumped to it.
    var kernelLoaderPresent: Bool {
        // `bra.w $0F92`... first word after relocation is $6000 at $400; check the
        // loader entry signature at $0C24: move.l sp,($156E).l
        machine.read16(0xc24) == 0x23cf && machine.read16(0xc26) == 0x0000 && machine.read16(0xc28) == 0x156e
    }

    func hleLoad(_ c: CPU) -> Bool {
        let track = Int(c.d[0] & 0xffff), count = Int(c.d[1] & 0xffff), dest = c.a[0]
        loads.append((machine.frame, track, count, dest))
        if track + count <= DiskImage.trackCount {
            machine.load(Array(disk.tracks(track, count: count)), at: Int(dest))
        }
        c.d[0] = 0
        c.pc = UInt32(machine.read16(c.a[7])) << 16 | UInt32(machine.read16(c.a[7] + 2))
        c.a[7] &+= 4
        c.cycles += 1000
        return true
    }

    /// Make the next level load use `level` (0-19) instead of the game's choice.
    /// Pokes the level word (8,A6) when the load check at $412E runs.
    /// (Harness-only cheat; the port never needs it.)
    public func forceLevel(_ level: Int, once: Bool = true) {
        var done = false
        pcHooks[0x412e] = { [unowned self] _ in
            if !(once && done) {
                machine.write16(OriginalGame.globals + 8, UInt16(level * 16))
                done = true
            }
            return false
        }
    }

    public func runFrames(_ n: Int) {
        for _ in 0..<n where !machine.resetRequested { machine.runFrame() }
    }
}
