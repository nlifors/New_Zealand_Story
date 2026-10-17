"""Decode the loading picture exactly as the launcher does ($766ac / $7604a):
word 0 = resolution, 16 ST-format palette words (each doubled into COLORxx),
then per-scanline, per-plane PackBits rows of 40 bytes (Degas Elite .PC1)."""
import sys, struct, zlib
def png(path, w, h, rgb):
    raw = b''.join(b'\0' + bytes(rgb[y*w*3:(y+1)*w*3]) for y in range(h))
    ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))
src = open(sys.argv[1], 'rb').read()
pal = []
for i in range(16):
    v = (struct.unpack_from('>H', src, 2 + 2*i)[0] * 2) & 0xfff        # add.w d1,d1
    pal.append(tuple(((v >> s) & 15) * 17 for s in (8, 4, 0)))
planes = [bytearray(40 * 200) for _ in range(4)]
i, line, plane, pos = 0x22, 0, 0, 0
while line < 200:
    c = src[i]; i += 1
    if c == 0x80: continue
    if c >= 0x80: n = 257 - c; out = bytes([src[i]]) * n; i += 1
    else: n = c + 1; out = src[i:i+n]; i += n
    for b in out:
        planes[plane][line*40 + pos] = b; pos += 1
        if pos == 40:
            pos = 0; plane += 1
            if plane == 4: plane = 0; line += 1
            if line == 200: break
rgb = bytearray()
for y in range(200):
    for x in range(320):
        bit = 7 - (x & 7); o = y*40 + (x >> 3)
        idx = sum(((planes[p][o] >> bit) & 1) << p for p in range(4))
        rgb += bytes(pal[idx])
png(sys.argv[2], 320, 200, rgb)
print("palette (Amiga $RGB after doubling):", ' '.join('%03x' % ((struct.unpack_from('>H', src, 2+2*i)[0]*2)&0xfff) for i in range(16)))
