import M68K

/// Emits Swift for one decoded instruction. Semantics mirror M68K/Execute.swift
/// statement for statement (same side-effect order, same dummy reads), so the
/// generated code and the interpreter stay in lockstep; the per-instruction
/// differential test (ReferenceTests) checks that.
///
/// Control flow is returned separately so the caller can lay out blocks.
public enum Flow {
    case next                                    // fall through
    case goto(UInt32)                            // unconditional branch
    case cond(String, UInt32)                    // if <expr> goto target, else next
    case dbcc(UInt32)                            // emitted inline: sets `taken`
    case call(UInt32)                            // static call; return address = next
    case callDynamic(String)                     // expression giving the target
    case jumpDynamic(String)                     // computed jump (tail)
    case jumpTable(String, [UInt32])             // computed jump within known targets
    case ret                                     // RTS/RTE/RTR: statements already produced `retval`
    case trap(Int)                               // exception vector; returns to next
    case fatal(String)
}

public struct GenResult {
    public var stmts: [String]
    public var flow: Flow
    /// Extra cycles computed at run time (Swift expression) on top of `staticCycles`.
    public var dynamicCycles: String? = nil
    public var checkInterrupts = false           // SR changed: force an interrupt check
    public var spReset = false                   // SP loaded with a constant (main-loop restart)
}

public struct CodeGen {
    /// Instruction addresses whose extension words are rewritten at run time
    /// (self-modifying code); their operands are read from memory instead.
    public var dynamicOperands: Set<UInt32>
    public init(dynamicOperands: Set<UInt32>) { self.dynamicOperands = dynamicOperands }

    var tmp = 0
    mutating func t(_ base: String = "t") -> String { tmp += 1; return "\(base)\(tmp)" }

    static func mask(_ s: Size) -> String { s == .byte ? "0xff" : s == .word ? "0xffff" : "0xffff_ffff" }
    static func sz(_ s: Size) -> String { s == .byte ? ".byte" : s == .word ? ".word" : ".long" }
    static func h(_ v: UInt32) -> String { String(format: "0x%x", v) }

    enum Loc { case d(Int), a(Int), mem(String), imm(String) }

    func xreg(_ r: Int, _ isA: Bool, _ long: Bool) -> String {
        let v = isA ? "c.a[\(r)]" : "c.d[\(r)]"
        return long ? v : "CPU.sext16(\(v))"
    }

    /// Resolve an operand: emits address computation (with (An)+/-(An) side
    /// effects) and returns its location. `smc` = read extension words from memory.
    mutating func loc(_ o: Operand, _ s: Size, _ out: inout [String], smc: Bool) -> Loc {
        switch o {
        case .d(let r): return .d(r)
        case .a(let r): return .a(r)
        case .ind(let r): let v = t("ea"); out.append("let \(v) = c.a[\(r)]"); return .mem(v)
        case .post(let r):
            let v = t("ea"); let n = (s == .byte && r == 7) ? 2 : s.rawValue
            out.append("let \(v) = c.a[\(r)]; c.a[\(r)] &+= \(n)"); return .mem(v)
        case .pre(let r):
            let v = t("ea"); let n = (s == .byte && r == 7) ? 2 : s.rawValue
            out.append("c.a[\(r)] &-= \(n); let \(v) = c.a[\(r)]"); return .mem(v)
        case .disp(let r, let d, let ext):
            let v = t("ea")
            if smc { out.append("let \(v) = c.a[\(r)] &+ CPU.sext16(c.read16(\(CodeGen.h(ext))))  // self-modified displacement") }
            else { out.append("let \(v) = c.a[\(r)] &+ \(CodeGen.h(UInt32(bitPattern: d)))") }
            return .mem(v)
        case .idx(let r, let d, let xr, let xa, let xl):
            let v = t("ea")
            out.append("let \(v) = c.a[\(r)] &+ \(xreg(xr, xa, xl)) &+ \(CodeGen.h(UInt32(bitPattern: d)))")
            return .mem(v)
        case .absW(let a): return .mem(CodeGen.h(a))
        case .absL(let a, let ext):
            if smc { let v = t("ea"); out.append("let \(v) = c.read32(\(CodeGen.h(ext)))  // self-modified address"); return .mem(v) }
            return .mem(CodeGen.h(a))
        case .pcDisp(let a): return .mem(CodeGen.h(a))
        case .pcIdx(let base, let xr, let xa, let xl):
            let v = t("ea"); out.append("let \(v) = \(CodeGen.h(base)) &+ \(xreg(xr, xa, xl))"); return .mem(v)
        case .imm(let val, let ext):
            if smc {
                let rd = s == .long ? "c.read32(\(CodeGen.h(ext)))" : s == .word ? "c.read16(\(CodeGen.h(ext)))" : "(c.read16(\(CodeGen.h(ext))) & 0xff)"
                return .imm(rd)
            }
            return .imm(CodeGen.h(val & s.mask))
        }
    }

