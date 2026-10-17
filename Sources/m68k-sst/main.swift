// Runs the SingleStepTests/m68000 suite (MAME-microcode-generated) against the M68K core.
// Usage: m68k-sst <dir with *.json.bin> [filter] [-v]
// Compares registers, SR, PC and RAM. Cycle counts and bus transactions are ignored.
import Foundation
import M68K
setvbuf(stdout, nil, _IONBF, 0)

final class FlatBus: M68KBus {
    var mem = [UInt8](repeating: 0, count: 1 << 24)
    var touched = [Int]()
    func read8(_ a: UInt32) -> UInt8 { mem[Int(a)] }
    func read16(_ a: UInt32) -> UInt16 { UInt16(mem[Int(a)]) << 8 | UInt16(mem[Int(a) + 1 & 0xffffff]) }
    func write8(_ a: UInt32, _ v: UInt8) { mem[Int(a)] = v; touched.append(Int(a)) }
    func write16(_ a: UInt32, _ v: UInt16) {
        mem[Int(a)] = UInt8(v >> 8); mem[Int(a) + 1 & 0xffffff] = UInt8(v & 0xff)
        touched.append(Int(a)); touched.append(Int(a) + 1 & 0xffffff)
    }
}

struct State { var regs = [UInt32](repeating: 0, count: 19); var prefetch = [UInt32](); var ram = [(Int, UInt8)]() }
struct Test { var name = ""; var initial = State(); var final = State(); var addrErr = false }

func check(_ v: UInt32, _ want: UInt32) { if v != want { fatalError("bad magic \(String(v, radix: 16))") } }

struct Reader {
    let b: [UInt8]; var p = 0
    mutating func u32() -> UInt32 { defer { p += 4 }; return UInt32(b[p]) | UInt32(b[p+1]) << 8 | UInt32(b[p+2]) << 16 | UInt32(b[p+3]) << 24 }
    mutating func u16() -> UInt16 { defer { p += 2 }; return UInt16(b[p]) | UInt16(b[p+1]) << 8 }
    mutating func u8() -> UInt8 { defer { p += 1 }; return b[p] }
    mutating func state() -> State {
        _ = u32(); check(u32(), 0x01234567)
        var s = State()
        for i in 0..<19 { s.regs[i] = u32() }
        s.prefetch = [u32(), u32()]
        let n = Int(u32())
        for _ in 0..<n { let a = Int(u32()); let d = u16(); s.ram.append((a, UInt8(d >> 8))); s.ram.append((a | 1, UInt8(d & 0xff))) }
        return s
    }
    mutating func test() -> Test {
        _ = u32(); check(u32(), 0xABC12367)
        var t = Test()
        _ = u32(); check(u32(), 0x89ABCDEF)
        let n = Int(u32()); t.name = String(decoding: b[p..<p+n], as: UTF8.self); p += n
        t.initial = state(); t.final = state()
        _ = u32(); check(u32(), 0x456789AB)
        _ = u32(); let nt = Int(u32())
        for _ in 0..<nt {
            let tw = u8(); _ = u32()
            if tw == 0 { continue }
            p += 20
            if tw == 4 || tw == 5 { t.addrErr = true }
        }
        return t
    }
}

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let filter = args.count > 2 && !args[2].hasPrefix("-") ? args[2] : nil
let verbose = args.contains("-v")
let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json.bin") }.sorted()
let bus = FlatBus()
let cpu = CPU(bus: bus)
var totalPass = 0, totalRun = 0, totalSkip = 0
for f in files where filter == nil || f.hasPrefix(filter!) {
    var r = Reader(b: [UInt8](try Data(contentsOf: dir.appendingPathComponent(f))))
    check(r.u32(), 0x1A3F5D71)
    let n = Int(r.u32())
    var pass = 0, run = 0, skip = 0, shown = 0
    for _ in 0..<n {
        let t = r.test()
        if t.addrErr { skip += 1; continue }
        for a in bus.touched { bus.mem[a] = 0 }
        bus.touched.removeAll(keepingCapacity: true)
        for (a, v) in t.initial.ram { bus.write8(UInt32(a), v) }
        let i = t.initial.regs
        let pc0 = i[18] &- 4
        bus.write16(pc0, UInt16(t.initial.prefetch[0])); bus.write16(pc0 + 2, UInt16(t.initial.prefetch[1]))
        for k in 0..<8 { cpu.d[k] = i[k] }
        for k in 0..<7 { cpu.a[k] = i[8 + k] }
        cpu.sr = UInt16(i[17])
        if cpu.sr & 0x2000 != 0 { cpu.a[7] = i[16]; cpu.usp = i[15] } else { cpu.a[7] = i[15]; cpu.ssp = i[16] }
        cpu.pc = pc0; cpu.stopped = false; cpu.ipl = 0
        cpu.step()
        run += 1
        let f2 = t.final.regs
        var errs = [String]()
        for k in 0..<8 where cpu.d[k] != f2[k] { errs.append("d\(k)=\(String(cpu.d[k], radix: 16)) want \(String(f2[k], radix: 16))") }
        for k in 0..<7 where cpu.a[k] != f2[8 + k] { errs.append("a\(k)=\(String(cpu.a[k], radix: 16)) want \(String(f2[8+k], radix: 16))") }
        let (myUSP, mySSP) = cpu.sr & 0x2000 != 0 ? (cpu.usp, cpu.a[7]) : (cpu.a[7], cpu.ssp)
        if myUSP != f2[15] { errs.append("usp=\(String(myUSP, radix: 16)) want \(String(f2[15], radix: 16))") }
        if mySSP != f2[16] { errs.append("ssp=\(String(mySSP, radix: 16)) want \(String(f2[16], radix: 16))") }
        if UInt32(cpu.sr) != f2[17] { errs.append("sr=\(String(cpu.sr, radix: 16)) want \(String(f2[17], radix: 16))") }
        if cpu.pc != f2[18] &- 4 { errs.append("pc=\(String(cpu.pc, radix: 16)) want \(String(f2[18] &- 4, radix: 16))") }
        for (a, v) in t.final.ram where bus.mem[a] != v { errs.append("ram[\(String(a, radix: 16))]=\(String(bus.mem[a], radix: 16)) want \(String(v, radix: 16))"); if errs.count > 6 { break } }
        if errs.isEmpty { pass += 1 } else if verbose && shown < 5 { shown += 1; print("  FAIL \(t.name): \(errs.joined(separator: ", "))") }
    }
    print("\(f.padding(toLength: 22, withPad: " ", startingAt: 0)) \(pass)/\(run) pass  (\(skip) address-error tests skipped)")
    totalPass += pass; totalRun += run; totalSkip += skip
}
print("TOTAL \(totalPass)/\(totalRun) pass, \(totalSkip) skipped")
