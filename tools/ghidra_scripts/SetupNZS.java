// Pre-script: add RAM above the image and the custom chip / CIA blocks, apply
// symbols from docs/symbols.txt (lines: HEXADDR NAME [f] [; comment]), mark
// entry points ("f" = function).
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.listing.*;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.function.CreateFunctionCmd;
import java.io.*;
import java.util.*;

public class SetupNZS extends GhidraScript {
    @Override
    public void run() throws Exception {
        String symFile = getScriptArgs()[0];
        Memory mem = currentProgram.getMemory();
        AddressSpace sp = currentProgram.getAddressFactory().getDefaultAddressSpace();
        long end = mem.getMaxAddress().getOffset() + 1;
        end = (end + 0xfff) & ~0xfff;
        if (mem.getBlock(sp.getAddress(0)) == null)
            mem.createUninitializedBlock("vectors", sp.getAddress(0), 0x400, false);
        mem.createUninitializedBlock("ram", sp.getAddress(end), 0x80000 - end, false);
        mem.createUninitializedBlock("cia", sp.getAddress(0xbfd000), 0x2000, false);
        mem.createUninitializedBlock("custom", sp.getAddress(0xdff000), 0x200, false);
        SymbolTable st = currentProgram.getSymbolTable();
        Listing lst = currentProgram.getListing();
        BufferedReader r = new BufferedReader(new FileReader(symFile));
        String line;
        List<Address> funcs = new ArrayList<>();
        while ((line = r.readLine()) != null) {
            String comment = null;
            int sc = line.indexOf(';');
            if (sc >= 0) { comment = line.substring(sc + 1).trim(); line = line.substring(0, sc); }
            line = line.trim();
            if (line.isEmpty()) continue;
            String[] p = line.split("\\s+");
            Address a = sp.getAddress(Long.parseLong(p[0], 16));
            if (p.length > 1) st.createLabel(a, p[1], SourceType.USER_DEFINED).setPrimary();
            if (p.length > 2 && p[2].equals("f")) funcs.add(a);
            if (comment != null && !comment.isEmpty()) lst.setComment(a, CodeUnit.PLATE_COMMENT, comment);
        }
        r.close();
        // dynamic coverage from the reference emulator: "ADDR FLAGS" (1 exec, 2 call target, 4 jump target)
        if (getScriptArgs().length > 1) {
            BufferedReader cr = new BufferedReader(new FileReader(getScriptArgs()[1]));
            AddressSet exec = new AddressSet();
            while ((line = cr.readLine()) != null) {
                String[] p = line.trim().split("\\s+");
                long ad = Long.parseLong(p[0], 16); int fl = Integer.parseInt(p[1]);
                Address a = sp.getAddress(ad);
                if ((fl & 1) != 0) exec.add(a);
                if ((fl & 2) != 0) funcs.add(a);
            }
            cr.close();
            new DisassembleCommand(exec, null, true).applyTo(currentProgram, monitor);
        }
        for (Address a : funcs) {
            new DisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
            new CreateFunctionCmd(a).applyTo(currentProgram, monitor);
        }
    }
}
