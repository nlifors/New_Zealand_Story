# Disk layout — "Newzealand Story.adf" (Accumulators crack, 20/07/89)

No AmigaDOS filesystem: a custom bootblock plus loaders reading raw sectors.
"Track" T below = cylinder*2+head = ADF bytes T*5632 .. (T+1)*5632.
Everything was traced from code (listings in work/disasm/); tools in tools/py/.

## Boot chain (all verified by disassembly + successful unpack)
1. Bootblock (crack): DoIO reads disk 0x1800..0x2800 to $16000, NOT.b every byte, jmp $16000.
2. $16000 (crack, "Telstar" intro): unpacks + runs intro at $18000, then runs the
   *game's* bootblock image stored at $16818.
3. Game bootblock: DoIO disk 0x400..0x1800 to $30000, jmp $30000.
4. $30000 is a hunk exe loaded raw (the header longs execute as harmless ORI.B).
   Backward bit-stream decruncher (tools/py/decrunch_loader.py) -> $5E900, 0x29E4 bytes.
5. $5E900: jsr $60000 (Accumulators/Chameleon intro with trainer prompt), then copies
   launcher to $76000.
6. Launcher ($76000, cracker's "pseudo-DOS" track loader, standard AmigaDOS MFM sectors):
   - tracks 91..93 -> $70000: loading picture, Degas Elite PC1 (ST palette, doubled).
   - tracks 94..143 -> $400: main image, simple escape-byte RLE (tools/py/load_game.py),
     338855 bytes covering $400..$52FA7. Word $40C6 "patched" to $6630 (already that value).
   - jmp $400.

## Main image ($400..$52FA7) — raw memory image, hand-written 68000 asm (not compiled C)
- $400..$3204: resident kernel; on entry copies itself down 4 bytes. Jump table:
  $404, $408 (input, called from VBL), $40C (track load: D0=track D1=count D2=drive A0=dest),
  $410, $414. Contains keyboard tables and a "CBM Amiga Monitor V3.5" debugger.
  The disk reader inside is the cracker's DOS-sector version.
- $4000: game entry (pointer at $15B0). Globals base A6 = $641B8 (outside image = BSS).
- VBL (level 3) handler $BDD8; calls $408 (input) and $E80C (likely music/sfx — unverified).
- Palettes are Atari ST words doubled (add.w d0,d0) into a copper list at $C328 ($BEFE).

## Level data (table at $5DBA, 20 entries x 16 bytes: 3 longs ptrs, trackA, trackB)
- trackA: 5 tracks, RLE (same format as main image) -> $3CAA6 — per-world graphics set.
- trackB: 1 track, raw -> $44AA6 — map, header "01", width $40, height.
- Boss graphics (levels 3,7,11,15,19): 2 tracks -> $6C000 from bytes at $418C:
  158,156,154,(none),152.
- Tracks 144..148: 5 tracks -> $3CAA6 (code at $43F4; purpose not yet known).

| tracks | contents |
|---|---|
| 0 | crack bootblock, game bootblock-loaded file (packed intro+launcher) |
| 1 | crack Telstar intro (sectors 12..19) |
| 2..89 | level gfx sets and maps (see table) |
| 91..93 | loading picture |
| 94..143 | main image |
| 144..159 | tracks 144.. data, boss gfx 152..159 |

## Assets found so far (decoders in Sources/NZSCore/Formats.swift; `nzs-dump` writes PNG/WAV)
| asset | where | format | status |
|---|---|---|---|
| world graphics sets | trackA x5, RLE | "01", 16 ST palette words, params, 16x16 tiles ST-interleaved 128 B | tiles verified (blit log + map render matches emulator); header params unknown |
| level maps | trackB | 128-byte header (w,h), bytes stored bottom row first | verified |
| tile collision codes | table ptr1 of level entry | word per tile = four 4-bit 8x8 codes | layout verified, code meanings unknown |
| main sprites | data $22AA6, table $39AA6 (289) | 16-byte table entries; ST 5-word groups (mask+4 planes) | verified |
| intro sprites | data $3CAA6, table $4CAA6 (15) | same | shapes verified, palette not yet |
| map-screen cards | tracks 144-148: table $3CAA6 (5), data $3CAF6 | same | verified |
| boss sprites | tracks 158/156/154/152 -> $6C000, table +$2A00 | same | shapes verified, palette not yet |
| pictures | loading (tracks 91-93), zoo intro (PC1 at $4CCA6), NZ map (tracks 144-148 +$3556, palette $C1AA) | Degas PC1 / PackBits | verified |
| samples | 18 IFF 8SVX FORMs in the image ($F42C..$20676) | standard | verified |
| music | driver $E800 (init $F10E, play $E808, VBL tick $E80C), 12 tunes, table $157D0, patterns $15830 | not yet decoded | reference WAVs recorded from the emulated original |
| font | $DA66, 96 x 8x8 1bpp | strings: x column, y pixel, control codes | verified on title screen |
