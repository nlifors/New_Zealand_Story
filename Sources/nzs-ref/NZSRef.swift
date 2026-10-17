// nzs-ref: run the ORIGINAL game code in the reference emulator and dump
// frames, audio and traces.
//   nzs-ref <adf> <outdir> [--frames N] [--every K] [--scale S] [--wav]
//           [--fire-at F,F..] [--random] [--seed N] [--coverage] [--blits]
//           [--watch lo,hi] [--audiolog] [--music N] [--level N]
import Foundation
import NZSCore
import NZSReference
import AmigaEmu

@main
struct NZSRef {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        var tool = try Tool(args: Array(CommandLine.arguments.dropFirst()))
        try tool.run()
    }
}

struct XorShift {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
}

struct Tool {
    let args: [String]
    let out: String
    let game: OriginalGame
    var m: Machine { game.machine }

    init(args: [String]) throws {
        self.args = args
        out = args[1]
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        game = try OriginalGame(disk: DiskImage(contentsOf: URL(fileURLWithPath: args[0])))
    }

    func opt(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    func flag(_ name: String) -> Bool { args.contains(name) }

    mutating func run() throws {
        let frames = Int(opt("--frames") ?? "300")!
        if let tune = opt("--music").flatMap({ Int($0) }) { try music(tune, frames: frames); return }

        let every = Int(opt("--every") ?? "50")!
        let scale = Int(opt("--scale") ?? "2")!
        let fireAt = Set((opt("--fire-at") ?? "").split(separator: ",").compactMap { Int($0) })
        m.paula.capture = flag("--wav")
        m.paula.logging = flag("--audiolog")
        var rng = XorShift(s: UInt64(opt("--seed") ?? "1234567") ?? 1234567)
        var input = (u: false, d: false, l: false, r: false, f: false)

        if flag("--coverage") {
            m.coverage = [UInt8](repeating: 0, count: 0x40000)
            if let prev = try? Data(contentsOf: URL(fileURLWithPath: "\(out)/coverage.bin")), prev.count == 0x40000 { m.coverage = [UInt8](prev) }
        }
        var blitSummary = [String: (count: Int, firstFrame: Int, rec: BlitRecord)]()
        if let rf = opt("--blitraw").flatMap({ Int($0) }) {
            m.blitLog = { r in
                guard r.frame >= rf && r.frame < rf + 9 else { return }
                print(String(format: "f%d pc=%06X con0=%04X con1=%04X %2dx%-3d A=%06X B=%06X C=%06X D=%06X mods A%04X B%04X C%04X D%04X fwm %04X lwm %04X",
                             r.frame, r.pc, r.con0, r.con1, r.width, r.height, r.a, r.b, r.c, r.d, r.amod, r.bmod, r.cmod, r.dmod, r.fwm, r.lwm))
            }
        }
        if flag("--blits") {
            m.blitLog = { r in
                let key = String(format: "pc=%06X con0=%04X con1=%04X %2dx%-3d A=%06X B=%06X", r.pc, r.con0, r.con1, r.width, r.height,
                                 r.con0 & 0x800 != 0 ? r.a : 0, r.con0 & 0x400 != 0 ? r.b : 0)
                if let e = blitSummary[key] { blitSummary[key] = (e.count + 1, e.firstFrame, e.rec) } else { blitSummary[key] = (1, r.frame, r) }
            }
        }
        var watchHits = [UInt32: (count: Int, frame: Int, lo: UInt32, hi: UInt32)]()
        if let w = opt("--watch") {
            let parts = w.split(separator: ",").map { UInt32($0, radix: 16)! }
            let lo = parts[0], hi = parts[1]
            let mm = m
            m.writeWatch = { addr, _, _ in
                guard addr >= lo && addr < hi else { return }
                let pc = mm.cpu.lastOpPC
                if let e = watchHits[pc] { watchHits[pc] = (e.count + 1, e.frame, min(e.lo, addr), max(e.hi, addr)) }
                else { watchHits[pc] = (1, mm.frame, addr, addr) }
            }
        }
        if let lv = opt("--level").flatMap({ Int($0) }) { game.forceLevel(lv) }
        // --flips: histogram of frames between screen-flip requests (st $63DDA at $BCC8)
        var flipFrames = [Int](); var lastFlip = -1; var gaps = [Int: Int]()
        if flag("--flips") {
            game.pcHooks[0xbcc8] = { [m] _ in
                if lastFlip >= 0 { gaps[m.frame - lastFlip, default: 0] += 1 }
                lastFlip = m.frame; flipFrames.append(m.frame); return false
            }
        }
        // idle = cycles spent spinning in the flip-wait loop $BCD0..$BCD6 per update
        var idleCycles = 0, lastCycles = 0, idleHist = [Int: Int]()
        if flag("--flips") {
            game.pcHooks[0xbcd0] = { [m] c in
                if lastCycles != 0 { idleCycles += c.cycles - lastCycles }
                lastCycles = c.cycles; return false
            }
            game.pcHooks[0xbcd8] = { _ in
                idleHist[idleCycles / 10000, default: 0] += 1; idleCycles = 0; lastCycles = 0; return false
            }
        }
        defer { if flag("--flips") { print("idle per update (x10k cycles):", idleHist.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")) } }
        defer { if flag("--flips") { print("frames between flips:", gaps.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")) } }
        // --smc: report CPU writes into instructions that have been executed
        var smc = [String: Int]()
        if flag("--smc") {
            if m.coverage == nil { m.coverage = [UInt8](repeating: 0, count: 0x40000) }
            let mm = m
            m.writeWatch = { addr, _, size in
                guard addr < 0x80000 else { return }
                for k in 0..<UInt32(size) where mm.coverage![Int((addr + k) >> 1)] & 1 != 0 {
                    smc[String(format: "pc=$%06X writes code at $%06X", mm.cpu.lastOpPC, addr + k), default: 0] += 1
                }
            }
        }
        defer { for (k, v) in smc.sorted(by: { $0.key < $1.key }) { print(k, "x\(v)") } }
        let rawKeys: [Character: UInt8] = ["A": 0x20, "B": 0x35, "C": 0x33, "D": 0x22, "E": 0x12, "F": 0x23, "G": 0x24, "H": 0x25,
            "I": 0x17, "J": 0x26, "K": 0x27, "L": 0x28, "M": 0x37, "N": 0x36, "O": 0x18, "P": 0x19, "Q": 0x10, "R": 0x13,
            "S": 0x21, "T": 0x14, "U": 0x16, "V": 0x34, "W": 0x11, "X": 0x32, "Y": 0x15, "Z": 0x31]
        var typed = [UInt8]()
        if let w = opt("--type") { for ch in w.uppercased() { if let k = rawKeys[ch] { typed += [k, k | 0x80] } } }
        let skipEvery = opt("--skip-every").flatMap { Int($0) }
        let t0 = Date()
        for f in 0..<frames {
            if f >= 260 && !typed.isEmpty && f % 2 == 0 { m.keyQueue.append(typed.removeFirst()) }
            if let n = skipEvery, f > 1400 { if f % n == 0 { m.keyQueue.append(0x5f) } else if f % n == 3 { m.keyQueue.append(0xdf) } }
            m.joyFire = fireAt.contains(f) || fireAt.contains(f - 1) || fireAt.contains(f - 2)
            if flag("--random") && f > 300 {
                if f % 12 == 0 {
                    let r = rng.next()
                    input = (r & 7 == 0, r & 0x30 == 0x10, r & 0x300 == 0x100, r & 0x300 == 0x200, r & 0x3000 != 0)
                }
                m.joyUp = input.u; m.joyDown = input.d; m.joyLeft = input.l; m.joyRight = input.r
                m.joyFire = input.f && f % 4 < 2
            }
            // --hold DIRS [--hold-from F]: hold joystick directions (u/d/l/r/f) from frame F
            if let h = opt("--hold"), f >= Int(opt("--hold-from") ?? "700")! {
                m.joyUp = h.contains("u"); m.joyDown = h.contains("d"); m.joyLeft = h.contains("l"); m.joyRight = h.contains("r")
                if h.contains("f") { m.joyFire = f % 4 < 2 }
            }
            m.runFrame()
            if let fromF = opt("--save-from").flatMap({ Int($0) }), f + 1 >= fromF, f + 1 < fromF + 200 {
                try ImageFile.writePNG(String(format: "%@/seq_%05d.png", out, f + 1), width: Video.width, height: Video.height, pixels: m.video.lastFrame, scale: 1)
            }
            if flag("--scrolllog"), f >= Int(opt("--hold-from") ?? "700")!, f < Int(opt("--hold-from") ?? "700")! + 80 {
                let cop = UInt32(m.custom[0x80 >> 1]) << 16 | UInt32(m.custom[0x82 >> 1])
                if f == Int(opt("--hold-from") ?? "700")! {
                    var a = cop; var lines = [String]()
                    for _ in 0..<80 { let w1 = m.read16(a), w2 = m.read16(a + 2); lines.append(String(format: "%06X: %04X %04X", a, w1, w2)); a += 4; if w1 == 0xffff && w2 == 0xfffe { break } }
                    print(lines.joined(separator: "\n"))
                }
                let w = stride(from: UInt32(0xc2b8), to: 0xc2e0, by: 2).map { String(format: "%04X", m.read16($0)) }
                let regs = [0x8e, 0x90, 0x92, 0x94, 0x100, 0x102, 0x104, 0x108, 0x10a].map { String(format: "%03X=%04X", $0, m.custom[$0 >> 1]) }
                print("f\(f + 1) regs:", regs.joined(separator: " "))
                print("f\(f + 1) cop:", w.joined(separator: " "), String(format: "  (3c,A6)=%04X", m.read16(0x641b8 + 0x3c)))
            }
            if !m.faults.isEmpty { print("frame \(f): faults: \(m.faults.prefix(5))"); m.faults.removeAll() }
            if m.resetRequested { print("frame \(f): game jumped to ROM (reset)"); break }
            if (f + 1) % every == 0 {
                let path = "\(out)/frame_\(String(format: "%05d", f + 1)).png"
                try ImageFile.writePNG(path, width: Video.width, height: Video.height, pixels: m.video.lastFrame, scale: scale)
                print(String(format: "frame %5d  pc=$%06X  blits=%d", f + 1, m.cpu.pc, m.blitCount))
            }
        }
        print("loads:", game.loads.map { "f\($0.frame):T\($0.track)x\($0.count)->$\(String($0.dest, radix: 16))" }.joined(separator: " "))
        print(String(format: "%.2fs for %d frames", Date().timeIntervalSince(t0), frames))
        for (pc, h) in watchHits.sorted(by: { $0.key < $1.key }) {
            print(String(format: "write pc=$%06X n=%d first frame %d range $%06X-$%06X", pc, h.count, h.frame, h.lo, h.hi))
        }
        if let cov = m.coverage {
            try Data(cov).write(to: URL(fileURLWithPath: "\(out)/coverage.bin"))
            print("coverage: \(cov.filter { $0 & 1 != 0 }.count) instructions, \(cov.filter { $0 & 2 != 0 }.count) call targets")
        }
        if !blitSummary.isEmpty {
            let lines = blitSummary.sorted { $0.key < $1.key }.map { k, v in String(format: "%@  n=%-6d first=f%-5d D=%06X mods A%04X B%04X C%04X D%04X", k, v.count, v.firstFrame, v.rec.d, v.rec.amod, v.rec.bmod, v.rec.cmod, v.rec.dmod) }
            try lines.joined(separator: "\n").write(toFile: "\(out)/blits.txt", atomically: true, encoding: .utf8)
            print("\(lines.count) distinct blits -> \(out)/blits.txt")
        }
        if m.paula.logging {
            let names = ["LCH", "", "LCL", "", "LEN", "", "PER", "", "VOL", "", "DAT", "", "", "", "", ""]
            let lines = m.paula.log.map { String(format: "f%05d ch%d %@ %04X", $0.0, $0.1, names[$0.2] as NSString, $0.3) }
            try lines.joined(separator: "\n").write(toFile: "\(out)/audiolog.txt", atomically: true, encoding: .utf8)
            print("\(lines.count) audio register writes -> \(out)/audiolog.txt")
        }
        if m.paula.capture { try WAVFile.write("\(out)/audio.wav", rate: 44100, left: m.paula.samplesL, right: m.paula.samplesR) }
    }

    /// Boot to the silent title screen, call the original driver's play-tune
    /// entry $E808 with D0 = tune and record `frames` frames of audio.
    func music(_ tune: Int, frames: Int) throws {
        for _ in 0..<300 { m.runFrame() }
        game.call(0xe808, d: [0: UInt32(tune)])
        while game.callInProgress { m.runLine() }
        m.paula.capture = true
        m.paula.samplesL.removeAll(); m.paula.samplesR.removeAll()
        for _ in 0..<frames { m.runFrame() }
        try WAVFile.write("\(out)/music_\(String(format: "%02d", tune)).wav", rate: 44100, left: m.paula.samplesL, right: m.paula.samplesR)
        print("tune \(tune): \(m.paula.samplesL.count) samples, peak \(m.paula.samplesL.map { abs(Int($0)) }.max() ?? 0)")
    }
}
