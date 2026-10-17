import M68K

/// Static 68000 decoder used by the translator. Covers the MC68000 instruction
/// set only (no 68010+ opcodes), mirroring the interpreter in M68K/Execute.swift.

public enum Operand: Equatable {
    case d(Int)
    case a(Int)
    case ind(Int)
    case post(Int)
    case pre(Int)
    case disp(Int, Int32, ext: UInt32)            // (d16,An); ext = address of the extension word
    case idx(Int, Int32, xr: Int, xa: Bool, xl: Bool)
    case absW(UInt32)
    case absL(UInt32, ext: UInt32)
    case pcDisp(UInt32)                           // resolved absolute address
    case pcIdx(UInt32, xr: Int, xa: Bool, xl: Bool)   // resolved base (pc + d8)
    case imm(UInt32, ext: UInt32)
}

public enum Kind: Equatable {
    // data movement
    case move, movea, moveq, lea, pea, clr, exg, swap, ext, movemToMem, movemToReg, movep, link, unlk
    case moveFromSR, moveToCCR, moveToSR, moveUSPfrom, moveUSPto
    // arithmetic / logic
    case add, adda, addq, addx, sub, suba, subq, subx, neg, negx, cmp, cmpa, cmpm, tst
    case and, or, eor, not, mulu, muls, divu, divs, abcd, sbcd, nbcd, tas, chk
    case addi, subi, andi, ori, eori, cmpi
    case andiCCR, oriCCR, eoriCCR, andiSR, oriSR, eoriSR
    case btst, bchg, bclr, bset
    case asl, asr, lsl, lsr, rol, ror, roxl, roxr
    // control
    case bra, bsr, bcc, dbcc, scc, jmp, jsr, rts, rte, rtr, trap, trapv, nop, stop, reset, illegal
}

public struct Instr {
    public let addr: UInt32
    public let length: Int
    public let opcode: UInt16
    public let kind: Kind
    public var size: Size = .word
    public var src: Operand? = nil
    public var dst: Operand? = nil
    public var cond: Int = 0          // Bcc/DBcc/Scc
    public var target: UInt32 = 0     // branch target
    public var quick: UInt32 = 0      // ADDQ/SUBQ/MOVEQ data, shift count, TRAP vector
    public var countReg: Int? = nil   // shift count register
    public var regMask: UInt16 = 0    // MOVEM
    public var reg: Int = 0           // Dn / An operand (many forms)
    public var reg2: Int = 0
    public var memoryForm = false     // ADDX/SUBX/ABCD/SBCD -(Ay),-(Ax); shift memory form

    public var next: UInt32 { addr &+ UInt32(length) }
    public var text: String { Disasm.text(self) }
}

public struct DecodeError: Error, CustomStringConvertible {
    public let addr: UInt32, opcode: UInt16
    public var description: String { String(format: "cannot decode $%04X at $%06X", opcode, addr) }
}

public struct Decoder {
    let read16: (UInt32) -> UInt16
    public init(read16: @escaping (UInt32) -> UInt16) { self.read16 = read16 }

    struct Cursor {
        var pc: UInt32
        let r: (UInt32) -> UInt16
        mutating func w() -> UInt32 { let v = UInt32(r(pc)); pc &+= 2; return v }
        mutating func l() -> UInt32 { let hi = w(); return hi << 16 | w() }
    }

