import Foundation
import M68K

/// Static translator: discovers code by control flow from entry points, splits
/// it into functions, and emits Swift. Cycle counts come from running each
/// instruction through the reference interpreter ("oracle"), so the generated
/// code and the interpreter account time identically.
public final class Translator {
    public struct Config {
        public var entries: [UInt32: String] = [:]       // address -> name
        public var extraEntries: Set<UInt32> = []        // e.g. coverage call targets
        public var dynamicOperands: Set<UInt32> = []     // self-modifying instructions
        /// Instructions whose opcode word can be overwritten at run time: the
        /// generated code checks the opcode and hands over to the interpreter if changed.
        public var opcodeGuards: Set<UInt32> = []
        public var native: [UInt32: String] = [:]        // HLE: calls/jumps go to rt.native
        public var jumpTables: [UInt32: [UInt32]] = [:]  // computed jump -> known targets
        public var codeRanges: [ClosedRange<UInt32>] = []
        public init() {}
    }

    public let memory: [UInt8]           // flat 512K image as the code sees it
    public var config: Config
    let decoder: Decoder
    public private(set) var instrs: [UInt32: Instr] = [:]
    public private(set) var functions: [UInt32: Set<UInt32>] = [:]     // entry -> instruction addresses
    public private(set) var leaders: [UInt32: Set<UInt32>] = [:]
    public private(set) var warnings: [String] = []
    var callTargets = Set<UInt32>()

    public init(memory: [UInt8], config: Config) {
        self.memory = memory
        self.config = config
        let mem = memory
        decoder = Decoder { a in
            let i = Int(a) & 0x7ffff
            return UInt16(mem[i]) << 8 | UInt16(mem[(i + 1) & 0x7ffff])
        }
    }

    func inCode(_ a: UInt32) -> Bool { config.codeRanges.contains { $0.contains(a) } && a & 1 == 0 }

    func decode(_ a: UInt32) -> Instr? {
        if let i = instrs[a] { return i }
        guard inCode(a) else { warnings.append(String(format: "reference outside code ranges: $%06X", a)); return nil }
        do { let i = try decoder.decode(a); instrs[a] = i; return i }
        catch { warnings.append("\(error)"); return nil }
    }

    /// Successors within a function (not following calls).
    func successors(_ i: Instr) -> [UInt32] {
        switch i.kind {
        case .bra: return [i.target]
        case .bcc, .dbcc: return [i.next, i.target]
        case .rts, .rte, .rtr, .stop, .illegal, .reset: return []
        case .trap where i.quick == 14: return []
        case .jmp:
            if let t = config.jumpTables[i.addr] { return t }
            if case .absL(let a, _)? = i.src, !config.dynamicOperands.contains(i.addr) { return [a] }
            if case .absW(let a)? = i.src { return [a] }
            if case .pcDisp(let a)? = i.src { return [a] }
            if case .pcIdx(let base, _, _, _)? = i.src {
                // table of BRA instructions following the JMP
                var t = [UInt32](); var a = base
                while let b = decode(a), b.kind == .bra { t.append(a); a = b.next }
                config.jumpTables[i.addr] = t
                return t
            }
            return []
        default: return [i.next]
        }
    }

    func callTarget(_ i: Instr) -> UInt32? {
        switch i.kind {
        case .bsr: return i.target
        case .jsr:
            if config.dynamicOperands.contains(i.addr) { return nil }
            if case .absL(let a, _)? = i.src { return a }
            if case .absW(let a)? = i.src { return a }
            if case .pcDisp(let a)? = i.src { return a }
            return nil
        default: return nil
        }
    }

