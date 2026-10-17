#!/bin/zsh
# Translate the original game code from your ADF into Swift (Sources/NZSGame/Generated).
# The output is derived from the original program and is gitignored.
set -e
ROOT=${0:A:h}/..
ADF=${1:-$ROOT/Newzealand Story.adf}
COV=$ROOT/docs/code-entries.txt
[ -f "$COV" ] || COV=-
cd $ROOT
swift build -c release --product nzs-recomp
.build/release/nzs-recomp "$ADF" docs/symbols.txt "$COV" Sources/NZSGame/Generated
