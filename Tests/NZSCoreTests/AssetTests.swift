import Testing
import Foundation
@testable import NZSCore

/// The tests need the user's ADF; it is never committed. Set NZS_ADF or keep
/// "Newzealand Story.adf" in the package root. Without it the tests are skipped.
enum Fixture {
    static let path: String = {
        if let p = ProcessInfo.processInfo.environment["NZS_ADF"] { return p }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Newzealand Story.adf").path
    }()
    static let available = FileManager.default.fileExists(atPath: path)
    static let data: GameData? = available ? try? GameData(disk: DiskImage(contentsOf: URL(fileURLWithPath: path))) : nil
}

/// FNV-1a fingerprint, used to pin decoded output.
func fingerprint<S: Sequence>(_ s: S) -> UInt64 where S.Element == UInt8 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

@Suite(.enabled(if: Fixture.available, "needs the ADF"))
struct AssetTests {
    let data = Fixture.data!

    @Test func bootChainDecrunchesExactly() throws {
        let f = try GameDisk.launcherFile(data.disk)
        #expect(f.count == 0x29e4)           // consumes input exactly (checked inside)
        let l = try GameDisk.launcher(data.disk)
        #expect(Array(l.prefix(4)) == [0x21, 0xfc, 0x00, 0x07])   // move.l #$7600C,($20).w
    }

    @Test func mainImage() {
        #expect(data.image.bytes.count == 338_855)
        #expect(data.image.u32(0x15b0 + 4) == 0x4000)  // game entry pointer (pre-relocation offset +4)
    }

    @Test func levelTable() {
        let lv = data.image.levels
        #expect(lv.count == 20)
        #expect(lv.map(\.graphicsTrack) == [2, 6, 11, 14, 22, 22, 22, 22, 29, 34, 39, 44, 52, 52, 52, 59, 70, 74, 81, 84])
        #expect(lv.map(\.mapTrack) == [18, 19, 20, 21, 25, 26, 27, 28, 48, 49, 50, 51, 56, 57, 58, 68, 79, 80, 88, 89])
        #expect((0..<5).map { data.image.bossTrack(world: $0) } == [158, 156, 154, 0, 152])
    }

    @Test func mapsAndGraphics() throws {
        let m = try data.map(level: 0)
        #expect(m.width == 64 && m.height == 14)
        let g = try data.graphicsSet(level: 0)
        #expect(g.raw.count == 22272)
        #expect(g.headerTileCount == 172)
    }

    @Test func spriteBanks() {
        let main = SpriteBank(image: data.image, name: "main", dataBase: 0x22aa6, tableBase: 0x39aa6)
        #expect(main.entries.count == 289)
        // every image's mask equals the OR of its planes (unconverted ST data, as $4E54 checks)
        #expect(main.entries.allSatisfy { $0.words > 0 && $0.lines > 0 })
        #expect(SpriteBank(image: data.image, name: "intro", dataBase: 0x3caa6, tableBase: 0x4caa6).entries.count == 15)
        #expect(data.track144Sprites().entries.count == 5)
        #expect((0..<5).map { data.bossSprites(world: $0)?.entries.count ?? 0 } == [26, 9, 21, 0, 10])
    }

    @Test func samples() {
        let s = Sample8SVX.scan(data.image)
        #expect(s.count == 18)
        #expect(s.map(\.name).prefix(4) == ["VOICE-WAVE", "PAN-MALLET", "SYNTH-BASS1", "VIBES"])
        #expect(s.allSatisfy { $0.body.count == $0.oneShot + $0.repeatLength })
    }

    @Test func pictures() throws {
        let p = try data.pictures()
        #expect(p.map(\.0) == ["loading", "zoo_intro", "track144"])
        #expect(p[0].1.palette.amiga[1] == 0xeee)
    }
}
