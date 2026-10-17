#!/bin/zsh
# Full re-analysis of the main image with docs/symbols.txt applied.
# Outputs work/disasm/nzs.lst (labelled listing) and work/disasm/functions.txt
set -e
HERE=${0:A:h}; ROOT=$HERE/..
# coverage.bin (from nzs-ref --coverage) -> address list for the pre-script
python3 -I -c "
import sys
d=open(sys.argv[1],'rb').read()
with open(sys.argv[2],'w') as f:
    for i,b in enumerate(d):
        if b and 0x400 <= i*2 < 0x53000: f.write('%x %d\n'%(i*2,b))
" $ROOT/work/ref/cov/coverage.bin $ROOT/work/disasm/coverage.txt
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
PROJ=$(mktemp -d)
/opt/homebrew/Cellar/ghidra/*/libexec/support/analyzeHeadless "$PROJ" p -import $ROOT/work/extracted/game_400_reloc.bin \
  -processor 68000:BE:32:default -loader BinaryLoader -loader-baseAddr 0x400 \
  -scriptPath "$HERE/ghidra_scripts" -preScript SetupNZS.java $ROOT/docs/symbols.txt $ROOT/work/disasm/coverage.txt \
  -postScript ExportNZS.java $ROOT/work/disasm/nzs.lst $ROOT/work/disasm/functions.txt \
  -deleteProject > $PROJ.log 2>&1 || { tail -40 $PROJ.log; exit 1; }
grep -E "ERROR|Exception" $PROJ.log | head -5
rm -rf $PROJ $PROJ.log
