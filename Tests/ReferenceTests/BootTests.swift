import Testing
import Foundation
import NZSCore
import NZSReference
import AmigaEmu

enum RefFixture {
    static let path: String = {
        if let p = ProcessInfo.processInfo.environment["NZS_ADF"] { return p }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Newzealand Story.adf").path
    }()
    static let available = FileManager.default.fileExists(atPath: path)
}

func fnv<S: Sequence>(_ s: S) -> UInt64 where S.Element == UInt8 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// Runs the original game in the reference emulator. These pin the emulator's
/// behaviour so regressions show up; they are not proof of hardware accuracy.
@Suite(.enabled(if: RefFixture.available, "needs the ADF"))
struct BootTests {
    @Test func bootsToTitleAndStartsLevel1() throws {
        let game = try OriginalGame(disk: DiskImage(contentsOf: URL(fileURLWithPath: RefFixture.path)))
        let m = game.machine
        for f in 0..<1200 {
            m.joyFire = (400...402).contains(f)
            m.runFrame()
            #expect(m.faults.isEmpty)
            #expect(!m.resetRequested)
        }
        #expect(game.loads.map { "\($0.track)x\($0.count)@\(String($0.dest, radix: 16))" } ==
                ["91x3@70000", "94x50@400", "2x5@3caa6", "18x1@44aa6"])
        // the level-1 frame is stable: pin its colour-index fingerprint
        // (re-pinned 2026-10-14 after modelling the blitter CPU stall;
        //  2026-10-15 after the lowres BPLCON1 shifter-load model)
        let fp = fnv(m.video.lastIndices)
        print("level-1 frame fingerprint:", String(fp, radix: 16))
        #expect(fp == 0x79911de6728383c4)
    }
}
