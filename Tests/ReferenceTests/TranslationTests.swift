import Testing
import Foundation
import M68K
@testable import NZSGame
import NZSCore

/// Memory for the differential test: deterministic pseudo-random contents,
/// overlaid with the translated program's bytes, recording all writes.
final class HashBus: M68KBus {
    let program: [UInt8]           // 512K: launcher + relocated main image
    let seed: UInt32
    var written = [UInt32: UInt8]()
    init(program: [UInt8], seed: UInt32) { self.program = program; self.seed = seed }
    func byte(_ a: UInt32) -> UInt8 {
        if let v = written[a] { return v }
        if a < 0x80000, program[Int(a)] != 0 || a < 0x16000 || (a >= 0x76000 && a < 0x76c00) { return program[Int(a)] }
        var x = (a &+ seed) &* 0x9E37_79B9; x ^= x >> 15; x = x &* 0x85EB_CA6B; x ^= x >> 13
        return UInt8(truncatingIfNeeded: x)
    }
    func read8(_ a: UInt32) -> UInt8 { byte(a) }
    func read16(_ a: UInt32) -> UInt16 { UInt16(byte(a)) << 8 | UInt16(byte(a &+ 1)) }
    func write8(_ a: UInt32, _ v: UInt8) { written[a] = v }
    func write16(_ a: UInt32, _ v: UInt16) { written[a] = UInt8(v >> 8); written[a &+ 1] = UInt8(v & 0xff) }
}

@Suite(.enabled(if: RefFixture.available, "needs the ADF"))
struct TranslationTests {
    /// Every translated instruction, from random states, against the interpreter.
    @Test func everyInstructionMatchesInterpreter() throws {
        let disk = try DiskImage(contentsOf: URL(fileURLWithPath: RefFixture.path))
        var mem = [UInt8](repeating: 0, count: 0x80000)
        for (k, b) in try GameDisk.launcher(disk).enumerated() { mem[0x76000 + k] = b }
        let main = try GameDisk.mainImage(disk)
        for (k, b) in main.enumerated() { mem[0x400 + k] = b }
        for k in 0..<(0xb84 * 4) { mem[0x400 + k] = main[4 + k] }

        var rng: UInt64 = 0x51ed_270b_d2a4_ea3d
        func r32() -> UInt32 { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return UInt32(truncatingIfNeeded: rng) }
        var failures = [String](), tested = 0, skipped = 0
        for (addr, snippet) in instructionSnippets.sorted(by: { $0.key < $1.key }) {
            for trial in 0..<12 {
                let seed = r32()
                let d = (0..<8).map { k -> UInt32 in
                    // small values sometimes, so loops/shifts/branches take both paths
                    trial % 3 == 0 ? r32() & 0x3f : r32()
                }
                let a = (0..<7).map { _ in 0x10000 + (r32() & 0x5fffe) }
                let ccr = UInt16(r32() & 0x1f)
                let busA = HashBus(program: mem, seed: seed), busB = HashBus(program: mem, seed: seed)
                let ref = CPU(bus: busA), port = CPU(bus: busB)
                for cpu in [ref, port] {
                    for k in 0..<8 { cpu.d[k] = d[k] }
                    for k in 0..<7 { cpu.a[k] = a[k] }
                    cpu.a[7] = 0x7f000; cpu.ssp = 0x7f000; cpu.usp = 0x6f000
                    cpu.sr = 0x2700 | ccr
                    cpu.pc = addr
                    cpu.ipl = 0
                }
                port.translatedMode = true
                ref.step()
                if ref.lastFault != nil { skipped += 1; continue }
                let next: UInt32
                do { next = try snippet(port) } catch { skipped += 1; continue }
                if port.hasPendingAddressError { skipped += 1; continue }
                tested += 1
                var diff = [String]()
                if ref.pc != next { diff.append(String(format: "pc $%X vs $%X", ref.pc, next)) }
                if ref.d != port.d { diff.append("d \(ref.d.map { String($0, radix: 16) }) vs \(port.d.map { String($0, radix: 16) })") }
                if ref.a != port.a { diff.append("a regs") }
                if ref.sr != port.sr { diff.append(String(format: "sr $%04X vs $%04X", ref.sr, port.sr)) }
                if ref.cycles != port.cycles { diff.append("cycles \(ref.cycles) vs \(port.cycles)") }
                if busA.written != busB.written { diff.append("memory writes differ") }
                if !diff.isEmpty { failures.append(String(format: "$%06X: ", addr) + diff.joined(separator: "; ")); break }
            }
        }
        print("differential test: \(tested) trials, \(skipped) skipped, \(failures.count) instructions failing")
        for f in failures.prefix(30) { print("  " + f) }
        #expect(failures.isEmpty)
    }
}
