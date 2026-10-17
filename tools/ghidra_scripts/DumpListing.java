// Disassemble from given entry points (script args, hex) and print a flat listing.
// Usage: -postScript DumpListing.java <outfile> <entry1> [entry2 ...]
import ghidra.app.script.GhidraScript;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import java.io.*;

public class DumpListing extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(a[0]));
        AddressSpace sp = currentProgram.getAddressFactory().getDefaultAddressSpace();
        AddressSet starts = new AddressSet();
        for (int i = 1; i < a.length; i++) starts.add(sp.getAddress(Long.parseLong(a[i], 16)));
        DisassembleCommand cmd = new DisassembleCommand(starts, null, true);
        cmd.applyTo(currentProgram, monitor);
        Listing lst = currentProgram.getListing();
        Memory mem = currentProgram.getMemory();
        CodeUnitIterator it = lst.getCodeUnits(true);
        boolean inData = false;
        while (it.hasNext()) {
            CodeUnit cu = it.next();
            if (cu instanceof Instruction) {
                inData = false;
                Instruction ins = (Instruction) cu;
                StringBuilder hb = new StringBuilder();
                for (byte b : ins.getBytes()) hb.append(String.format("%02x", b & 0xff));
                out.printf("%08x  %-20s %s%n", ins.getAddress().getOffset(), hb, ins.toString());
            } else if (!inData) {
                inData = true;
                out.printf("%08x  ...data...%n", cu.getAddress().getOffset());
            }
        }
        out.close();
    }
}
