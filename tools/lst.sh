#!/bin/zsh
# lst.sh <startHex> <endHex> [listing]  — print listing lines with start <= addr < end
L=${3:-${0:A:h}/../work/disasm/game_400.lst}
python3 -I -c "
import sys
s,e=int(sys.argv[1],16),int(sys.argv[2],16)
for l in open(sys.argv[3]):
    a=int(l[:8],16)
    if s<=a<e: print(l,end='')
" $1 $2 $L