    func get(_ l: Loc, _ s: Size) -> String {
        switch l {
        case .d(let r): return s == .long ? "c.d[\(r)]" : "(c.d[\(r)] & \(CodeGen.mask(s)))"
        case .a(let r): return s == .long ? "c.a[\(r)]" : "(c.a[\(r)] & \(CodeGen.mask(s)))"
        case .mem(let e): return s == .byte ? "c.read8(\(e))" : s == .word ? "c.read16(\(e))" : "c.read32(\(e))"
        case .imm(let e): return e.hasPrefix("0x") ? "UInt32(\(e))" : e
        }
    }

    func put(_ l: Loc, _ s: Size, _ v: String) -> String {
        switch l {
        case .d(let r): return s == .long ? "c.d[\(r)] = \(v)" : "c.d[\(r)] = (c.d[\(r)] & ~\(CodeGen.mask(s))) | ((\(v)) & \(CodeGen.mask(s)))"
        case .a(let r): return "c.a[\(r)] = \(v)"
        case .mem(let e): return s == .byte ? "c.write8(\(e), \(v))" : s == .word ? "c.write16(\(e), \(v))" : "c.write32(\(e), \(v))"
        case .imm: return "/* write to immediate ignored */"
        }
    }

    func addr(_ l: Loc) -> String { if case .mem(let e) = l { return e }; return "0 /* not memory */" }

    static let condNames = ["true", "false", "hi", "ls", "cc", "cs", "ne", "eq", "vc", "vs", "pl", "mi", "ge", "lt", "gt", "le"]

