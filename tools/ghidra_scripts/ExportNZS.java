// Post-script: export a labelled listing and a function table.
// Args: <listing out> <functions out>
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;

public class ExportNZS extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(a[0]));
        Listing lst = currentProgram.getListing();
        SymbolTable st = currentProgram.getSymbolTable();
        FunctionManager fm = currentProgram.getFunctionManager();
        CodeUnitIterator it = lst.getCodeUnits(currentProgram.getMemory().getLoadedAndInitializedAddressSet(), true);
        boolean inData = false;
        while (it.hasNext()) {
            CodeUnit cu = it.next();
            Address ad = cu.getAddress();
            String plate = cu.getComment(CodeUnit.PLATE_COMMENT);
            Function f = fm.getFunctionAt(ad);
            if (f != null) out.printf("%n;================ %s ================%n", f.getName());
            if (plate != null) out.printf("; %s%n", plate.replace("\n", "\n; "));
            Symbol s = st.getPrimarySymbol(ad);
            if (s != null && f == null && (cu instanceof Instruction || !inData)) out.printf("%s:%n", s.getName());
            if (cu instanceof Instruction) {
                inData = false;
                out.printf("%08x  %s%n", ad.getOffset(), cu.toString());
            } else {
                if (s != null) { out.printf("%08x  ...data... %s%n", ad.getOffset(), s.getName()); inData = true; }
                else if (!inData) { out.printf("%08x  ...data...%n", ad.getOffset()); inData = true; }
            }
        }
        out.close();
        PrintWriter fo = new PrintWriter(new FileWriter(a[1]));
        for (Function f : fm.getFunctions(true)) {
            int callers = f.getCallingFunctions(monitor).size();
            fo.printf("%08x %6d %3d %s%n", f.getEntryPoint().getOffset(), f.getBody().getNumAddresses(), callers, f.getName());
        }
        fo.close();
    }
}
