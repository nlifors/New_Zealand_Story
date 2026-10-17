// nzs-recomp: translate the original game's 68000 code into Swift.
// Usage: nzs-recomp <adf> <symbols.txt> <coverage.bin|-> <outdir>
// Reads code from the user's ADF; the output directory receives Swift sources.
import Foundation
import NZSCore
import NZSRecomp

@main
struct NZSRecompTool {
    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        let disk = try DiskImage(contentsOf: URL(fileURLWithPath: args[1]))

        // Memory as the code sees it: launcher at $76000, main image after the
        // kernel's 4-byte self-relocation at $400.
        var mem = [UInt8](repeating: 0, count: 0x80000)
        let launcher = try GameDisk.launcher(disk)
        for (k, b) in launcher.enumerated() { mem[0x76000 + k] = b }
        let main = try GameDisk.mainImage(disk)
        for (k, b) in main.enumerated() { mem[0x400 + k] = b }
        for k in 0..<(0xb84 * 4) { mem[0x400 + k] = main[4 + k] }      // the copy loop at $3218

        // symbols
        var names = [UInt32: String](), comments = [UInt32: String]()
        var cfg = Translator.Config()
        for raw in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n") {
            var line = String(raw)
            var comment: String?
            if let sc = line.firstIndex(of: ";") { comment = String(line[line.index(after: sc)...]).trimmingCharacters(in: .whitespaces); line = String(line[..<sc]) }
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 1, let a = UInt32(p[0], radix: 16) else { continue }
            if p.count >= 2 { names[a] = String(p[1]) }
            if let c = comment, !c.isEmpty { comments[a] = c }
            if p.count >= 3 && p[2] == "f" { cfg.entries[a] = names[a] ?? "" }
        }
        cfg.codeRanges = [0x400...0x31ff, 0x3218...0x3237, 0x4000...0x157cf, 0x76000...0x76b67]
        // The kernel's self-relocation loop (runs once from the pre-relocation image;
        // the copy does not touch $3218, so its bytes are the same afterwards).
        cfg.entries[0x3218] = "kernel_relocate"; names[0x3218] = "kernel_relocate"
        cfg.entries[0x76000] = "launcher_main"; names[0x76000] = "launcher_main"
        cfg.dynamicOperands = [0xb6c4, 0xb6ca, 0x4cc6, 0x4ee6, 0x4eea, 0x4eee, 0x4ef2, 0x6f1e, 0xb8dc]
        cfg.native = [
            0x767c4: "launcher track loader (HLE: copies tracks from the ADF)",
            0x76694: "launcher's jump into the main image (performs the $3218 self-relocation)",
            0x00c24: "kernel track loader (HLE: copies tracks from the ADF)",
        ]
        // sound driver command dispatch at $EBAA: word offsets relative to the table entry
        var ebaaTargets = [UInt32]()
        for idx in 0..<32 {
            let at = 0xebae + idx * 2
            let w = Int16(bitPattern: UInt16(mem[at]) << 8 | UInt16(mem[at + 1]))
            if w != 0 { ebaaTargets.append(UInt32(at + Int(w))) }
        }
        cfg.jumpTables[0xebaa] = ebaaTargets

        // code entries: text "ADDR FLAGS" (docs/code-entries.txt) or a raw coverage.bin
        if args[3] != "-" {
            var found = [UInt32]()
            if args[3].hasSuffix(".txt"), let text = try? String(contentsOfFile: args[3], encoding: .utf8) {
                for line in text.split(separator: "\n") where !line.hasPrefix(";") {
                    let p = line.split(separator: " ")
                    if p.count == 2, let a = UInt32(p[0], radix: 16), let fl = Int(p[1]), fl & 6 != 0 { found.append(a) }
                }
            } else if let cov = try? Data(contentsOf: URL(fileURLWithPath: args[3])) {
                for (i, b) in cov.enumerated() where b & 6 != 0 { found.append(UInt32(i * 2)) }
            }
            for a in found where cfg.codeRanges.contains(where: { $0.contains(a) }) { cfg.extraEntries.insert(a) }
        }

        // Iterate: handler addresses stored as immediates (object slots +$14/+$18,
        // interrupt vectors) become entries until nothing new appears.
        // Excluded constants that merely look like code addresses:
        // Object structure (stride $3A, table at $64380): +$14 animation script
        // (data), +$18 handler (code). Animation scripts can call code (command $4C).
        func r16(_ a: UInt32) -> UInt16 { UInt16(mem[Int(a)]) << 8 | UInt16(mem[Int(a) + 1]) }
        func r32(_ a: UInt32) -> UInt32 { UInt32(r16(a)) << 16 | UInt32(r16(a + 2)) }
        func isHandlerStore(_ i: Instr) -> Bool {
            switch i.dst {
            case .disp(_, 0x18, _)?: return i.kind == .move
            case .absW(0x70)?, .absW(0x6c)?, .absW(0x68)?, .absW(0x78)?: return true
            case .absL(let a, _)? where a >= 0x64380 && a < 0x64380 + 0x3a * 0x47: return (a - 0x64380) % 0x3a == 0x18
            default: return false
            }
        }
        func isScriptStore(_ i: Instr) -> Bool {
            if case .disp(_, 0x14, _)? = i.dst, i.kind == .move { return true }
            return false
        }
        var scriptsSeen = Set<UInt32>()
        func crawlScript(_ start: UInt32) -> Set<UInt32> {
            var code = Set<UInt32>(), work = [start]
            while let s0 = work.popLast() {
                if scriptsSeen.contains(s0) || s0 < 0x4000 || s0 >= 0x60000 { continue }
                scriptsSeen.insert(s0)
                var p = s0
                scan: for _ in 0..<512 {
                    let w = r16(p)
                    guard w & 0x8000 != 0 else { p += 2; continue }
                    switch Int(w & 0x7fff) {
                    case 0x00, 0x3c: break scan
                    case 0x1c: work.append(r32(p + 2)); break scan
                    case 0x24, 0x40, 0x48: p += 2
                    case 0x04, 0x08, 0x0c, 0x10, 0x14, 0x18, 0x20, 0x28: p += 4
                    case 0x44: p += 6
                    case 0x4c: code.insert(r32(p + 2)); p += 6
                    case 0x2c, 0x30, 0x34, 0x38: work.append(r32(p + 4)); p += 8
                    default: break scan     // not a script (or unknown command)
                    }
                }
            }
            return code
        }
        // Animation-script "call code" commands anywhere in the data: $804C + long.
        // ($804C is not a valid 68000 opcode, so this pattern does not occur in code.)
        for a in stride(from: 0x4000, to: 0x60000 - 6, by: 2) where r16(UInt32(a)) == 0x804c {
            let t = r32(UInt32(a + 2))
            if t >= 0x4000 && t < 0x157d0 && t & 1 == 0 { cfg.extraEntries.insert(t) }
        }
        // Raw scan for `move.l #imm,($18,An)` (handler) and `move.l #imm,($14,An)`
        // (animation script), so stores in code the flow analysis has not reached
        // still contribute entries.
        var rawScripts = [UInt32]()
        for a in stride(from: 0x4000, to: 0x157c0, by: 2) {
            let op = r16(UInt32(a))
            guard op & 0xf1ff == 0x217c else { continue }
            let imm = r32(UInt32(a + 2)), disp = r16(UInt32(a + 6))
            guard imm >= 0x4000 && imm < 0x157d0 && imm & 1 == 0 else { continue }
            if disp == 0x18 { cfg.extraEntries.insert(imm) }
            if disp == 0x14 { rawScripts.append(imm) }
        }
        var tr = Translator(memory: mem, config: cfg)
        tr.analyse()
        for sc in rawScripts { cfg.extraEntries.formUnion(crawlScript(sc).filter { $0 >= 0x4000 && $0 < 0x157d0 }) }
        tr = Translator(memory: mem, config: cfg)
        tr.analyse()
        while true {
            var add = Set<UInt32>()
            for (v, uses) in tr.immediateUses {
                if uses.contains(where: isHandlerStore) { add.insert(v) }
                if uses.contains(where: isScriptStore) { add.formUnion(crawlScript(v)) }
            }
            add.subtract(tr.functions.keys)
            add = add.filter { a in cfg.codeRanges.contains { $0.contains(a) } }
            if add.isEmpty { break }
            cfg.extraEntries.formUnion(add)
            tr = Translator(memory: mem, config: cfg)
            tr.analyse()
        }
        // operands rewritten at run time (self-modifying code): read them from memory
        var smcAdded = Set<UInt32>()
        for (w, t) in Set(tr.selfModifyingWrites().map { [$0.0, $0.1] }).sorted(by: { $0[1] < $1[1] }).map({ ($0[0], $0[1]) }) where !cfg.dynamicOperands.contains(t) {
            smcAdded.insert(t); print(String(format: "self-modifying: $%06X writes into instruction $%06X", w, t))
        }
        cfg.opcodeGuards = tr.opcodeTargets
        print("opcode guards:", tr.opcodeTargets.sorted().map { String(format: "$%06X", $0) }.joined(separator: " "))
        if !smcAdded.isEmpty || !cfg.opcodeGuards.isEmpty {
            cfg.dynamicOperands.formUnion(smcAdded)
            tr = Translator(memory: mem, config: cfg); tr.analyse()
        }
        print("functions: \(tr.functions.count), instructions: \(tr.instrs.count)")
        for w in Set(tr.warnings).sorted().prefix(40) { print("warning:", w) }
        let unknownImm = tr.candidateImmediates.subtracting(tr.functions.keys).sorted()
        print("animation scripts crawled: \(scriptsSeen.count)")
        for v in unknownImm where !(tr.immediateUses[v] ?? []).contains(where: isScriptStore) { print(String(format: "immediate $%X used by ", v) + tr.immediateUses[v, default: []].map { String(format: "$%X %@", $0.addr, $0.text) }.joined(separator: " | ")) }

        let out = args[4]
        try? FileManager.default.removeItem(atPath: out)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let header = """
        // GENERATED by nzs-recomp from the original game code on the user's disk.
        // Do not edit: change docs/symbols.txt or the translator and regenerate.
        import M68K

        """
        let entries = tr.functions.keys.sorted()
        var chunk = [String](), fileNo = 0, size = 0
        func flush() throws {
            guard !chunk.isEmpty else { return }
            try (header + chunk.joined(separator: "\n") + "\n").write(toFile: "\(out)/Code\(String(format: "%02d", fileNo)).swift", atomically: true, encoding: .utf8)
            fileNo += 1; chunk.removeAll(); size = 0
        }
        for e in entries {
            let f = tr.emitFunction(e, names: names, comments: comments)
            chunk.append(f); size += f.count
            if size > 150_000 { try flush() }
        }
        try flush()
        var disp = header + "/// Enter original code at any known entry or block leader.\nfunc dispatchOriginal(_ c: CPU, _ rt: Runtime, _ addr: UInt32) throws -> UInt32? {\n    switch addr {\n"
        for (a, fn) in tr.dispatchTable(names: names) { disp += "    case \(String(format: "0x%x", a)): return try \(fn)(c, rt, \(String(format: "0x%x", a)))\n" }
        disp += "    default: return nil\n    }\n}\n"
        disp += "\n/// Addresses translated code can be (re)entered at.\nlet dispatchEntries: Set<UInt32> = [" + tr.dispatchTable(names: names).map { String(format: "0x%x", $0.0) }.joined(separator: ", ") + "]\n"
        try disp.write(toFile: "\(out)/Dispatch.swift", atomically: true, encoding: .utf8)
        try (header + tr.emitSnippets() + "\n").write(toFile: "\(out)/Snippets.swift", atomically: true, encoding: .utf8)
        print("wrote \(fileNo) code files to \(out)")

    }
}
