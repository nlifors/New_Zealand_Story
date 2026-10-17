// nzs-lockstep: run the reference interpreter and the translated port side by
// side with identical input and compare complete machine state every frame.
// Usage: nzs-lockstep <adf> [--frames N] [--random] [--seed S] [--level L]
import Foundation
import NZSCore
import NZSReference
import NZSGame
import AmigaEmu

@main
struct Lockstep {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = Array(CommandLine.arguments.dropFirst())
        func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let frames = Int(opt("--frames") ?? "1500")!
        let disk = try DiskImage(contentsOf: URL(fileURLWithPath: args[0]))
        let ref = try OriginalGame(disk: disk)
        let port = try Runtime(disk: disk)
        if let lv = opt("--level").flatMap({ Int($0) }) {
            ref.forceLevel(lv)
            var done = false
            port.pokeHooks[0x412e] = { m in if !done { m.write16(0x641b8 + 8, UInt16(lv * 16)); done = true } }
            port.tracing = true
        }
        var seed = UInt64(opt("--seed") ?? "99") ?? 99
        func rnd() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }

        // port runs on its own thread with a big stack; it pauses at every frame end
        let toPort = DispatchSemaphore(value: 0), toMain = DispatchSemaphore(value: 0)
        var portError: String?
        port.onFrame = { toMain.signal(); toPort.wait() }
        let th = Thread {
            do { try port.run() } catch { portError = "\(error)" }
            toMain.signal()
        }
        th.stackSize = 1 << 26
        th.start()

        var input = (u: false, d: false, l: false, r: false, f: false)
        // --type WORD: type Amiga raw keys on the title screen (from frame 260), both machines
        let rawKeys: [Character: UInt8] = ["A": 0x20, "B": 0x35, "C": 0x33, "D": 0x22, "E": 0x12, "F": 0x23, "G": 0x24, "H": 0x25,
            "I": 0x17, "J": 0x26, "K": 0x27, "L": 0x28, "M": 0x37, "N": 0x36, "O": 0x18, "P": 0x19, "Q": 0x10, "R": 0x13,
            "S": 0x21, "T": 0x14, "U": 0x16, "V": 0x34, "W": 0x11, "X": 0x32, "Y": 0x15, "Z": 0x31]
        var typed = [UInt8]()
        if let w = opt("--type") { for ch in w.uppercased() { if let k = rawKeys[ch] { typed += [k, k | 0x80] } } }
        let t0 = Date()
        for f in 0..<frames {
            if args.contains("--random") && f > 300 {
                if f % 12 == 0 { let r = rnd(); input = (r & 7 == 0, r & 0x30 == 0x10, r & 0x300 == 0x100, r & 0x300 == 0x200, r & 0x3000 != 0) }
            } else { input = (false, false, false, false, (400...402).contains(f)) }
            for m in [ref.machine, port.machine] {
                m.joyUp = input.u; m.joyDown = input.d; m.joyLeft = input.l; m.joyRight = input.r
                m.joyFire = args.contains("--random") && f > 300 ? (input.f && f % 4 < 2) : input.f
            }
            let traceFrom = Int(opt("--trace-from") ?? "-1")!
            if f == traceFrom { ref.tracing = true; port.tracing = true; port.recordTrace = true }
            // --skip-every N: with the cheat active, HELP ($5F) skips the level (developer key)
            if let n = opt("--skip-every").flatMap({ Int($0) }), f > 1400, f % n == 0 {
                for mm in [ref.machine, port.machine] { mm.keyQueue.append(0x5f) }
            }
            if let n = opt("--skip-every").flatMap({ Int($0) }), f > 1400, f % n == 3 {
                for mm in [ref.machine, port.machine] { mm.keyQueue.append(0x5f | 0x80) }
            }
            if f % 500 == 0 { print(String(format: "  frame %d level word %d lives %d", f, Int(ref.machine.read16(0x641b8 + 8)) / 16, Int(ref.machine.read16(0x641b8 + 0x1a)))) }
            if f >= 260 && !typed.isEmpty && f % 2 == 0 {
                let k = typed.removeFirst()
                ref.machine.keyQueue.append(k); port.machine.keyQueue.append(k)
            }
            ref.machine.runFrame()
            if f > 0 { toPort.signal() }
            toMain.wait()
            if let e = portError { print("frame \(f): port stopped: \(e)"); exit(1) }
            if let d = compare(ref.machine, port.machine) {
                print("frame \(f): DIVERGED: \(d)")
                if ref.tracing {
                    let a = ref.traceLog.filter { $0.0 != 0x76694 && !($0.0 == 0x400 && $0.2 == 0xF974DB7D) }, b = port.traceLog
                    var i = 0
                    while i < min(a.count, b.count) && a[i].0 == b[i].0 && a[i].1 == b[i].1 && a[i].2 == b[i].2 { i += 1 }
                    print("trace: \(a.count) vs \(b.count) instructions; first difference at #\(i)")
                    for k in max(0, i - 8)..<min(i + 4, max(a.count, b.count)) {
                        let x = k < a.count ? String(format: "$%06X c=%d d0=%08X", a[k].0, a[k].1, a[k].2) : "-"
                        let y = k < b.count ? String(format: "$%06X c=%d d0=%08X", b[k].0, b[k].1, b[k].2) : "-"
                        print("  \(k): ref \(x)   port \(y)")
                    }
                }
                exit(1)
            }
            if f % 250 == 0 { print("frame \(f) identical (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)") }
        }
        print("\(frames) frames identical")
        print(String(format: "lives word (0x1A,A6) = %d", Int(ref.machine.read16(0x641b8 + 0x1a))))
        if !port.fallbackLog.isEmpty { print("interpreter fallbacks:", port.fallbackLog.map { String(format: "$%06X x%d", $0.key, $0.value) }.sorted().joined(separator: " ")) }
        exit(0)
    }

    static func compare(_ a: Machine, _ b: Machine) -> String? {
        let ca = a.cpu, cb = b.cpu
        if ca.cycles != cb.cycles { return "cycles \(ca.cycles) vs \(cb.cycles)" }
        for k in 0..<8 where ca.d[k] != cb.d[k] { return String(format: "d%d $%08X vs $%08X", k, ca.d[k], cb.d[k]) }
        for k in 0..<8 where ca.a[k] != cb.a[k] { return String(format: "a%d $%08X vs $%08X", k, ca.a[k], cb.a[k]) }
        if ca.sr != cb.sr { return String(format: "sr $%04X vs $%04X", ca.sr, cb.sr) }
        for k in 0..<256 where a.custom[k] != b.custom[k] { return String(format: "custom $%03X $%04X vs $%04X", k * 2, a.custom[k], b.custom[k]) }
        for i in 0..<Machine.chipSize where a.chip[i] != b.chip[i] {
            return String(format: "memory $%06X $%02X vs $%02X", i, a.chip[i], b.chip[i])
        }
        return nil
    }
}