    func ea(_ mode: Int, _ reg: Int, _ s: Size, _ c: inout Cursor) -> Operand? {
        switch mode {
        case 0: return .d(reg)
        case 1: return .a(reg)
        case 2: return .ind(reg)
        case 3: return .post(reg)
        case 4: return .pre(reg)
        case 5: let at = c.pc; return .disp(reg, Int32(Int16(truncatingIfNeeded: c.w())), ext: at)
        case 6:
            let e = c.w()
            return .idx(reg, Int32(Int8(truncatingIfNeeded: e)), xr: Int(e >> 12) & 7, xa: e & 0x8000 != 0, xl: e & 0x800 != 0)
        default:
            switch reg {
            case 0: return .absW(UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: c.w()))))
            case 1: let at = c.pc; return .absL(c.l(), ext: at)
            case 2: let base = c.pc; return .pcDisp(base &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: c.w()))))
            case 3:
                let base = c.pc
                let e = c.w()
                return .pcIdx(base &+ UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: e))), xr: Int(e >> 12) & 7, xa: e & 0x8000 != 0, xl: e & 0x800 != 0)
            case 4:
                let at = c.pc
                if s == .long { return .imm(c.l(), ext: at) }
                let w = c.w()
                return .imm(s == .byte ? w & 0xff : w, ext: at)
            default: return nil
            }
        }
    }

    static func sz(_ v: Int) -> Size? { v == 0 ? .byte : v == 1 ? .word : v == 2 ? .long : nil }

    public func decode(_ addr: UInt32) throws -> Instr {
        var c = Cursor(pc: addr, r: read16)
        let op = Int(c.w())
        func fail() -> DecodeError { DecodeError(addr: addr, opcode: UInt16(op)) }
        func mk(_ k: Kind) -> Instr { Instr(addr: addr, length: 0, opcode: UInt16(op), kind: k) }
        func done(_ i: Instr) -> Instr {
            var j = Instr(addr: addr, length: Int(c.pc &- addr), opcode: UInt16(op), kind: i.kind)
            j.size = i.size; j.src = i.src; j.dst = i.dst; j.cond = i.cond; j.target = i.target; j.quick = i.quick
            j.countReg = i.countReg; j.regMask = i.regMask; j.reg = i.reg; j.reg2 = i.reg2; j.memoryForm = i.memoryForm
            return j
        }
        let mode = (op >> 3) & 7, reg = op & 7
        let dataAlterable = mode != 1 && !(mode == 7 && reg > 1)
        let control = mode == 2 || mode == 5 || mode == 6 || (mode == 7 && reg <= 3)

        switch op >> 12 {
        case 0x0:
            if op & 0x100 != 0 && mode == 1 {
                var i = mk(.movep); i.reg = (op >> 9) & 7; i.reg2 = reg
                i.size = (op >> 6) & 1 == 0 ? .word : .long
                i.quick = UInt32((op >> 7) & 1)          // 1 = register to memory
                i.src = .disp(reg, Int32(Int16(truncatingIfNeeded: c.w())), ext: addr + 2)
                return done(i)
            }
            if op & 0x100 != 0 || (op >> 8) & 0xf == 8 {
                let kinds: [Kind] = [.btst, .bchg, .bclr, .bset]
                var i = mk(kinds[(op >> 6) & 3])
                if op & 0x100 != 0 { i.countReg = (op >> 9) & 7 } else { i.quick = c.w() & 0xff }
                if mode == 1 { throw fail() }
                if i.kind != .btst && mode == 7 && reg >= 2 { throw fail() }
                i.size = mode == 0 ? .long : .byte
                guard let d = ea(mode, reg, .byte, &c) else { throw fail() }
                i.dst = d
                return done(i)
            }
            let k = (op >> 9) & 7
            guard let s = Decoder.sz((op >> 6) & 3) else { throw fail() }
            if mode == 7 && reg == 4 {
                guard s != .long else { throw fail() }
                let imm = c.w() & (s == .byte ? 0xff : 0xffff)
                var i: Instr
                switch (k, s) {
                case (0, .byte): i = mk(.oriCCR)
                case (1, .byte): i = mk(.andiCCR)
                case (5, .byte): i = mk(.eoriCCR)
                case (0, .word): i = mk(.oriSR)
                case (1, .word): i = mk(.andiSR)
                case (5, .word): i = mk(.eoriSR)
                default: throw fail()
                }
                i.quick = imm; i.size = s
                return done(i)
            }
            let kinds: [Int: Kind] = [0: .ori, 1: .andi, 2: .subi, 3: .addi, 5: .eori, 6: .cmpi]
            guard let kind = kinds[k], mode != 1 else { throw fail() }
            var i = mk(kind); i.size = s
            let at = c.pc
            i.src = .imm(s == .long ? c.l() : (c.w() & s.mask), ext: at)
            if kind != .cmpi && !dataAlterable { throw fail() }
            guard let d = ea(mode, reg, s, &c) else { throw fail() }
            i.dst = d
            return done(i)

        case 0x1, 0x2, 0x3:
            let s: Size = op >> 12 == 1 ? .byte : (op >> 12 == 3 ? .word : .long)
            if s == .byte && mode == 1 { throw fail() }
            guard let src = ea(mode, reg, s, &c) else { throw fail() }
            let dm = (op >> 6) & 7, dr = (op >> 9) & 7
            if dm == 1 {
                if s == .byte { throw fail() }
                var i = mk(.movea); i.size = s; i.src = src; i.dst = .a(dr)
                return done(i)
            }
            if dm == 7 && dr > 1 { throw fail() }
            guard let dst = ea(dm, dr, s, &c) else { throw fail() }
            var i = mk(.move); i.size = s; i.src = src; i.dst = dst
            return done(i)

        case 0x4:
            if op & 0x1c0 == 0x1c0 {
                guard control else { throw fail() }
                var i = mk(.lea); i.size = .long; i.src = ea(mode, reg, .long, &c); i.dst = .a((op >> 9) & 7)
                return done(i)
            }
            if op & 0x1c0 == 0x180 {
                if mode == 1 { throw fail() }
                var i = mk(.chk); i.size = .word; i.src = ea(mode, reg, .word, &c); i.reg = (op >> 9) & 7
                return done(i)
            }
            switch op & 0xfff {
            case 0xe70: return done(mk(.reset))
            case 0xe71: return done(mk(.nop))
            case 0xe72: var i = mk(.stop); i.quick = c.w(); return done(i)
            case 0xe73: return done(mk(.rte))
            case 0xe75: return done(mk(.rts))
            case 0xe76: return done(mk(.trapv))
            case 0xe77: return done(mk(.rtr))
            case 0xafc: return done(mk(.illegal))
            default: break
            }
            switch (op >> 6) & 0x3f {
            case 0x03:
                guard dataAlterable else { throw fail() }
                var i = mk(.moveFromSR); i.size = .word; i.dst = ea(mode, reg, .word, &c); return done(i)
            case 0x13:
                if mode == 1 { throw fail() }
                var i = mk(.moveToCCR); i.size = .word; i.src = ea(mode, reg, .word, &c); return done(i)
            case 0x1b:
                if mode == 1 { throw fail() }
                var i = mk(.moveToSR); i.size = .word; i.src = ea(mode, reg, .word, &c); return done(i)
            case 0x20:
                guard dataAlterable else { throw fail() }
                var i = mk(.nbcd); i.size = .byte; i.dst = ea(mode, reg, .byte, &c); return done(i)
            case 0x21:
                if mode == 0 { var i = mk(.swap); i.reg = reg; i.size = .long; return done(i) }
                guard control else { throw fail() }
                var i = mk(.pea); i.size = .long; i.src = ea(mode, reg, .long, &c); return done(i)
            case 0x22, 0x23:
                if mode == 0 { var i = mk(.ext); i.reg = reg; i.size = op & 0x40 == 0 ? .word : .long; return done(i) }
                guard mode == 2 || mode == 4 || (mode >= 5 && !(mode == 7 && reg >= 2)) else { throw fail() }
                var i = mk(.movemToMem); i.size = op & 0x40 != 0 ? .long : .word
                i.regMask = UInt16(c.w())
                i.dst = mode == 4 ? .pre(reg) : ea(mode, reg, i.size, &c)
                return done(i)
            case 0x2b:
                guard dataAlterable else { throw fail() }
                var i = mk(.tas); i.size = .byte; i.dst = ea(mode, reg, .byte, &c); return done(i)
            case 0x32, 0x33:
                guard mode == 2 || mode == 3 || (mode >= 5 && !(mode == 7 && reg == 4)) else { throw fail() }
                var i = mk(.movemToReg); i.size = op & 0x40 != 0 ? .long : .word
                i.regMask = UInt16(c.w())
                i.src = mode == 3 ? .post(reg) : ea(mode, reg, i.size, &c)
                return done(i)
            case 0x39:
                switch mode {
                case 0, 1: var i = mk(.trap); i.quick = UInt32(op & 15); return done(i)
                case 2: var i = mk(.link); i.reg = reg; i.quick = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: c.w()))); return done(i)
                case 3: var i = mk(.unlk); i.reg = reg; return done(i)
                case 4: var i = mk(.moveUSPto); i.reg = reg; return done(i)
                case 5: var i = mk(.moveUSPfrom); i.reg = reg; return done(i)
                default: throw fail()
                }
            case 0x3a:
                guard control else { throw fail() }
                var i = mk(.jsr); i.src = ea(mode, reg, .long, &c); return done(i)
            case 0x3b:
                guard control else { throw fail() }
                var i = mk(.jmp); i.src = ea(mode, reg, .long, &c); return done(i)
            default: break
            }
            guard let s = Decoder.sz((op >> 6) & 3), mode != 1 else { throw fail() }
            let k = (op >> 9) & 7
            let kinds: [Int: Kind] = [0: .negx, 1: .clr, 2: .neg, 3: .not, 5: .tst]
            guard let kind = kinds[k] else { throw fail() }
            if kind != .tst && !dataAlterable { throw fail() }
            var i = mk(kind); i.size = s
            guard let d = ea(mode, reg, s, &c) else { throw fail() }
            i.dst = d
            return done(i)

        case 0x5:
            if (op >> 6) & 3 == 3 {
                if mode == 1 {
                    var i = mk(.dbcc); i.cond = (op >> 8) & 15; i.reg = reg
                    let base = c.pc
                    i.target = base &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: c.w())))
                    return done(i)
                }
                guard dataAlterable else { throw fail() }
                var i = mk(.scc); i.cond = (op >> 8) & 15; i.size = .byte; i.dst = ea(mode, reg, .byte, &c)
                return done(i)
            }
            guard let s = Decoder.sz((op >> 6) & 3) else { throw fail() }
            if mode == 7 && reg > 1 { throw fail() }
            if mode == 1 && s == .byte { throw fail() }
            var i = mk(op & 0x100 != 0 ? .subq : .addq); i.size = s
            i.quick = UInt32((op >> 9) & 7); if i.quick == 0 { i.quick = 8 }
            i.dst = ea(mode, reg, s, &c)
            return done(i)

        case 0x6:
            let cnd = (op >> 8) & 15
            var disp = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: op)))
            let base = c.pc
            if op & 0xff == 0 { disp = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: c.w()))) }
            var i = mk(cnd == 0 ? .bra : cnd == 1 ? .bsr : .bcc)
            i.cond = cnd; i.target = base &+ disp
            return done(i)

        case 0x7:
            if op & 0x100 != 0 { throw fail() }
            var i = mk(.moveq); i.size = .long; i.reg = (op >> 9) & 7
            i.quick = UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: op)))
            return done(i)

        case 0x8, 0xC:
            let isC = op >> 12 == 0xC
            let dr = (op >> 9) & 7
            if isC {
                switch (op >> 3) & 0x3f {
                case 0x28: var i = mk(.exg); i.reg = dr; i.reg2 = reg; i.quick = 0; return done(i)
                case 0x29: var i = mk(.exg); i.reg = dr; i.reg2 = reg; i.quick = 1; return done(i)
                case 0x31: var i = mk(.exg); i.reg = dr; i.reg2 = reg; i.quick = 2; return done(i)
                default: break
                }
            }
            switch (op >> 6) & 7 {
            case 3, 7:
                if mode == 1 { throw fail() }
                let signed = op & 0x100 != 0
                var i = mk(isC ? (signed ? .muls : .mulu) : (signed ? .divs : .divu))
                i.size = .word; i.reg = dr; i.src = ea(mode, reg, .word, &c)
                if i.src == nil { throw fail() }
                return done(i)
            case 4 where mode < 2:
                var i = mk(isC ? .abcd : .sbcd); i.size = .byte; i.reg = dr; i.reg2 = reg; i.memoryForm = mode == 1
                return done(i)
            default: break
            }
            guard let s = Decoder.sz((op >> 6) & 3), mode != 1 else { throw fail() }
            var i = mk(isC ? .and : .or); i.size = s; i.reg = dr
            if op & 0x100 == 0 { i.src = ea(mode, reg, s, &c); i.dst = .d(dr); if i.src == nil { throw fail() } }
            else {
                guard dataAlterable, mode >= 2 else { throw fail() }
                i.src = .d(dr); i.dst = ea(mode, reg, s, &c)
            }
            return done(i)

        case 0x9, 0xD:
            let add = op >> 12 == 0xD
            let dr = (op >> 9) & 7
            let opm = (op >> 6) & 7
            if opm == 3 || opm == 7 {
                let s: Size = opm == 3 ? .word : .long
                var i = mk(add ? .adda : .suba); i.size = s; i.src = ea(mode, reg, s, &c); i.dst = .a(dr)
                if i.src == nil { throw fail() }
                return done(i)
            }
            guard let s = Decoder.sz(opm & 3) else { throw fail() }
            if opm >= 4 && mode < 2 {
                var i = mk(add ? .addx : .subx); i.size = s; i.reg = dr; i.reg2 = reg; i.memoryForm = mode == 1
                return done(i)
            }
            var i = mk(add ? .add : .sub); i.size = s; i.reg = dr
            if opm < 4 {
                if s == .byte && mode == 1 { throw fail() }
                i.src = ea(mode, reg, s, &c); i.dst = .d(dr)
                if i.src == nil { throw fail() }
            } else {
                guard dataAlterable else { throw fail() }
                i.src = .d(dr); i.dst = ea(mode, reg, s, &c)
            }
            return done(i)

        case 0xB:
            let dr = (op >> 9) & 7
            let opm = (op >> 6) & 7
            if opm == 3 || opm == 7 {
                let s: Size = opm == 3 ? .word : .long
                var i = mk(.cmpa); i.size = s; i.src = ea(mode, reg, s, &c); i.dst = .a(dr)
                if i.src == nil { throw fail() }
                return done(i)
            }
            guard let s = Decoder.sz(opm & 3) else { throw fail() }
            if opm < 4 {
                if s == .byte && mode == 1 { throw fail() }
                var i = mk(.cmp); i.size = s; i.src = ea(mode, reg, s, &c); i.dst = .d(dr)
                if i.src == nil { throw fail() }
                return done(i)
            }
            if mode == 1 {
                var i = mk(.cmpm); i.size = s; i.src = .post(reg); i.dst = .post(dr); return done(i)
            }
            guard dataAlterable else { throw fail() }
            var i = mk(.eor); i.size = s; i.reg = dr; i.src = .d(dr); i.dst = ea(mode, reg, s, &c)
            return done(i)

        case 0xE:
            let kinds: [[Kind]] = [[.asr, .asl], [.lsr, .lsl], [.roxr, .roxl], [.ror, .rol]]
            let left = op & 0x100 != 0 ? 1 : 0
            if (op >> 6) & 3 == 3 {
                if mode < 2 || (mode == 7 && reg > 1) || op & 0x800 != 0 { throw fail() }
                var i = mk(kinds[(op >> 9) & 3][left]); i.size = .word; i.memoryForm = true
                i.dst = ea(mode, reg, .word, &c); i.quick = 1
                return done(i)
            }
            guard let s = Decoder.sz((op >> 6) & 3) else { throw fail() }
            var i = mk(kinds[(op >> 3) & 3][left]); i.size = s; i.reg = reg
            if op & 0x20 != 0 { i.countReg = (op >> 9) & 7 } else { i.quick = UInt32((op >> 9) & 7); if i.quick == 0 { i.quick = 8 } }
            i.dst = .d(reg)
            return done(i)

        default:
            throw fail()   // line A / line F
        }
    }
}

