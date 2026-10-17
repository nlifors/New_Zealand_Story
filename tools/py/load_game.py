"""Reproduce the crack's launcher at $76000 (work/disasm/game_76000.lst):
  - track loader: track T (= cyl*2+head) is ADF bytes T*5632..(T+1)*5632
  - load 3 tracks from T=$5B to $70000 (Degas PC1 loading picture)
  - load $32 tracks from T=$5E to $400, RLE-unpack in place ($7671e), patch
    word $40C6 = $6630, jmp $400."""
import sys, struct
TRK = 5632

def tracks(adf, t, n): return adf[t*TRK:(t+n)*TRK]

def unrle(src):
    d3, d1 = struct.unpack_from('>II', src, 0)
    p = src[8:8 + d1 + 1]
    esc = p[0]; i = 1; out = bytearray()
    while len(out) < d3 + 1:
        c = p[i]; i += 1
        if c != esc: out.append(c)
        else:
            v, n = p[i], p[i+1]; i += 2
            out += bytes([v]) * (n + 1)
    return bytes(out[:d3 + 1]), d1 + 9

if __name__ == '__main__':
    adf = open(sys.argv[1], 'rb').read(); od = sys.argv[2]
    open(f'{od}/title_pc1_70000.bin', 'wb').write(tracks(adf, 0x5b, 3))
    raw = tracks(adf, 0x5e, 0x32)
    game, used = unrle(raw)
    print(f"unpacked {len(game)} bytes (${len(game):x}) from {used} packed bytes; raw tail unused: {len(raw)-used}")
    print("original word at $40C6:", game[0x40c6-0x400:0x40c8-0x400].hex())
    open(f'{od}/game_400_unpatched.bin', 'wb').write(game)