    public func analyse() {
        var work = Array(Set(config.entries.keys).union(config.extraEntries)).sorted()
        var entrySet = Set(work)
        while let e = work.popLast() {
            if functions[e] != nil || config.native[e] != nil { continue }
            var body = Set<UInt32>(), lead: Set<UInt32> = [e]
            var stack = [e]
            while let a = stack.popLast() {
                if body.contains(a) { continue }
                if a != e && entrySet.contains(a) { continue }     // branch into another function = tail call
                if config.native[a] != nil { continue }
                guard let i = decode(a) else { continue }
                body.insert(a)
                if let t = callTarget(i), config.native[t] == nil, !entrySet.contains(t), inCode(t) {
                    entrySet.insert(t); work.append(t)
                }
                if callTarget(i) != nil || i.kind == .jsr { lead.insert(i.next) }
                if i.kind == .lea, case .a(7)? = i.dst { lead.insert(i.next) }      // resume point after a stack reset
                for s in successors(i) {
                    if s != i.next || i.kind == .bra || i.kind == .jmp { lead.insert(s) }
                    if !inCode(s) { warnings.append(String(format: "branch $%06X -> $%06X outside code", a, s)); continue }
                    stack.append(s)
                }
            }
            functions[e] = body
            leaders[e] = lead.intersection(body).union([e])
            // immediates that look like code addresses (handlers stored in data) become entries
            for a in body {
                let i = instrs[a]!
                for o in [i.src, i.dst] {
                    if case .imm(let v, _)? = o, i.size == .long, v >= 0x4000, v < 0x60000,
                       let d = try? decoder.decode(v), d.length > 0 {
                        _ = d
                        candidateImmediates.insert(v)
                        immediateUses[v, default: []].append(i)
                    }
                }
            }
        }
        callTargets = entrySet
    }
    public private(set) var candidateImmediates = Set<UInt32>()

