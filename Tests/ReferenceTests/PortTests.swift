import Testing
import Foundation
import NZSCore
import NZSGame
import AmigaEmu

/// Runs the translated port headless on a background thread, one frame at a time.
final class PortDriver {
    let rt: Runtime
    let toPort = DispatchSemaphore(value: 0), toMain = DispatchSemaphore(value: 0)
    var error: String?
    var started = false
    init() throws {
        rt = try Runtime(disk: DiskImage(contentsOf: URL(fileURLWithPath: RefFixture.path)))
        rt.onFrame = { [unowned self] in toMain.signal(); toPort.wait() }
    }
    func frame(_ input: (inout Machine) -> Void = { _ in }) {
        var m = rt.machine
        input(&m)
        if !started {
            started = true
            let th = Thread { [unowned self] in
                do { try rt.run() } catch { self.error = "\(error)" }
                toMain.signal()
            }
            th.stackSize = 1 << 26
            th.start()
        } else { toPort.signal() }
        toMain.wait()
    }
}

@Suite(.enabled(if: RefFixture.available, "needs the ADF"), .serialized)
struct PortTests {
    /// A saved high-score table is put into the unpacked image at boot.
    @Test func highScoresRestored() throws {
        let p = try PortDriver()
        var hs = [UInt8]()
        for k in 0..<5 {
            var e = [UInt8](repeating: 0x20, count: 19)
            e[0] = 0x0e; e[1] = 0
            for (j, ch) in "0\(9 - k)1230".utf8.enumerated() { e[2 + j] = ch }
            for (j, ch) in "  5_2  ".utf8.enumerated() { e[8 + j] = ch }
            for (j, ch) in "MAC".utf8.enumerated() { e[15 + j] = ch }
            e[18] = k == 4 ? 0xff : 0
            hs += e
        }
        #expect(Runtime.validHighScores(hs))
        p.rt.highScoreRestore = hs
        for _ in 0..<300 { p.frame() }
        let now = p.rt.currentHighScores()
        for k in 0..<5 { #expect(Array(now[(k * 19 + 2)..<(k * 19 + 18)]) == Array(hs[(k * 19 + 2)..<(k * 19 + 18)])) }
        #expect(now[1] == 0x50)    // screen position bytes kept from the original
    }

    /// Save state at frame 1300 (level 1 running), play on, load, replay the
    /// same input: the machine must end up byte-identical.
    @Test func saveStateRoundTrip() throws {
        let p = try PortDriver()
        func input(_ f: Int) -> (inout Machine) -> Void {
            { m in m.joyFire = (400...402).contains(f) || (f > 1300 && f % 40 < 3); m.joyRight = f > 1300 && f % 100 < 60 }
        }
        for f in 0..<1300 { p.frame(input(f)) }
        var saved: Data?
        p.rt.saveRequest = { saved = $0 }
        for f in 1300..<1302 { p.frame(input(f)) }
        let state = try #require(saved)
        for f in 1302..<1600 { p.frame(input(f)) }
        let after = fnv(UnsafeBufferPointer(start: p.rt.machine.chip, count: Machine.chipSize))
        p.rt.pendingLoad = state
        // the save was taken during frame 1300 or 1301; loading rewinds there
        p.frame(input(1300))
        let resumedAt = p.rt.machine.frame
        #expect(resumedAt <= 1302, "the load must rewind to the saved frame")
        for f in resumedAt..<1600 { p.frame(input(f)) }
        let again = fnv(UnsafeBufferPointer(start: p.rt.machine.chip, count: Machine.chipSize))
        #expect(p.error == nil)
        #expect(after == again)
    }
}
