import Foundation
import M68K

/// Minimal binary snapshot of the whole machine (CPU registers, chip RAM and
/// every chip's internal state) for save states.
public struct StateWriter {
    public private(set) var data = Data()
    public init() {}
    public mutating func int(_ v: Int) { var x = Int64(v).littleEndian; data.append(Data(bytes: &x, count: 8)) }
    public mutating func u32(_ v: UInt32) { int(Int(v)) }
    public mutating func bool(_ v: Bool) { int(v ? 1 : 0) }
    public mutating func bytes(_ p: UnsafeRawBufferPointer) { int(p.count); data.append(contentsOf: p) }
}

public struct StateReader {
    let data: Data
    var pos = 0
    public init(_ d: Data) { data = d }
    public mutating func int() throws -> Int {
        guard pos + 8 <= data.count else { throw StateError(message: "truncated state") }
        var x: Int64 = 0
        _ = withUnsafeMutableBytes(of: &x) { data.copyBytes(to: $0, from: data.startIndex + pos ..< data.startIndex + pos + 8) }
        pos += 8
        return Int(Int64(littleEndian: x))
    }
    public mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try int()) }
    public mutating func bool() throws -> Bool { try int() != 0 }
    public mutating func bytes(into p: UnsafeMutableRawBufferPointer) throws {
        let n = try int()
        guard n == p.count, pos + n <= data.count else { throw StateError(message: "state size mismatch") }
        data.copyBytes(to: p, from: data.startIndex + pos ..< data.startIndex + pos + n)
        pos += n
    }
}

extension CIA {
    func save(_ w: inout StateWriter) {
        for v in [pra, prb, ddra, ddrb, portAIn, portBIn, cra, crb, icrMask, icrData, sdr] { w.int(Int(v)) }
        for v in [ta, tb, taLatch, tbLatch] { w.int(Int(v)) }
        w.u32(tod); w.u32(alarm); w.bool(todHalted)
    }
    func load(_ r: inout StateReader) throws {
        pra = UInt8(try r.int()); prb = UInt8(try r.int()); ddra = UInt8(try r.int()); ddrb = UInt8(try r.int())
        portAIn = UInt8(try r.int()); portBIn = UInt8(try r.int()); cra = UInt8(try r.int()); crb = UInt8(try r.int())
        icrMask = UInt8(try r.int()); icrData = UInt8(try r.int()); sdr = UInt8(try r.int())
        ta = UInt16(try r.int()); tb = UInt16(try r.int()); taLatch = UInt16(try r.int()); tbLatch = UInt16(try r.int())
        tod = try r.u32(); alarm = try r.u32(); todHalted = try r.bool()
    }
}

extension Paula {
    func save(_ w: inout StateWriter) {
        for c in ch {
            w.bool(c.on); w.u32(c.pt); w.int(c.len); w.int(c.counter); w.int(Int(c.word)); w.int(c.half); w.int(Int(c.sample)); w.bool(c.started)
        }
        w.int(outAcc); w.int(ccCarry)
    }
    func load(_ r: inout StateReader) throws {
        for i in 0..<4 {
            ch[i].on = try r.bool(); ch[i].pt = try r.u32(); ch[i].len = try r.int(); ch[i].counter = try r.int()
            ch[i].word = UInt16(try r.int()); ch[i].half = try r.int(); ch[i].sample = Int8(try r.int()); ch[i].started = try r.bool()
        }
        outAcc = try r.int(); ccCarry = try r.int()
    }
}

extension Video {
    func save(_ w: inout StateWriter) {
        for s in sprites { for v in [s.pos, s.ctl, s.dataA, s.dataB] { w.int(Int(v)) }; w.bool(s.armed); w.int(s.dmaState) }
    }
    func load(_ r: inout StateReader) throws {
        for i in 0..<8 {
            sprites[i].pos = UInt16(try r.int()); sprites[i].ctl = UInt16(try r.int())
            sprites[i].dataA = UInt16(try r.int()); sprites[i].dataB = UInt16(try r.int())
            sprites[i].armed = try r.bool(); sprites[i].dmaState = try r.int()
        }
    }
}

extension Machine {
    public static let stateVersion = 1

    public func saveState() -> Data {
        var w = StateWriter()
        w.int(Machine.stateVersion)
        let c = cpu
        for v in c.d { w.u32(v) }
        for v in c.a { w.u32(v) }
        w.u32(c.pc); w.int(Int(c.sr)); w.u32(c.usp); w.u32(c.ssp); w.int(c.cycles); w.bool(c.stopped); w.int(c.ipl)
        w.bytes(UnsafeRawBufferPointer(start: chip, count: Machine.chipSize))
        custom.withUnsafeBytes { w.bytes($0) }
        w.int(vpos); w.int(frame); w.int(lineStartCycle); w.int(eClockRemainder); w.int(blitBusyUntil); w.bool(blitZero)
        w.int(blitCount); w.u32(copper.pc); w.bool(copper.waiting)
        for v in [copper.waitV, copper.waitH, copper.waitMaskV, copper.waitMaskH] { w.int(v) }
        w.int(eventCycle)
        ciaA.save(&w); ciaB.save(&w); paula.save(&w); video.save(&w)
        return w.data
    }

    public func loadState(_ data: Data) throws {
        var r = StateReader(data)
        guard try r.int() == Machine.stateVersion else { throw StateError(message: "unsupported save state version") }
        let c = cpu
        for k in 0..<8 { c.d[k] = try r.u32() }
        for k in 0..<8 { c.a[k] = try r.u32() }
        c.pc = try r.u32(); c.sr = UInt16(try r.int()); c.usp = try r.u32(); c.ssp = try r.u32()
        c.cycles = try r.int(); c.stopped = try r.bool(); c.ipl = try r.int()
        try r.bytes(into: UnsafeMutableRawBufferPointer(start: chip, count: Machine.chipSize))
        try custom.withUnsafeMutableBytes { try r.bytes(into: $0) }
        vpos = try r.int(); frame = try r.int(); lineStartCycle = try r.int(); eClockRemainder = try r.int()
        blitBusyUntil = try r.int(); blitZero = try r.bool(); blitCount = try r.int()
        copper.pc = try r.u32(); copper.waiting = try r.bool()
        copper.waitV = try r.int(); copper.waitH = try r.int(); copper.waitMaskV = try r.int(); copper.waitMaskH = try r.int()
        eventCycle = try r.int()
        try ciaA.load(&r); try ciaB.load(&r); try paula.load(&r); try video.load(&r)
        keyQueue.removeAll()
    }
}

public struct StateError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