    public mutating func gen(_ i: Instr) -> GenResult {
        tmp = 0
        var o = [String]()
        let s = i.size
        let S = CodeGen.sz(s)
        let smc = dynamicOperands.contains(i.addr)
        let next = CodeGen.h(i.next)
        var r = GenResult(stmts: [], flow: .next)

        switch i.kind {
        case .move:
            let src = loc(i.src!, s, &o, smc: smc)
            let v = t("v"); o.append("let \(v) = \(get(src, s))")
            let dst = loc(i.dst!, s, &o, smc: smc)
            o.append("c.setNZ(\(v), \(S))")
            o.append(put(dst, s, v))
        case .movea:
            let src = loc(i.src!, s, &o, smc: smc)
            let v = get(src, s)
            o.append(put(i.dst!.loc, .long, s == .word ? "CPU.sext16(\(v))" : v))
        case .moveq:
            o.append("c.d[\(i.reg)] = \(CodeGen.h(i.quick)); c.setNZ(\(CodeGen.h(i.quick)), .long)")
        case .lea:
            let src = loc(i.src!, .long, &o, smc: smc)
            o.append("c.a[\(i.dst!.regNum)] = \(addr(src))")
            if i.dst!.regNum == 7, case .mem(let e) = src, e.hasPrefix("0x") { r.spReset = true }
        case .pea:
            let src = loc(i.src!, .long, &o, smc: smc)
            o.append("c.push32(\(addr(src)))")
        case .clr:
            let dst = loc(i.dst!, s, &o, smc: smc)
            if case .mem(let e) = dst { o.append("_ = \(get(.mem(e), s))") }
            o.append(put(dst, s, "0"))
            o.append("c.sr = (c.sr & ~(CPU.N | CPU.V | CPU.C)) | CPU.Z")
        case .tst:
            let dst = loc(i.dst!, s, &o, smc: smc)
            o.append("c.setNZ(\(get(dst, s)), \(S))")
        case .exg:
            let (x, y): (String, String)
            switch i.quick { case 0: (x, y) = ("c.d[\(i.reg)]", "c.d[\(i.reg2)]"); case 1: (x, y) = ("c.a[\(i.reg)]", "c.a[\(i.reg2)]"); default: (x, y) = ("c.d[\(i.reg)]", "c.a[\(i.reg2)]") }
            o.append("do { let tx = \(x); \(x) = \(y); \(y) = tx }")
        case .swap:
            o.append("c.d[\(i.reg)] = (c.d[\(i.reg)] >> 16) | (c.d[\(i.reg)] << 16); c.setNZ(c.d[\(i.reg)], .long)")
        case .ext:
            if s == .word { o.append("do { let v = CPU.sext8(c.d[\(i.reg)]) & 0xffff; c.d[\(i.reg)] = (c.d[\(i.reg)] & 0xffff_0000) | v; c.setNZ(v, .word) }") }
            else { o.append("c.d[\(i.reg)] = CPU.sext16(c.d[\(i.reg)]); c.setNZ(c.d[\(i.reg)], .long)") }
        case .movemToMem:
            let n = s.rawValue
            if case .pre(let ar) = i.dst! {
                o.append("var ma: UInt32 = c.a[\(ar)]")
                o.append("let initial = c.a[\(ar)]")
                for k in 0..<16 where i.regMask & (1 << k) != 0 {
                    let rr = 15 - k
                    let v = rr < 8 ? "c.d[\(rr)]" : (rr - 8 == ar ? "initial" : "c.a[\(rr - 8)]")
                    o.append("ma &-= \(n); " + (s == .long ? "c.write32(ma, \(v))" : "c.write16(ma, \(v))"))
                }
                o.append("c.a[\(ar)] = ma")
                o.append("_ = initial")
            } else {
                let dst = loc(i.dst!, s, &o, smc: smc)
                o.append("var ma: UInt32 = \(addr(dst))")
                for k in 0..<16 where i.regMask & (1 << k) != 0 {
                    let v = k < 8 ? "c.d[\(k)]" : "c.a[\(k - 8)]"
                    o.append((s == .long ? "c.write32(ma, \(v))" : "c.write16(ma, \(v))") + "; ma &+= \(n)")
                }
                o.append("_ = ma")
            }
        case .movemToReg:
            let n = s.rawValue
            var postReg: Int? = nil
            if case .post(let ar) = i.src! { postReg = ar; o.append("var ma: UInt32 = c.a[\(ar)]") }
            else { let src = loc(i.src!, s, &o, smc: smc); o.append("var ma: UInt32 = \(addr(src))") }
            for k in 0..<16 where i.regMask & (1 << k) != 0 {
                let rd = s == .long ? "c.read32(ma)" : "CPU.sext16(c.read16(ma))"
                o.append((k < 8 ? "c.d[\(k)]" : "c.a[\(k - 8)]") + " = \(rd); ma &+= \(n)")
            }
            o.append("_ = c.read16(ma)")
            if let ar = postReg { o.append("c.a[\(ar)] = ma") }
        case .movep:
            if case .disp(let ar, let d, _) = i.src! {
                let dr = i.reg
                o.append("let ma = c.a[\(ar)] &+ \(CodeGen.h(UInt32(bitPattern: d)))")
                switch (i.quick, s) {
                case (0, .word): o.append("c.d[\(dr)] = (c.d[\(dr)] & 0xffff_0000) | c.read8(ma) << 8 | c.read8(ma &+ 2)")
                case (0, _): o.append("c.d[\(dr)] = c.read8(ma) << 24 | c.read8(ma &+ 2) << 16 | c.read8(ma &+ 4) << 8 | c.read8(ma &+ 6)")
                case (_, .word): o.append("c.write8(ma, c.d[\(dr)] >> 8); c.write8(ma &+ 2, c.d[\(dr)])")
                default: o.append("c.write8(ma, c.d[\(dr)] >> 24); c.write8(ma &+ 2, c.d[\(dr)] >> 16); c.write8(ma &+ 4, c.d[\(dr)] >> 8); c.write8(ma &+ 6, c.d[\(dr)])")
                }
            }
        case .link:
            o.append("c.push32(c.a[\(i.reg)]); c.a[\(i.reg)] = c.a[7]; c.a[7] &+= \(CodeGen.h(i.quick))")
        case .unlk:
            o.append("c.a[7] = c.a[\(i.reg)]; c.a[\(i.reg)] = c.pop32()")
        case .moveFromSR:
            let dst = loc(i.dst!, .word, &o, smc: smc)
            if case .mem(let e) = dst { o.append("_ = c.read16(\(e))") }
            o.append(put(dst, .word, "UInt32(c.sr)"))
        case .moveToCCR:
            let src = loc(i.src!, .word, &o, smc: smc)
            o.append("c.sr = (c.sr & 0xff00) | UInt16(\(get(src, .word)) & 0x1f)")
        case .moveToSR:
            let src = loc(i.src!, .word, &o, smc: smc)
            o.append("c.setSR(UInt16(\(get(src, .word))))")
            r.checkInterrupts = true
        case .moveUSPto: o.append("c.usp = c.a[\(i.reg)]")
        case .moveUSPfrom: o.append("c.a[\(i.reg)] = c.usp")
        case .andiCCR: o.append("c.sr = (c.sr & 0xff00) | UInt16((UInt32(c.sr) & \(CodeGen.h(i.quick | 0xff00))) & 0x1f)")
        case .oriCCR: o.append("c.sr = (c.sr & 0xff00) | UInt16((UInt32(c.sr) | \(CodeGen.h(i.quick))) & 0x1f)")
        case .eoriCCR: o.append("c.sr = (c.sr & 0xff00) | UInt16((UInt32(c.sr) ^ \(CodeGen.h(i.quick))) & 0x1f)")
        case .andiSR: o.append("c.setSR(UInt16(UInt32(c.sr) & \(CodeGen.h(i.quick))))"); r.checkInterrupts = true
        case .oriSR: o.append("c.setSR(UInt16(UInt32(c.sr) | \(CodeGen.h(i.quick))))"); r.checkInterrupts = true
        case .eoriSR: o.append("c.setSR(UInt16(UInt32(c.sr) ^ \(CodeGen.h(i.quick))))"); r.checkInterrupts = true

        case .ori, .andi, .eori, .subi, .addi, .cmpi:
            let imm = loc(i.src!, s, &o, smc: smc)
            let iv = t("i"); o.append("let \(iv) = \(get(imm, s))")
            let dst = loc(i.dst!, s, &o, smc: smc)
            let v = t("v"); o.append("let \(v) = \(get(dst, s))")
            switch i.kind {
            case .ori: o.append("let rr = (\(v) | \(iv)) & \(CodeGen.mask(s)); c.setNZ(rr, \(S)); " + put(dst, s, "rr"))
            case .andi: o.append("let rr = \(v) & \(iv); c.setNZ(rr, \(S)); " + put(dst, s, "rr"))
            case .eori: o.append("let rr = (\(v) ^ \(iv)) & \(CodeGen.mask(s)); c.setNZ(rr, \(S)); " + put(dst, s, "rr"))
            case .subi: o.append(put(dst, s, "c.subOp(\(v), \(iv), \(S))"))
            case .addi: o.append(put(dst, s, "c.addOp(\(v), \(iv), \(S))"))
            default: o.append("c.cmpOp(\(v), \(iv), \(S))")
            }

        case .btst, .bchg, .bclr, .bset:
            let bitExpr = i.countReg.map { "c.d[\($0)]" } ?? CodeGen.h(i.quick)
            let b = t("b"); o.append("var \(b): UInt32 = \(bitExpr)")
            if case .d(let dr) = i.dst! {
                o.append("\(b) &= 31")
                o.append("let v = c.d[\(dr)]; c.setFlag(CPU.Z, v & (1 << \(b)) == 0)")
                switch i.kind {
                case .bchg: o.append("c.d[\(dr)] = v ^ (1 << \(b))")
                case .bclr: o.append("c.d[\(dr)] = v & ~(1 << \(b))")
                case .bset: o.append("c.d[\(dr)] = v | (1 << \(b))")
                default: o.append("_ = v")
                }
            } else {
                o.append("\(b) &= 7")
                let dst = loc(i.dst!, .byte, &o, smc: smc)
                o.append("let v = \(get(dst, .byte)); c.setFlag(CPU.Z, v & (1 << \(b)) == 0)")
                switch i.kind {
                case .bchg: o.append(put(dst, .byte, "v ^ (1 << \(b))"))
                case .bclr: o.append(put(dst, .byte, "v & ~(1 << \(b))"))
                case .bset: o.append(put(dst, .byte, "v | (1 << \(b))"))
                default: o.append("_ = v")
                }
            }

        case .negx, .neg, .not:
            let dst = loc(i.dst!, s, &o, smc: smc)
            let v = get(dst, s)
            switch i.kind {
            case .negx: o.append(put(dst, s, "c.subOp(0, \(v), \(S), x: true)"))
            case .neg: o.append(put(dst, s, "c.subOp(0, \(v), \(S))"))
            default: o.append("let rr = ~\(v) & \(CodeGen.mask(s)); c.setNZ(rr, \(S)); " + put(dst, s, "rr"))
            }
        case .nbcd:
            let dst = loc(i.dst!, .byte, &o, smc: smc)
            o.append(put(dst, .byte, "c.bcdSub(0, \(get(dst, .byte)))"))
        case .tas:
            let dst = loc(i.dst!, .byte, &o, smc: smc)
            o.append("let v = \(get(dst, .byte)); c.setNZ(v, .byte); " + put(dst, .byte, "v | 0x80"))
        case .chk:
            let src = loc(i.src!, .word, &o, smc: smc)
            o.append("let bound = Int16(truncatingIfNeeded: \(get(src, .word))); let v = Int16(truncatingIfNeeded: c.d[\(i.reg)])")
            o.append("c.sr &= ~(CPU.Z | CPU.V | CPU.C); if v == 0 { c.sr |= CPU.Z }")
            o.append("if v < 0 { c.sr |= CPU.N; chkFail = true } else if v > bound { c.sr &= ~CPU.N; chkFail = true } else { c.sr &= ~CPU.N }")
            r.flow = .fatal("CHK exception path not translated")
            o.insert("var chkFail = false", at: 0)
            o.append("if chkFail { try rt.fatal(c, \"CHK failed at \(CodeGen.h(i.addr))\") }")
            r.flow = .next

        case .addq, .subq:
            if case .a(let ar) = i.dst! {
                o.append(i.kind == .subq ? "c.a[\(ar)] &-= \(i.quick)" : "c.a[\(ar)] &+= \(i.quick)")
            } else {
                let dst = loc(i.dst!, s, &o, smc: smc)
                let v = t("v"); o.append("let \(v) = \(get(dst, s))")
                o.append(put(dst, s, i.kind == .subq ? "c.subOp(\(v), \(i.quick), \(S))" : "c.addOp(\(v), \(i.quick), \(S))"))
            }

        case .add, .sub:
            let isAdd = i.kind == .add
            let fn = isAdd ? "c.addOp" : "c.subOp"
            if case .d(let dr) = i.dst!, isDestReg(i) {
                let src = loc(i.src!, s, &o, smc: smc)
                o.append("let v = \(get(src, s))")
                o.append(put(.d(dr), s, "\(fn)(c.d[\(dr)], v, \(S))"))
            } else {
                let dst = loc(i.dst!, s, &o, smc: smc)
                o.append("let v = \(get(dst, s))")
                o.append(put(dst, s, "\(fn)(v, c.d[\(i.reg)], \(S))"))
            }
        case .adda, .suba:
            let src = loc(i.src!, s, &o, smc: smc)
            o.append("var v = \(get(src, s))")
            if s == .word { o.append("v = CPU.sext16(v)") }
            let ar = i.dst!.regNum
            o.append(i.kind == .adda ? "c.a[\(ar)] = c.a[\(ar)] &+ v" : "c.a[\(ar)] = c.a[\(ar)] &- v")
            if ar == 7 { o.append("// SP adjusted") }
        case .addx, .subx:
            let fn = i.kind == .addx ? "c.addOp" : "c.subOp"
            if !i.memoryForm {
                o.append(put(.d(i.reg), s, "\(fn)(c.d[\(i.reg)], c.d[\(i.reg2)], \(S), x: true)"))
            } else {
                let st = (s == .byte && i.reg2 == 7) ? 2 : s.rawValue, dt = (s == .byte && i.reg == 7) ? 2 : s.rawValue
                o.append("c.a[\(i.reg2)] &-= \(st); let sv = \(get(.mem("c.a[\(i.reg2)]"), s))")
                o.append("c.a[\(i.reg)] &-= \(dt); let dv = \(get(.mem("c.a[\(i.reg)]"), s))")
                o.append(put(.mem("c.a[\(i.reg)]"), s, "\(fn)(dv, sv, \(S), x: true)"))
            }
        case .cmp:
            let src = loc(i.src!, s, &o, smc: smc)
            o.append("c.cmpOp(\(get(.d(i.dst!.regNum), s)), \(get(src, s)), \(S))")
        case .cmpa:
            let src = loc(i.src!, s, &o, smc: smc)
            o.append("var v = \(get(src, s))")
            if s == .word { o.append("v = CPU.sext16(v)") }
            o.append("c.cmpOp(c.a[\(i.dst!.regNum)], v, .long)")
        case .cmpm:
            let src = loc(i.src!, s, &o, smc: false)
            o.append("let sv = \(get(src, s))")
            let dst = loc(i.dst!, s, &o, smc: false)
            o.append("let dv = \(get(dst, s))")
            o.append("c.cmpOp(dv, sv, \(S))")
        case .and, .or:
            let op = i.kind == .and ? "&" : "|"
            if case .d(let dr) = i.dst!, isDestReg(i) {
                let src = loc(i.src!, s, &o, smc: smc)
                o.append("let rr = (c.d[\(dr)] \(op) \(get(src, s))) & \(CodeGen.mask(s))")
                o.append(put(.d(dr), s, "rr") + "; c.setNZ(rr, \(S))")
            } else {
                let dst = loc(i.dst!, s, &o, smc: smc)
                o.append("let rr = (\(get(dst, s)) \(op) c.d[\(i.reg)]) & \(CodeGen.mask(s))")
                o.append("c.setNZ(rr, \(S)); " + put(dst, s, "rr"))
            }
        case .eor:
            let dst = loc(i.dst!, s, &o, smc: smc)
            o.append("let rr = (\(get(dst, s)) ^ c.d[\(i.reg)]) & \(CodeGen.mask(s))")
            o.append("c.setNZ(rr, \(S)); " + put(dst, s, "rr"))
        case .mulu, .muls:
            let src = loc(i.src!, .word, &o, smc: smc)
            o.append("let sv = \(get(src, .word))")
            if i.kind == .mulu {
                o.append("let rr = (c.d[\(i.reg)] & 0xffff) &* sv")
                if !i.src!.isImmediate { r.dynamicCycles = "2 * sv.nonzeroBitCount" }
            } else {
                o.append("let rr = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: c.d[\(i.reg)])) &* Int32(Int16(truncatingIfNeeded: sv)))")
                if !i.src!.isImmediate { r.dynamicCycles = "2 * (((sv << 1) ^ sv) & 0xffff).nonzeroBitCount" }
            }
            o.append("c.d[\(i.reg)] = rr; c.setNZ(rr, .long)")
        case .divu, .divs:
            let src = loc(i.src!, .word, &o, smc: smc)
            o.append("let sv = \(get(src, .word))")
            o.append("if sv == 0 { try rt.fatal(c, \"division by zero at \(CodeGen.h(i.addr))\") }")
            o.append("c.divide(\(i.reg), sv, signed: \(i.kind == .divs))")
            r.dynamicCycles = "-(\(i.kind == .divs ? 158 : 140))"   // divide() adds its own cycles
        case .abcd, .sbcd:
            let fn = i.kind == .abcd ? "c.bcdAdd" : "c.bcdSub"
            if !i.memoryForm {
                o.append("c.d[\(i.reg)] = (c.d[\(i.reg)] & ~0xff) | \(fn)(c.d[\(i.reg)] & 0xff, c.d[\(i.reg2)] & 0xff)")
            } else {
                o.append("c.a[\(i.reg2)] &-= \(i.reg2 == 7 ? 2 : 1); let sv = c.read8(c.a[\(i.reg2)])")
                o.append("c.a[\(i.reg)] &-= \(i.reg == 7 ? 2 : 1); let dv = c.read8(c.a[\(i.reg)])")
                o.append("c.write8(c.a[\(i.reg)], \(fn)(dv, sv))")
            }

        case .asl, .asr, .lsl, .lsr, .rol, .ror, .roxl, .roxr:
            let kindNum: Int; let left: Bool
            switch i.kind {
            case .asl: (kindNum, left) = (0, true); case .asr: (kindNum, left) = (0, false)
            case .lsl: (kindNum, left) = (1, true); case .lsr: (kindNum, left) = (1, false)
            case .roxl: (kindNum, left) = (2, true); case .roxr: (kindNum, left) = (2, false)
            case .rol: (kindNum, left) = (3, true); default: (kindNum, left) = (3, false)
            }
            if i.memoryForm {
                let dst = loc(i.dst!, .word, &o, smc: smc)
                o.append(put(dst, .word, "c.shift(\(kindNum), left: \(left), \(get(dst, .word)), 1, .word)"))
            } else {
                let cnt: String
                if let cr = i.countReg { cnt = "(c.d[\(cr)] & 63)"; r.dynamicCycles = "2 * Int(cnt)" } else { cnt = "\(i.quick)" }
                o.append("let cnt: UInt32 = \(cnt)")
                o.append(put(.d(i.reg), s, "c.shift(\(kindNum), left: \(left), c.d[\(i.reg)] & \(CodeGen.mask(s)), cnt, \(S))"))
            }

        case .bra:
            r.flow = .goto(i.target)
        case .bcc:
            r.flow = .cond("c.cond(\(i.cond))", i.target)
        case .bsr:
            r.flow = .call(i.target)
        case .dbcc:
            // mirrors line5(): if cond -> fall through (12); else decrement, loop if != -1 (10) else fall (14)
            o.append("var taken = false")
            o.append("if c.cond(\(i.cond)) { c.cycles &+= 12 } else { let v = (c.d[\(i.reg)] &- 1) & 0xffff; c.d[\(i.reg)] = (c.d[\(i.reg)] & 0xffff_0000) | v; if v != 0xffff { taken = true; c.cycles &+= 10 } else { c.cycles &+= 14 } }")
            r.flow = .dbcc(i.target)
        case .scc:
            let dst = loc(i.dst!, .byte, &o, smc: smc)
            o.append("let tt = c.cond(\(i.cond))")
            if case .mem(let e) = dst { o.append("_ = c.read8(\(e))") }
            o.append(put(dst, .byte, "tt ? 0xff : 0"))
            if case .d = dst { r.dynamicCycles = "tt ? 2 : 0" }
        case .jmp:
            let src = loc(i.src!, .long, &o, smc: smc)
            if case .mem(let e) = src {
                if e.hasPrefix("0x"), !smc { r.flow = .goto(UInt32(e.dropFirst(2), radix: 16)!) }
                else if case .pcIdx = i.src! { r.flow = .jumpTable(e, []) }
                else { r.flow = .jumpDynamic(e) }
            }
        case .jsr:
            let src = loc(i.src!, .long, &o, smc: smc)
            if case .mem(let e) = src {
                if e.hasPrefix("0x"), !smc { r.flow = .call(UInt32(e.dropFirst(2), radix: 16)!) }
                else { r.flow = .callDynamic(e) }
            }
        case .rts:
            o.append("let retval = c.pop32()")
            r.flow = .ret
        case .rte:
            o.append("let nsr = c.pop16(); let retval = c.pop32(); c.setSR(UInt16(nsr))")
            r.flow = .ret
        case .rtr:
            o.append("let ccr = c.pop16(); let retval = c.pop32(); c.sr = (c.sr & 0xff00) | UInt16(ccr & 0x1f)")
            r.flow = .ret
        case .trap:
            // TRAP #14 is the developer's assertion break into the kernel monitor;
            // the game never takes it in normal play.
            r.flow = i.quick == 14 ? .fatal("assertion TRAP #14 at \(CodeGen.h(i.addr))") : .trap(32 + Int(i.quick))
        case .trapv:
            r.flow = .fatal("TRAPV not translated")
        case .nop:
            break
        case .stop, .reset, .illegal:
            r.flow = .fatal("\(i.kind) at \(next) not translated")
        }
        _ = next
        r.stmts = o
        return r
    }

    func isDestReg(_ i: Instr) -> Bool {
        // ADD/SUB/AND/OR: opmode bit 8 clear = <ea> op Dn -> Dn
        return i.opcode & 0x100 == 0
    }
}

extension Operand {
    var loc: CodeGen.Loc {
        if case .a(let r) = self { return .a(r) }
        if case .d(let r) = self { return .d(r) }
        return .imm("0")
    }
    var isImmediate: Bool { if case .imm = self { return true }; return false }
    var regNum: Int {
        switch self { case .a(let r), .d(let r): return r; default: return -1 }
    }
}