public enum Disasm {
    static let cc = ["t", "f", "hi", "ls", "cc", "cs", "ne", "eq", "vc", "vs", "pl", "mi", "ge", "lt", "gt", "le"]
    static func hex(_ v: UInt32) -> String { String(format: "$%X", v) }
    static func x(_ r: Int, _ a: Bool, _ l: Bool) -> String { "\(a ? "a" : "d")\(r).\(l ? "l" : "w")" }
    public static func op(_ o: Operand) -> String {
        switch o {
        case .d(let r): return "d\(r)"
        case .a(let r): return r == 7 ? "sp" : "a\(r)"
        case .ind(let r): return "(a\(r))"
        case .post(let r): return "(a\(r))+"
        case .pre(let r): return "-(a\(r))"
        case .disp(let r, let d, _): return "\(d)(a\(r))"
        case .idx(let r, let d, let xr, let xa, let xl): return "\(d)(a\(r),\(x(xr, xa, xl)))"
        case .absW(let a): return hex(a) + ".w"
        case .absL(let a, _): return hex(a)
        case .pcDisp(let a): return "\(hex(a))(pc)"
        case .pcIdx(let a, let xr, let xa, let xl): return "\(hex(a))(pc,\(x(xr, xa, xl)))"
        case .imm(let v, _): return "#" + hex(v)
        }
    }
    public static func text(_ i: Instr) -> String {
        let sfx = i.size == .byte ? ".b" : i.size == .word ? ".w" : ".l"
        var name = "\(i.kind)"
        switch i.kind {
        case .bcc: name = "b" + cc[i.cond]
        case .dbcc: name = "db" + cc[i.cond]
        case .scc: name = "s" + cc[i.cond]
        default: break
        }
        var ops = [String]()
        switch i.kind {
        case .bra, .bsr, .bcc: ops = [hex(i.target)]
        case .dbcc: ops = ["d\(i.reg)", hex(i.target)]
        case .moveq: ops = ["#\(Int32(bitPattern: i.quick))", "d\(i.reg)"]
        case .addq, .subq: ops = ["#\(i.quick)"] + [i.dst.map(op) ?? ""]
        case .swap, .ext: ops = ["d\(i.reg)"]
        case .trap: ops = ["#\(i.quick)"]
        case .link: ops = ["a\(i.reg)", "#\(Int32(bitPattern: i.quick))"]
        case .unlk: ops = ["a\(i.reg)"]
        case .movemToMem: ops = [String(format: "#$%04X", i.regMask), i.dst.map(op) ?? ""]
        case .movemToReg: ops = [i.src.map(op) ?? "", String(format: "#$%04X", i.regMask)]
        case .asl, .asr, .lsl, .lsr, .rol, .ror, .roxl, .roxr:
            ops = i.memoryForm ? [i.dst.map(op) ?? ""] : [i.countReg.map { "d\($0)" } ?? "#\(i.quick)", "d\(i.reg)"]
        case .btst, .bchg, .bclr, .bset: ops = [i.countReg.map { "d\($0)" } ?? "#\(i.quick)", i.dst.map(op) ?? ""]
        case .abcd, .sbcd, .addx, .subx: ops = i.memoryForm ? ["-(a\(i.reg2))", "-(a\(i.reg))"] : ["d\(i.reg2)", "d\(i.reg)"]
        case .exg: ops = ["r\(i.reg)", "r\(i.reg2)"]
        case .andiCCR, .oriCCR, .eoriCCR, .andiSR, .oriSR, .eoriSR, .stop: ops = [String(format: "#$%X", i.quick)]
        case .mulu, .muls, .divu, .divs, .chk: ops = [i.src.map(op) ?? "", "d\(i.reg)"]
        default:
            if let s = i.src { ops.append(op(s)) }
            if let d = i.dst { ops.append(op(d)) }
        }
        return name + sfx + " " + ops.joined(separator: ",")
    }
}
