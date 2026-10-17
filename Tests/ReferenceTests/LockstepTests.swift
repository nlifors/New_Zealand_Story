import Testing
import Foundation
import NZSCore
import NZSReference
import NZSGame
import AmigaEmu

/// The translated port against the reference interpreter over the whole game:
/// cheat typed on the title screen, then the developer HELP key skips each
/// level, through the map screens, the bosses and the ending back to the title.
@Suite(.enabled(if: RefFixture.available, "needs the ADF"), .serialized)
struct LockstepTests {
    static let cheat: [UInt8] = [0x37, 0x18, 0x14, 0x25, 0x12, 0x13, 0x23, 0x16, 0x33, 0x27, 0x12, 0x36,
                                 0x27, 0x17, 0x11, 0x17, 0x35, 0x20, 0x21, 0x14, 0x20, 0x13, 0x22]  // raw keys of the cheat

    @Test func wholeGameTraversalMatchesReference() throws {
        let disk = try DiskImage(contentsOf: URL(fileURLWithPath: RefFixture.path))
        let ref = try OriginalGame(disk: disk)
        let port = try PortDriver()
        var typed = LockstepTests.cheat.flatMap { [$0, $0 | 0x80] }
        var firstDifference: String?
        for f in 0..<11_000 {
            var keys = [UInt8]()
            if f >= 260 && !typed.isEmpty && f % 2 == 0 { keys.append(typed.removeFirst()) }
            if f > 1400 && f % 400 == 0 { keys.append(0x5f) }
            if f > 1400 && f % 400 == 3 { keys.append(0xdf) }
            let fire = (400...402).contains(f)
            ref.machine.joyFire = fire
            ref.machine.keyQueue += keys
            ref.machine.runFrame()
            port.frame { m in m.joyFire = fire; m.keyQueue += keys }
            #expect(port.error == nil)
            if f % 100 == 99 {
                let a = ref.machine, b = port.rt.machine
                let same = a.cpu.cycles == b.cpu.cycles && a.cpu.d == b.cpu.d && a.cpu.a == b.cpu.a &&
                    memcmp(a.chip, b.chip, Machine.chipSize) == 0 && a.custom == b.custom
                if !same { firstDifference = "frame \(f)"; break }
            }
        }
        #expect(firstDifference == nil, "port diverged from the reference at \(firstDifference ?? "")")
        #expect(ref.machine.read16(0x641b8 + 8) == 0)          // back at level 0 after the ending
        // Pinned: changes when the hardware model or translation changes behaviour.
        // Re-pin deliberately (and say why) if such a change is intended.
        let fp = fnv(UnsafeBufferPointer(start: port.rt.machine.chip, count: Machine.chipSize))
        #expect(fp == 0x45e5d5b273949a38, "traversal end fingerprint \(String(fp, radix: 16))")
    }
}
