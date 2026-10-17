#!/bin/zsh
# disasm.sh <binfile> <baseHex> <outfile> <entryHex...>
set -e
BIN=$1; BASE=$2; OUT=$3; shift 3
HERE=${0:A:h}
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
PROJ=$(mktemp -d)
/opt/homebrew/Cellar/ghidra/*/libexec/support/analyzeHeadless "$PROJ" p -import "$BIN" \
  -processor 68000:BE:32:default -loader BinaryLoader -loader-baseAddr 0x$BASE \
  -noanalysis -scriptPath "$HERE/ghidra_scripts" -postScript DumpListing.java "${OUT:A}" "$@" \
  -deleteProject > "$PROJ.log" 2>&1 || { tail -30 "$PROJ.log"; exit 1; }
rm -rf "$PROJ" "$PROJ.log"
