"""Port of the backward bit-stream decruncher at $30024 of the game loader
(disk 0x400..0x1800, loaded to $30000 by the bootblock).  Ported line-by-line
from the Ghidra listing work/disasm/loader_30000.lst."""
import sys, struct

class Bits:
    def __init__(s, mem, a0, d0):
        s.m, s.a0, s.d0 = mem, a0, d0
    def rdl(s):
        s.a0 -= 4
        return struct.unpack_from('>I', s.m, s.a0)[0]
    def bit(s):
        c = s.d0 & 1; s.d0 >>= 1
        if s.d0 == 0:                      # refill: move.l -(a0),d0 ; X=1 ; roxr.l #1,d0
            v = s.rdl(); c = v & 1; s.d0 = (v >> 1) | 0x80000000
        return c
    def get(s, n):
        d2 = 0
        for _ in range(n): d2 = (d2 << 1) | s.bit()
        return d2

def decrunch(mem, a0_end, dest):
    """mem: bytearray covering the address space (index = address)."""
    b = Bits(mem, a0_end, 0)
    a2 = dest + b.rdl()                   # unpacked length
    b.d0 = b.rdl()
    a1 = dest
    while True:
        d2 = b.get(3)
        if d2:
            if d2 == 7:
                if b.bit() == 0: d2 = b.get(4) + 7
                else:
                    d2 = b.get(10)
                    if d2 == 0: d2 = b.get(18)
            for _ in range(d2):
                a2 -= 1; mem[a2] = b.get(8)
        if a1 >= a2: return a1, a2, b.a0
        d2 = b.get(2)
        if d2 == 0: d3, d1 = 2, 8
        elif d2 == 1:
            d3 = 3; d1 = 8 if b.bit() else 14
        else:
            if d2 == 2: d3 = 4
            else:
                x = b.get(2)
                d3 = b.get(8) if x == 3 else (b.get(2) + 7 if x == 2 else x + 5)
            if b.bit() == 0: d1 = 16
            else: d1 = 8 if b.bit() else 12
        off = b.get(d1)
        for _ in range(d3):
            a2 -= 1; mem[a2] = mem[a2 + off]

if __name__ == '__main__':
    adf, out = sys.argv[1], sys.argv[2]
    d = open(adf, 'rb').read()
    mem = bytearray(0x80000)
    mem[0x30000:0x31400] = d[0x400:0x1800]
    a3 = 0x30158
    src_len = struct.unpack_from('>I', mem, a3 + 8)[0]
    dest = struct.unpack_from('>I', mem, a3 + 4)[0]
    a0 = a3 + 0xc + src_len
    a1, a2, a0f = decrunch(mem, a0, dest)
    size = struct.unpack_from('>I', mem, a0 - 4)[0]
    print(f"dest ${dest:x} size ${size:x} final a2=${a2:x} a0=${a0f:x} (packed start ${a3+0xc:x})")
    open(out, 'wb').write(mem[dest:dest + size])
