extension CPU {
    @inline(__always) public static func sext8(_ v: UInt32) -> UInt32 { UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: v))) }
    @inline(__always) public static func sext16(_ v: UInt32) -> UInt32 { UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: v))) }

    static func sizeField(_ v: Int) -> Size? {
        switch v { case 0: return .byte; case 1: return .word; case 2: return .long; default: return nil }
    }

    // MARK: arithmetic helpers (return result, set flags)
    public func addOp(_ dst: UInt32, _ src: UInt32, _ s: Size, x: Bool = false, setX: Bool = true) -> UInt32 {
        let m = s.mask
        let xin: UInt64 = x && flag(CPU.X) ? 1 : 0
        let wide = UInt64(dst & m) + UInt64(src & m) + xin
        let r = UInt32(truncatingIfNeeded: wide) & m
        let carry = wide > UInt64(m)
        let ov = ((src ^ r) & (dst ^ r) & s.msb) != 0
        var f = sr & ~(CPU.N | CPU.V | CPU.C | (setX ? CPU.X : 0))
        if x { if r != 0 { f &= ~CPU.Z } } else { f &= ~CPU.Z; if r == 0 { f |= CPU.Z } }
        if r & s.msb != 0 { f |= CPU.N }
        if ov { f |= CPU.V }
        if carry { f |= CPU.C | (setX ? CPU.X : 0) }
        sr = f
        return r
    }

    /// dst - src
    public func subOp(_ dst: UInt32, _ src: UInt32, _ s: Size, x: Bool = false, setX: Bool = true) -> UInt32 {
        let m = s.mask
        let xin: UInt64 = x && flag(CPU.X) ? 1 : 0
        let borrow = UInt64(src & m) + xin > UInt64(dst & m)
        let r = (dst &- src &- UInt32(xin)) & m
        let ov = ((src ^ dst) & (r ^ dst) & s.msb) != 0
        var f = sr & ~(CPU.N | CPU.V | CPU.C | (setX ? CPU.X : 0))
        if x { if r != 0 { f &= ~CPU.Z } } else { f &= ~CPU.Z; if r == 0 { f |= CPU.Z } }
        if r & s.msb != 0 { f |= CPU.N }
        if ov { f |= CPU.V }
        if borrow { f |= CPU.C | (setX ? CPU.X : 0) }
        sr = f
        return r
    }

    public func cmpOp(_ dst: UInt32, _ src: UInt32, _ s: Size) {
        _ = subOp(dst, src, s, setX: false)
    }

    // MARK: main dispatch
    public func execute(_ op: UInt32) {
        let o = Int(op)
        switch o >> 12 {
        case 0x0: line0(o)
        case 0x1, 0x2, 0x3: move(o)
        case 0x4: line4(o)
        case 0x5: line5(o)
        case 0x6: branch(o)
        case 0x7:
            if o & 0x100 != 0 { illegalPending = true; return }
            let v = CPU.sext8(UInt32(o & 0xff))
            d[(o >> 9) & 7] = v
            setNZ(v, .long)
            cycles += 4
        case 0x8: line8(o)
        case 0x9: addSub(o, add: false)
        case 0xA: pc = lastOpPC; exception(10)
        case 0xB: lineB(o)
        case 0xC: lineC(o)
        case 0xD: addSub(o, add: true)
        case 0xE: shifts(o)
        default: pc = lastOpPC; exception(11)
        }
    }

    // MARK: line 0: immediate ops, bit ops, movep
    func line0(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7
        if o & 0x100 != 0 || (o >> 8) & 0xf == 8 {
            if o & 0x100 != 0 && mode == 1 { movep(o); return }
            bitOp(o)
            return
        }
        let kind = (o >> 9) & 7
        guard let s = CPU.sizeField((o >> 6) & 3) else { illegalPending = true; return }
        // to CCR / SR
        if mode == 7 && reg == 4 {
            guard kind == 0 || kind == 1 || kind == 5, s != .long else { illegalPending = true; return }
            let imm = fetch16() & (s == .byte ? 0xff : 0xffff)
            if s == .word && !supervisor { pc = lastOpPC; exception(8); return }
            var v = UInt32(sr)
            switch kind { case 0: v |= imm; case 1: v &= (s == .byte ? (imm | 0xff00) : imm); default: v ^= imm }
            if s == .byte { sr = (sr & 0xff00) | UInt16(v & 0x1f) } else { setSR(UInt16(v)) }
            cycles += 20
            return
        }
        let imm = s == .long ? fetch32() : (fetch16() & s.mask)
        if mode == 1 { illegalPending = true; return }
        let dst = ea(mode, reg, s)
        let v = get(dst, s)
        let regDst = mode == 0
        switch kind {
        case 0: let r = (v | imm) & s.mask; setNZ(r, s); put(dst, s, r)
        case 1: let r = v & imm; setNZ(r, s); put(dst, s, r)
        case 2: put(dst, s, subOp(v, imm, s))
        case 3: put(dst, s, addOp(v, imm, s))
        case 5: let r = (v ^ imm) & s.mask; setNZ(r, s); put(dst, s, r)
        case 6: cmpOp(v, imm, s); cycles += s == .long ? (regDst ? 14 : 12) : 8; return
        default: illegalPending = true; return
        }
        cycles += s == .long ? (regDst ? 16 : 20) : (regDst ? 8 : 12)
    }

    func bitOp(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7
        let kind = (o >> 6) & 3
        var bit: UInt32
        if o & 0x100 != 0 { bit = d[(o >> 9) & 7] } else { bit = fetch16() & 0xff; cycles += 4 }
        if mode == 0 {
            bit &= 31
            let v = d[reg]
            setFlag(CPU.Z, v & (1 << bit) == 0)
            switch kind {
            case 1: d[reg] = v ^ (1 << bit); cycles += 8
            case 2: d[reg] = v & ~(1 << bit); cycles += 10
            case 3: d[reg] = v | (1 << bit); cycles += 8
            default: cycles += 6
            }
            return
        }
        if mode == 1 { illegalPending = true; return }
        if kind != 0 && mode == 7 && reg >= 2 { illegalPending = true; return }
        bit &= 7
        let dst = ea(mode, reg, .byte)
        let v = get(dst, .byte)
        setFlag(CPU.Z, v & (1 << bit) == 0)
        switch kind {
        case 1: put(dst, .byte, v ^ (1 << bit)); cycles += 12
        case 2: put(dst, .byte, v & ~(1 << bit)); cycles += 12
        case 3: put(dst, .byte, v | (1 << bit)); cycles += 12
        default: cycles += 8
        }
    }

    func movep(_ o: Int) {
        let dr = (o >> 9) & 7, ar = o & 7
        let addr = a[ar] &+ CPU.sext16(fetch16())
        switch (o >> 6) & 3 {
        case 0: d[dr] = (d[dr] & 0xffff_0000) | read8(addr) << 8 | read8(addr &+ 2); cycles += 16
        case 1: d[dr] = read8(addr) << 24 | read8(addr &+ 2) << 16 | read8(addr &+ 4) << 8 | read8(addr &+ 6); cycles += 24
        case 2: write8(addr, d[dr] >> 8); write8(addr &+ 2, d[dr]); cycles += 16
        default:
            write8(addr, d[dr] >> 24); write8(addr &+ 2, d[dr] >> 16)
            write8(addr &+ 4, d[dr] >> 8); write8(addr &+ 6, d[dr]); cycles += 24
        }
    }

    // MARK: move
    func move(_ o: Int) {
        let s: Size = o >> 12 == 1 ? .byte : (o >> 12 == 3 ? .word : .long)
        let srcMode = (o >> 3) & 7, srcReg = o & 7
        let dstReg = (o >> 9) & 7, dstMode = (o >> 6) & 7
        if s == .byte && srcMode == 1 { illegalPending = true; return }
        let src = ea(srcMode, srcReg, s)
        let v = get(src, s)
        if dstMode == 1 {
            if s == .byte { illegalPending = true; return }
            a[dstReg] = s == .word ? CPU.sext16(v) : v
            cycles += 4
            return
        }
        if dstMode == 7 && dstReg > 1 { illegalPending = true; return }
        // -(An) destination does not add the usual 2-cycle penalty
        let dst = ea(dstMode, dstReg, s)
        if dstMode == 4 { cycles -= 2 }
        setNZ(v, s)
        put(dst, s, v)
        cycles += 4
    }

    // MARK: line 4
    func line4(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7
        if o & 0x1c0 == 0x1c0 {          // LEA
            guard mode == 2 || mode >= 5, !(mode == 7 && reg == 4) else { illegalPending = true; return }
            let e = ea(mode, reg, .long, time: false)
            a[(o >> 9) & 7] = address(e)
            cycles += [0, 0, 4, 0, 0, 8, 12, 8, 12, 8, 12, 0][eaIndex(mode, reg)]
            return
        }
        if o & 0x1c0 == 0x180 {          // CHK.W
            let src = ea(mode, reg, .word)
            if mode == 1 { illegalPending = true; return }
            let bound = Int16(truncatingIfNeeded: get(src, .word))
            let v = Int16(truncatingIfNeeded: d[(o >> 9) & 7])
            cycles += 10
            sr &= ~(CPU.Z | CPU.V | CPU.C)
            if v == 0 { sr |= CPU.Z }
            if v < 0 { sr |= CPU.N; exception(6) } else if v > bound { sr &= ~CPU.N; exception(6) }
            else { sr &= ~CPU.N }
            return
        }
        switch o & 0xfff {
        case 0xe70: if !supervisor { pc = lastOpPC; exception(8) } else { cycles += 132 }; return   // RESET
        case 0xe71: cycles += 4; return                                                         // NOP
        case 0xe72:                                                                             // STOP
            let v = fetch16()
            if !supervisor { pc = lastOpPC; exception(8); return }
            setSR(UInt16(v)); stopped = true; cycles += 4; return
        case 0xe73:                                                                             // RTE
            if !supervisor { pc = lastOpPC; exception(8); return }
            let nsr = pop16(); let npc = pop32()
            pc = npc; setSR(UInt16(nsr)); cycles += 20; return
        case 0xe75: pc = pop32(); cycles += 16; return                                         // RTS
        case 0xe76: if flag(CPU.V) { exception(7) } else { cycles += 4 }; return                // TRAPV
        case 0xe77:                                                                             // RTR
            let ccr = pop16(); pc = pop32()
            sr = (sr & 0xff00) | UInt16(ccr & 0x1f); cycles += 20; return
        default: break
        }
        switch (o >> 6) & 0x3f {
        case 0x03:                          // MOVE from SR
            if mode == 1 { illegalPending = true; return }
            let dst = ea(mode, reg, .word)
            if case .mem(let addr) = dst { _ = read16(addr) }
            put(dst, .word, UInt32(sr)); cycles += mode == 0 ? 6 : 8; return
        case 0x13:                          // MOVE to CCR
            if mode == 1 { illegalPending = true; return }
            let v = get(ea(mode, reg, .word), .word)
            sr = (sr & 0xff00) | UInt16(v & 0x1f); cycles += 12; return
        case 0x1b:                          // MOVE to SR
            if mode == 1 { illegalPending = true; return }
            if !supervisor { pc = lastOpPC; exception(8); return }
            let v = get(ea(mode, reg, .word), .word)
            setSR(UInt16(v)); cycles += 12; return
        case 0x20:                          // NBCD
            if mode == 1 { illegalPending = true; return }
            let dst = ea(mode, reg, .byte)
            put(dst, .byte, bcdSub(0, get(dst, .byte)))
            cycles += mode == 0 ? 6 : 8; return
        case 0x21:
            if mode == 0 {                  // SWAP
                let v = (d[reg] >> 16) | (d[reg] << 16); d[reg] = v; setNZ(v, .long); cycles += 4; return
            }
            if mode == 1 { illegalPending = true; return }   // BKPT not on 68000
            let e = ea(mode, reg, .long, time: false)        // PEA
            push32(address(e))
            cycles += [0, 0, 12, 0, 0, 16, 20, 16, 20, 16, 20, 0][eaIndex(mode, reg)]; return
        case 0x22, 0x23:
            if mode == 0 {                  // EXT
                if o & 0x40 == 0 { let v = CPU.sext8(d[reg]) & 0xffff; d[reg] = (d[reg] & 0xffff_0000) | v; setNZ(v, .word) }
                else { let v = CPU.sext16(d[reg]); d[reg] = v; setNZ(v, .long) }
                cycles += 4; return
            }
            movemToMem(o); return
        case 0x2b:
            if o == 0x4afc { illegalPending = true; return }
            if mode == 1 { illegalPending = true; return }   // TAS
            let dst = ea(mode, reg, .byte)
            let v = get(dst, .byte); setNZ(v, .byte); put(dst, .byte, v | 0x80)
            cycles += mode == 0 ? 4 : 14; return
        case 0x32, 0x33: movemToReg(o); return
        case 0x39:
            switch mode {
            case 0, 1: pc = lastOpPC + 2; exception(32 + (o & 15)); return   // TRAP
            case 2:                              // LINK
                let disp = CPU.sext16(fetch16())
                push32(a[reg]); a[reg] = a[7]; a[7] &+= disp; cycles += 16; return
            case 3:                              // UNLK
                a[7] = a[reg]; a[reg] = pop32(); cycles += 12; return
            case 4:                              // MOVE An,USP
                if !supervisor { pc = lastOpPC; exception(8); return }
                usp = a[reg]; cycles += 4; return
            case 5:
                if !supervisor { pc = lastOpPC; exception(8); return }
                a[reg] = usp; cycles += 4; return
            default: illegalPending = true; return
            }
        case 0x3a:                          // JSR
            guard mode == 2 || mode >= 5, !(mode == 7 && reg == 4) else { illegalPending = true; return }
            let target = address(ea(mode, reg, .long, time: false))
            push32(pc); pc = target
            cycles += [0, 0, 16, 0, 0, 18, 22, 18, 20, 18, 22, 0][eaIndex(mode, reg)]; return
        case 0x3b:                          // JMP
            guard mode == 2 || mode >= 5, !(mode == 7 && reg == 4) else { illegalPending = true; return }
            pc = address(ea(mode, reg, .long, time: false))
            cycles += [0, 0, 8, 0, 0, 10, 14, 10, 12, 10, 14, 0][eaIndex(mode, reg)]; return
        default: break
        }
        // NEGX / CLR / NEG / NOT / TST : 0100 xxx0 ss
        guard let s = CPU.sizeField((o >> 6) & 3) else { illegalPending = true; return }
        if mode == 1 { illegalPending = true; return }
        let kind = (o >> 9) & 7
        if kind == 5 {                      // TST
            setNZ(get(ea(mode, reg, s), s), s); cycles += 4; return
        }
        if mode == 7 && reg > 1 { illegalPending = true; return }
        let dst = ea(mode, reg, s)
        let extra = mode == 0 ? (s == .long ? 6 : 4) : (s == .long ? 12 : 8)
        switch kind {
        case 0: put(dst, s, subOp(0, get(dst, s), s, x: true))
        case 1: if case .mem(let addr) = dst { _ = read(addr, s) }
                put(dst, s, 0); sr = (sr & ~(CPU.N | CPU.V | CPU.C)) | CPU.Z
        case 2: put(dst, s, subOp(0, get(dst, s), s))
        case 3: let r = ~get(dst, s) & s.mask; setNZ(r, s); put(dst, s, r)
        default: illegalPending = true; return
        }
        cycles += extra
    }

    func movemToMem(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7
        let mask = fetch16()
        let s: Size = o & 0x40 != 0 ? .long : .word
        guard mode == 2 || mode == 4 || (mode >= 5 && !(mode == 7 && reg >= 2)) else { illegalPending = true; return }
        if mode == 4 {
            var addr = a[reg]
            let initial = a[reg]
            for i in 0..<16 where mask & (1 << i) != 0 {
                let r = 15 - i
                addr &-= UInt32(s.rawValue)
                // 68000 writes the initial value of An when An is in the list
                let v = r < 8 ? d[r] : (r - 8 == reg ? initial : a[r - 8])
                write(addr, s, v)
                cycles += s == .long ? 8 : 4
            }
            a[reg] = addr
            cycles += 8
            return
        }
        var addr = address(ea(mode, reg, s, time: false))
        cycles += [0, 0, 8, 0, 0, 12, 14, 12, 16, 0, 0, 0][eaIndex(mode, reg)]
        for i in 0..<16 where mask & (1 << i) != 0 {
            write(addr, s, i < 8 ? d[i] : a[i - 8])
            addr &+= UInt32(s.rawValue)
            cycles += s == .long ? 8 : 4
        }
    }

    func movemToReg(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7
        let mask = fetch16()
        let s: Size = o & 0x40 != 0 ? .long : .word
        guard mode == 2 || mode == 3 || (mode >= 5 && !(mode == 7 && reg == 4)) else { illegalPending = true; return }
        var addr: UInt32
        if mode == 3 { addr = a[reg] } else { addr = address(ea(mode, reg, s, time: false)) }
        cycles += [0, 0, 12, 12, 0, 16, 18, 16, 20, 16, 18, 0][eaIndex(mode, reg)]
        for i in 0..<16 where mask & (1 << i) != 0 {
            var v = read(addr, s)
            if s == .word { v = CPU.sext16(v) }
            if i < 8 { d[i] = v } else { a[i - 8] = v }
            addr &+= UInt32(s.rawValue)
            cycles += s == .long ? 8 : 4
        }
        _ = read16(addr)      // the 68000 performs one extra word read
        if mode == 3 { a[reg] = addr }
    }

    // MARK: line 5
    func line5(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7
        if (o >> 6) & 3 == 3 {
            let c = (o >> 8) & 15
            if mode == 1 {                  // DBcc
                let disp = CPU.sext16(fetch16())
                if cond(c) { cycles += 12; return }
                let v = (d[reg] &- 1) & 0xffff
                d[reg] = (d[reg] & 0xffff_0000) | v
                if v != 0xffff { pc = lastOpPC &+ 2 &+ disp; cycles += 10 } else { cycles += 14 }
                return
            }
            if mode == 7 && reg > 1 { illegalPending = true; return }
            let dst = ea(mode, reg, .byte)
            let t = cond(c)
            if case .mem(let addr) = dst { _ = read8(addr) }
            put(dst, .byte, t ? 0xff : 0)
            cycles += mode == 0 ? (t ? 6 : 4) : 8
            return
        }
        guard let s = CPU.sizeField((o >> 6) & 3) else { illegalPending = true; return }
        var q = UInt32((o >> 9) & 7); if q == 0 { q = 8 }
        if mode == 7 && reg > 1 { illegalPending = true; return }
        if mode == 1 {
            if s == .byte { illegalPending = true; return }
            a[reg] = o & 0x100 != 0 ? a[reg] &- q : a[reg] &+ q
            cycles += 8
            return
        }
        let dst = ea(mode, reg, s)
        let v = get(dst, s)
        put(dst, s, o & 0x100 != 0 ? subOp(v, q, s) : addOp(v, q, s))
        cycles += mode == 0 ? (s == .long ? 8 : 4) : (s == .long ? 12 : 8)
    }

    // MARK: branches
    func branch(_ o: Int) {
        let c = (o >> 8) & 15
        var disp = CPU.sext8(UInt32(o & 0xff))
        let base = pc
        let word = o & 0xff == 0
        if word { disp = CPU.sext16(fetch16()) }
        if c == 1 {                         // BSR
            push32(pc); pc = base &+ disp; cycles += 18; return
        }
        if cond(c) { pc = base &+ disp; cycles += 10 } else { cycles += word ? 12 : 8 }
    }

    // MARK: line 8: OR, DIV, SBCD
    func line8(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7, dr = (o >> 9) & 7
        switch (o >> 6) & 7 {
        case 3, 7:                          // DIVU / DIVS
            if mode == 1 { illegalPending = true; return }
            let src = get(ea(mode, reg, .word), .word)
            divide(dr, src, signed: o & 0x100 != 0)
            return
        case 4 where mode < 2:              // SBCD
            if mode == 0 { d[dr] = (d[dr] & ~0xff) | bcdSub(d[dr] & 0xff, d[reg] & 0xff); cycles += 6 }
            else {
                a[reg] &-= reg == 7 ? 2 : 1; let sv = read8(a[reg])
                a[dr] &-= dr == 7 ? 2 : 1; let dv = read8(a[dr])
                write8(a[dr], bcdSub(dv, sv)); cycles += 18
            }
            return
        default: break
        }
        logic(o) { $0 | $1 }
    }

    func logic(_ o: Int, _ f: (UInt32, UInt32) -> UInt32) {
        let mode = (o >> 3) & 7, reg = o & 7, dr = (o >> 9) & 7
        guard let s = CPU.sizeField((o >> 6) & 3) else { illegalPending = true; return }
        if mode == 1 { illegalPending = true; return }
        if o & 0x100 == 0 {
            let v = get(ea(mode, reg, s), s)
            let r = f(d[dr], v) & s.mask
            d[dr] = (d[dr] & ~s.mask) | r
            setNZ(r, s)
            cycles += s == .long ? ((mode == 0 || (mode == 7 && reg == 4)) ? 8 : 6) : 4
        } else {
            if mode == 7 && reg > 1 { illegalPending = true; return }
            let dst = ea(mode, reg, s)
            let r = f(get(dst, s), d[dr]) & s.mask
            setNZ(r, s); put(dst, s, r)
            cycles += s == .long ? 12 : 8
        }
    }

    public func divide(_ dr: Int, _ src: UInt32, signed: Bool) {
        if src == 0 {
            sr &= ~(CPU.N | CPU.Z | CPU.V | CPU.C)
            exception(5); return
        }
        if !signed {
            let q = d[dr] / src, r = d[dr] % src
            cycles += 140
            if q > 0xffff { sr = (sr & ~(CPU.C | CPU.Z)) | CPU.V | CPU.N; return }
            d[dr] = r << 16 | q
            setNZ(q, .word)
        } else {
            let dv = Int64(Int32(bitPattern: d[dr])), sv = Int64(Int16(truncatingIfNeeded: src))
            let q = dv / sv, r = dv % sv
            cycles += 158
            if q > 32767 || q < -32768 { sr = (sr & ~(CPU.C | CPU.Z)) | CPU.V | CPU.N; return }
            let qq = UInt32(truncatingIfNeeded: q) & 0xffff, rr = UInt32(truncatingIfNeeded: r) & 0xffff
            d[dr] = rr << 16 | qq
            setNZ(qq, .word)
        }
    }

    // BCD including the undocumented V flag, after the real-chip behaviour
    // (formulas as in the Moira emulator; matched against SingleStepTests).
    public func bcdAdd(_ dst: UInt32, _ src: UInt32) -> UInt32 {
        let x: UInt32 = flag(CPU.X) ? 1 : 0
        let lo = (src & 0x0f) + (dst & 0x0f) + x
        let tmp = (src & 0xf0) + (dst & 0xf0) + lo
        var res = tmp
        if lo > 9 { res += 6 }
        let c = (res & 0x3f0) > 0x90
        if c { res += 0x60 }
        finishBCD(res, c, v: (tmp & 0x80) == 0 && (res & 0x80) != 0)
        return res & 0xff
    }

    /// dst - src - X
    public func bcdSub(_ dst: UInt32, _ src: UInt32) -> UInt32 {
        let x: UInt32 = flag(CPU.X) ? 1 : 0
        let lo = (dst & 0x0f) &- (src & 0x0f) &- x
        let hi = (dst & 0xf0) &- (src & 0xf0)
        let tmp = hi &+ lo
        var res = tmp
        var corr: UInt32 = 0
        if lo & 0xf0 != 0 { corr = 6; res = res &- 6 }
        if (dst &- src &- x) & 0x100 != 0 { res = res &- 0x60 }
        let c = ((dst &- src &- corr &- x) & 0x300) > 0xff
        finishBCD(res, c, v: (tmp & 0x80) != 0 && (res & 0x80) == 0)
        return res & 0xff
    }

    private func finishBCD(_ res: UInt32, _ c: Bool, v: Bool) {
        setFlag(CPU.C, c); setFlag(CPU.X, c)
        setFlag(CPU.V, v)
        setFlag(CPU.N, res & 0x80 != 0)
        if res & 0xff != 0 { sr &= ~CPU.Z }
    }

    // MARK: ADD / SUB family (lines 9 and D)
    func addSub(_ o: Int, add: Bool) {
        let mode = (o >> 3) & 7, reg = o & 7, dr = (o >> 9) & 7
        let opm = (o >> 6) & 7
        if opm == 3 || opm == 7 {           // ADDA / SUBA
            let s: Size = opm == 3 ? .word : .long
            var v = get(ea(mode, reg, s), s)
            if s == .word { v = CPU.sext16(v) }
            a[dr] = add ? a[dr] &+ v : a[dr] &- v
            cycles += s == .long && !(mode == 0 || mode == 1 || (mode == 7 && reg == 4)) ? 6 : 8
            return
        }
        guard let s = CPU.sizeField(opm & 3) else { illegalPending = true; return }
        if opm >= 4 && mode < 2 {           // ADDX / SUBX
            if mode == 0 {
                let r = add ? addOp(d[dr], d[reg], s, x: true) : subOp(d[dr], d[reg], s, x: true)
                d[dr] = (d[dr] & ~s.mask) | r
                cycles += s == .long ? 8 : 4
            } else {
                let st = UInt32((s == .byte && reg == 7) ? 2 : s.rawValue)
                a[reg] &-= st; let sv = read(a[reg], s)
                let dt = UInt32((s == .byte && dr == 7) ? 2 : s.rawValue)
                a[dr] &-= dt; let dv = read(a[dr], s)
                write(a[dr], s, add ? addOp(dv, sv, s, x: true) : subOp(dv, sv, s, x: true))
                cycles += s == .long ? 30 : 18
            }
            return
        }
        if opm < 4 {                        // <ea> op Dn -> Dn
            if s == .byte && mode == 1 { illegalPending = true; return }
            let v = get(ea(mode, reg, s), s)
            let r = add ? addOp(d[dr], v, s) : subOp(d[dr], v, s)
            d[dr] = (d[dr] & ~s.mask) | r
            cycles += s == .long ? ((mode < 2 || (mode == 7 && reg == 4)) ? 8 : 6) : 4
        } else {                            // Dn op <ea> -> <ea>
            if mode == 7 && reg > 1 { illegalPending = true; return }
            let dst = ea(mode, reg, s)
            let v = get(dst, s)
            put(dst, s, add ? addOp(v, d[dr], s) : subOp(v, d[dr], s))
            cycles += s == .long ? 12 : 8
        }
    }

    // MARK: line B: CMP, CMPA, CMPM, EOR
    func lineB(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7, dr = (o >> 9) & 7
        let opm = (o >> 6) & 7
        if opm == 3 || opm == 7 {           // CMPA
            let s: Size = opm == 3 ? .word : .long
            var v = get(ea(mode, reg, s), s)
            if s == .word { v = CPU.sext16(v) }
            cmpOp(a[dr], v, .long)
            cycles += 6
            return
        }
        guard let s = CPU.sizeField(opm & 3) else { illegalPending = true; return }
        if opm < 4 {
            if s == .byte && mode == 1 { illegalPending = true; return }
            cmpOp(d[dr], get(ea(mode, reg, s), s), s)
            cycles += s == .long ? 6 : 4
            return
        }
        if mode == 1 {                      // CMPM (Ay)+,(Ax)+
            let sv = get(ea(3, reg, s, time: false), s)
            let dv = get(ea(3, dr, s, time: false), s)
            cmpOp(dv, sv, s)
            cycles += s == .long ? 20 : 12
            return
        }
        if mode == 7 && reg > 1 { illegalPending = true; return }
        let dst = ea(mode, reg, s)          // EOR Dn,<ea>
        let r = (get(dst, s) ^ d[dr]) & s.mask
        setNZ(r, s); put(dst, s, r)
        cycles += mode == 0 ? (s == .long ? 8 : 4) : (s == .long ? 12 : 8)
    }

    // MARK: line C: AND, MUL, ABCD, EXG
    func lineC(_ o: Int) {
        let mode = (o >> 3) & 7, reg = o & 7, dr = (o >> 9) & 7
        switch (o >> 3) & 0x3f {
        case 0x28: let t = d[dr]; d[dr] = d[reg]; d[reg] = t; cycles += 6; return   // EXG Dx,Dy
        case 0x29: let t = a[dr]; a[dr] = a[reg]; a[reg] = t; cycles += 6; return   // EXG Ax,Ay
        case 0x31: let t = d[dr]; d[dr] = a[reg]; a[reg] = t; cycles += 6; return   // EXG Dx,Ay
        default: break
        }
        switch (o >> 6) & 7 {
        case 3, 7:                          // MULU / MULS
            if mode == 1 { illegalPending = true; return }
            let src = get(ea(mode, reg, .word), .word)
            let r: UInt32
            if o & 0x100 == 0 {
                r = (d[dr] & 0xffff) * src
                cycles += 38 + 2 * src.nonzeroBitCount
            } else {
                r = UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: d[dr])) * Int32(Int16(truncatingIfNeeded: src)))
                let pat = (src << 1) ^ src
                cycles += 38 + 2 * (pat & 0xffff).nonzeroBitCount
            }
            d[dr] = r; setNZ(r, .long)
            return
        case 4 where mode < 2:              // ABCD
            if mode == 0 { d[dr] = (d[dr] & ~0xff) | bcdAdd(d[dr] & 0xff, d[reg] & 0xff); cycles += 6 }
            else {
                a[reg] &-= reg == 7 ? 2 : 1; let sv = read8(a[reg])
                a[dr] &-= dr == 7 ? 2 : 1; let dv = read8(a[dr])
                write8(a[dr], bcdAdd(dv, sv)); cycles += 18
            }
            return
        default: break
        }
        logic(o) { $0 & $1 }
    }

    // MARK: line E: shifts and rotates
    func shifts(_ o: Int) {
        if (o >> 6) & 3 == 3 {              // memory form, word, count 1
            let mode = (o >> 3) & 7, reg = o & 7
            if mode < 2 || (mode == 7 && reg > 1) || o & 0x800 != 0 { illegalPending = true; return }
            let dst = ea(mode, reg, .word)
            let r = shift((o >> 9) & 3, left: o & 0x100 != 0, get(dst, .word), 1, .word)
            put(dst, .word, r)
            cycles += 8
            return
        }
        guard let s = CPU.sizeField((o >> 6) & 3) else { illegalPending = true; return }
        let reg = o & 7
        var count = UInt32((o >> 9) & 7)
        if o & 0x20 != 0 { count = d[Int(count)] & 63 } else if count == 0 { count = 8 }
        let r = shift((o >> 3) & 3, left: o & 0x100 != 0, d[reg] & s.mask, count, s)
        d[reg] = (d[reg] & ~s.mask) | r
        cycles += (s == .long ? 8 : 6) + 2 * Int(count)
    }

    public func shift(_ kind: Int, left: Bool, _ value: UInt32, _ count: UInt32, _ s: Size) -> UInt32 {
        let m = s.mask, msb = s.msb, bits = UInt32(s.rawValue * 8)
        var v = value & m
        var c = false, ov = false
        var x = flag(CPU.X)
        if count == 0 {
            sr &= ~(CPU.V | CPU.C)
            if kind == 2 { setFlag(CPU.C, x) }
            setFlag(CPU.N, v & msb != 0); setFlag(CPU.Z, v == 0)
            return v
        }
        for _ in 0..<count {
            switch (kind, left) {
            case (0, true):                 // ASL
                c = v & msb != 0
                let nv = (v << 1) & m
                if (nv ^ v) & msb != 0 { ov = true }
                v = nv; x = c
            case (0, false):                // ASR
                c = v & 1 != 0; v = (v >> 1) | (v & msb); x = c
            case (1, true): c = v & msb != 0; v = (v << 1) & m; x = c           // LSL
            case (1, false): c = v & 1 != 0; v >>= 1; x = c                     // LSR
            case (2, true):                 // ROXL
                c = v & msb != 0; v = ((v << 1) | (x ? 1 : 0)) & m; x = c
            case (2, false):                // ROXR
                c = v & 1 != 0; v = (v >> 1) | (x ? msb : 0); x = c
            case (3, true): c = v & msb != 0; v = ((v << 1) | (c ? 1 : 0)) & m  // ROL
            default: c = v & 1 != 0; v = (v >> 1) | (c ? msb : 0)              // ROR
            }
        }
        _ = bits
        sr &= ~(CPU.N | CPU.Z | CPU.V | CPU.C)
        if v & msb != 0 { sr |= CPU.N }
        if v == 0 { sr |= CPU.Z }
        if ov { sr |= CPU.V }
        if c { sr |= CPU.C }
        if kind != 3 { setFlag(CPU.X, x) }
        return v
    }
}