    /// Static self-modification check: instructions that write to an absolute
    /// address inside another translated instruction. Returns (writer, target instruction).
    public private(set) var opcodeTargets = Set<UInt32>()
    public func selfModifyingWrites() -> [(UInt32, UInt32)] {
        let starts = instrs.keys.sorted()
        var result = [(UInt32, UInt32)]()
        func containing(_ x: UInt32) -> UInt32? {
            var lo = 0, hi = starts.count - 1, best: UInt32?
            while lo <= hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= x { best = starts[mid]; lo = mid + 1 } else { hi = mid - 1 }
            }
            if let b = best, x < b + UInt32(instrs[b]!.length) { return b }
            return nil
        }
        for (a, i) in instrs {
            let writes: Bool
            switch i.kind {
            case .move, .clr, .addq, .subq, .add, .sub, .and, .or, .eor, .not, .neg, .addi, .subi, .andi, .ori, .eori,
                 .bset, .bclr, .bchg, .scc, .movemToMem: writes = true
            default: writes = false
            }
            guard writes, let d = i.dst else { continue }
            var t: UInt32?
            if case .absL(let x, _) = d { t = x }
            if case .absW(let x) = d { t = x }
            guard let target = t, target >= 0x400, target < 0x80000 else { continue }
            for k in 0..<UInt32(i.size.rawValue) {
                if let inst = containing(target + k), inst != a { result.append((a, inst)); if target + k < inst + 2 { opcodeTargets.insert(inst) } }
            }
        }
        return result
    }
    public private(set) var immediateUses = [UInt32: [Instr]]()

    // MARK: oracle cycles

    final class ScratchBus: M68KBus {
        var mem = [UInt8](repeating: 0, count: 1 << 24)
        var touched = [Int]()
        var fill: UInt8 = 0
        func read8(_ a: UInt32) -> UInt8 { mem[Int(a)] }
        func read16(_ a: UInt32) -> UInt16 { UInt16(mem[Int(a)]) << 8 | UInt16(mem[(Int(a) + 1) & 0xffffff]) }
        func write8(_ a: UInt32, _ v: UInt8) { mem[Int(a)] = v; touched.append(Int(a)) }
        func write16(_ a: UInt32, _ v: UInt16) { write8(a, UInt8(v >> 8)); write8((a + 1) & 0xffffff, UInt8(v & 0xff)) }
        func reset() { for t in touched { mem[t] = fill }; touched.removeAll(keepingCapacity: true) }
    }
    lazy var scratch = ScratchBus()
    lazy var scratchCPU = CPU(bus: scratch)

    /// Cycles the interpreter charges for `i`, with registers/memory chosen so
    /// that value-dependent timing takes its base value.
    func oracleCycles(_ i: Instr) -> Int {
        let c = scratchCPU
        var best = -1
        for oddBase in [false, true] {
            scratch.reset()
            let isDiv = i.kind == .divu || i.kind == .divs
            for k in 0..<8 { c.d[k] = isDiv ? 1 : 0 }
            for k in 0..<7 { c.a[k] = 0x100000 + UInt32(k) * 0x1000 + (oddBase ? 1 : 0) }
            c.a[7] = 0x200000; c.ssp = 0x200000; c.usp = 0x300000
            if isDiv {
                // non-zero divisor everywhere it could be read from
                for k in stride(from: 0x100000, to: 0x108000, by: 2) { scratch.write16(UInt32(k), 1) }
                for k in stride(from: 0x0, to: 0x8000, by: 2) { scratch.write16(UInt32(k), 1) }
            }
            // instruction bytes last, so the fill above cannot overwrite them
            for k in 0..<i.length { scratch.write8(i.addr + UInt32(k), memory[Int(i.addr) + k]) }
            c.sr = 0x2700; c.pc = i.addr; c.cycles = 0; c.lastFault = nil; c.ipl = 0
            c.step()
            if c.lastFault == nil { best = c.cycles; break }
            best = c.cycles
        }
        return best
    }

    func staticCycles(_ i: Instr, _ g: GenResult) -> Int {
        switch i.kind {
        case .bra, .bcc, .bsr, .dbcc, .trap: return 0    // handled in flow emission
        case .scc:
            if case .d? = i.dst {
                let t = oracleCycles(i)
                scratchCPU.sr = 0x2700
                return t - (scratchCPU.cond(i.cond) ? 2 : 0)
            }
            return oracleCycles(i)
        default: return oracleCycles(i)
        }
    }

    // MARK: emission

    public static func fname(_ a: UInt32, _ names: [UInt32: String]) -> String {
        if let n = names[a] { return "f_\(n)" }
        return String(format: "f_%06x", a)
    }

    func swiftFlow(_ i: Instr, _ g: GenResult, _ fnEntry: UInt32, _ body: Set<UInt32>, _ out: inout [String], _ names: [UInt32: String]) {
        let h = CodeGen.h
        let next = h(i.next)
        func tick(_ pc: String) -> String { "if c.cycles >= rt.eventCycle { try rt.service(c, \(pc)) }" }
        func jumpTo(_ t: UInt32) -> String {
            if config.native[t] != nil { return "return try rt.native(c, \(h(t)))" }
            if body.contains(t) && (t != fnEntry || true) && (t == fnEntry || !callTargets.contains(t) || body.contains(t)) && leaders[fnEntry]!.contains(t) {
                return "pc = \(h(t)); continue"
            }
            if functions[t] != nil { return "return try \(Translator.fname(t, names))(c, rt, \(h(t)))" }
            return "return try rt.dispatch(c, \(h(t)))"
        }
        func call(_ target: String, _ direct: UInt32?) -> String {
            let callee: String
            if let t = direct, config.native[t] != nil { callee = "rt.native(c, \(h(t)))" }
            else if let t = direct, functions[t] != nil { callee = "\(Translator.fname(t, names))(c, rt, \(h(t)))" }
            else { callee = "rt.dispatch(c, \(target))" }
            return "do { let r = try \(callee); if r != \(next) { return r } }"
        }
        switch g.flow {
        case .next:
            if g.spReset { out.append("try rt.stackReset(c, \(next))") }
            if g.checkInterrupts { out.append("try rt.service(c, \(next))") } else { out.append(tick(next)) }
        case .goto(let t):
            // BRA costs 10; JMP's cost is already in the oracle's static count
            out.append((i.kind == .bra ? "c.cycles &+= 10; " : "") + tick(h(t)))
            out.append(jumpTo(t))
        case .cond(let e, let t):
            let notTaken = i.length == 2 ? 8 : 12
            out.append("if \(e) { c.cycles &+= 10; \(tick(h(t))); \(jumpTo(t)) }")
            out.append("c.cycles &+= \(notTaken); " + tick(next))
        case .dbcc(let t):
            out.append("if taken { \(tick(h(t))); \(jumpTo(t)) }")
            out.append(tick(next))
        case .call(let t):
            if i.kind == .bsr { out.append("c.push32(\(next)); c.cycles &+= 18; " + tick(h(t))) }
            else { out.append(tick(h(t))) }     // JSR: push done in statements below
            out.append(call(h(t), t))
        case .callDynamic(let e):
            out.append(tick(e))
            out.append(call(e, nil))
        case .jumpDynamic(let e):
            out.append(tick(e))
            out.append("return try rt.dispatch(c, \(e))")
        case .jumpTable(let e, _):
            out.append(tick(e))
            out.append("pc = \(e); continue")
        case .ret:
            out.append(tick("retval"))
            out.append("return retval")
        case .trap(let v):
            out.append("do { let r = try rt.exception(c, vector: \(v), returnTo: \(next)); if r != \(next) { return r } }")
        case .fatal(let m):
            out.append("try rt.fatal(c, \"\(m)\")")
        }
    }

    public func emitFunction(_ e: UInt32, names: [UInt32: String], comments: [UInt32: String]) -> String {
        var gen = CodeGen(dynamicOperands: config.dynamicOperands)
        let body = functions[e]!
        let lead = leaders[e]!
        let addrs = body.sorted()
        var out = [String]()
        let h = CodeGen.h
        out.append("")
        if let cmt = comments[e] { out.append("/// \(cmt)") }
        out.append(String(format: "/// Original routine at $%06X", e))
        out.append("func \(Translator.fname(e, names))(_ c: CPU, _ rt: Runtime, _ entry: UInt32) throws -> UInt32 {")
        out.append("    var pc = entry")
        out.append("    while true {")
        out.append("        switch pc {")
        var open = false
        for (n, a) in addrs.enumerated() {
            let i = instrs[a]!
            let isLeader = lead.contains(a) || n == 0 || addrs[n - 1] != a - UInt32(instrs[addrs[n - 1]]!.length) && false
            if isLeader || !open {
                if open { out.append("            fallthrough") }
                out.append("        case \(h(a)):" + (names[a].map { "  // \($0)" } ?? ""))
                open = true
            }
            var g = gen.gen(i)
            if i.kind == .jsr { g.stmts.append("c.push32(\(h(i.next)))") }
            let cyc = staticCycles(i, g)
            var lines = ["// $\(String(format: "%06X", a))  \(i.text)" + (comments[a].map { "   ; \($0)" } ?? ""),
                         "if rt.tracing { rt.trace(c, \(h(a))) }"]
            if config.opcodeGuards.contains(a) {
                lines.append("if c.read16(\(h(a))) != \(String(format: "0x%04x", i.opcode)) { return try rt.interpret(c, \(h(a))) }  // opcode rewritten at run time")
            }
            var core = g.stmts
            if cyc != 0 { core.append("c.cycles &+= \(cyc)") }
            if let dc = g.dynamicCycles { core.append("c.cycles &+= \(dc)") }
            var flow = [String]()
            swiftFlow(i, g, e, body, &flow, names)
            if core.isEmpty && flow.count <= 1 {
                lines += flow
            } else if needsScope(core) {
                lines.append("do {")
                lines += core.map { "    " + $0 }
                lines += flow.map { "    " + $0 }
                lines.append("}")
            } else {
                lines += core + flow
            }
            out += lines.map { "            " + $0 }
            // control leaves the instruction without falling through?
            let fallsThrough: Bool
            switch g.flow {
            case .goto, .ret, .jumpDynamic, .jumpTable, .fatal: fallsThrough = false
            default: fallsThrough = true
            }
            let nextInBody = n + 1 < addrs.count && addrs[n + 1] == i.next
            if !fallsThrough {
                open = false
            } else if !nextInBody {
                out.append("            \(nextJump(i.next, e, body, names))")
                open = false
            }
        }
        out.append("        default:")
        out.append("            return try rt.dispatch(c, pc)")
        out.append("        }")
        out.append("    }")
        out.append("}")
        return out.joined(separator: "\n")
    }

    func nextJump(_ t: UInt32, _ e: UInt32, _ body: Set<UInt32>, _ names: [UInt32: String]) -> String {
        let h = CodeGen.h
        if config.native[t] != nil { return "return try rt.native(c, \(h(t)))" }
        if body.contains(t) { return "pc = \(h(t)); continue" }
        if functions[t] != nil { return "return try \(Translator.fname(t, names))(c, rt, \(h(t)))" }
        return "return try rt.dispatch(c, \(h(t)))"
    }

    /// Standalone form of every translated instruction for the differential
    /// test: executes the instruction's effects and cycles, returns the next PC.
    public func emitSnippets() -> String {
        var gen = CodeGen(dynamicOperands: config.dynamicOperands)
        var out = ["/// Per-instruction snippets for the differential test (ReferenceTests).",
                   "public struct SnippetFatal: Error {}",
                   "func snippetFatal(_ c: CPU, _ m: String) throws { throw SnippetFatal() }",
                   "nonisolated(unsafe) public let instructionSnippets: [UInt32: (CPU) throws -> UInt32] = ["]
        let h = CodeGen.h
        for a in instrs.keys.sorted() {
            let i = instrs[a]!
            var g = gen.gen(i)
            if i.kind == .jsr { g.stmts.append("c.push32(\(h(i.next)))") }
            var body = g.stmts.map { $0.replacingOccurrences(of: "try rt.fatal(c,", with: "try snippetFatal(c,") }
            let cyc = staticCycles(i, g)
            if cyc != 0 { body.append("c.cycles &+= \(cyc)") }
            if let dc = g.dynamicCycles { body.append("c.cycles &+= \(dc)") }
            switch g.flow {
            case .next: body.append("return \(h(i.next))")
            case .goto(let t): if i.kind == .bra { body.append("c.cycles &+= 10") }; body.append("return \(h(t))")
            case .cond(let e, let t): body.append("if \(e) { c.cycles &+= 10; return \(h(t)) }; c.cycles &+= \(i.length == 2 ? 8 : 12); return \(h(i.next))")
            case .dbcc(let t): body.append("return taken ? \(h(t)) : \(h(i.next))")
            case .call(let t): if i.kind == .bsr { body.append("c.push32(\(h(i.next))); c.cycles &+= 18") }; body.append("return \(h(t))")
            case .callDynamic(let e), .jumpDynamic(let e), .jumpTable(let e, _): body.append("return \(e)")
            case .ret: body.append("return retval")
            case .trap, .fatal: continue
            }
            out.append("    \(h(a)): { c in  // \(i.text)")
            out += body.map { "        " + $0 }
            out.append("    },")
        }
        out.append("]")
        return out.joined(separator: "\n")
    }

    func needsScope(_ s: [String]) -> Bool { s.contains { $0.hasPrefix("let ") || $0.hasPrefix("var ") || $0.contains("; let ") } }

    /// Every address code may be entered at: function entries and leaders.
    public func dispatchTable(names: [UInt32: String]) -> [(UInt32, String)] {
        var map = [UInt32: String]()
        for (e, ls) in leaders {
            for l in ls where map[l] == nil || l == e { map[l] = Translator.fname(e, names) }
        }
        for (e, _) in functions { map[e] = Translator.fname(e, names) }
        return map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}
