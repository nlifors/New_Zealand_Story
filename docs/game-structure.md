# Game structure (recovered from the disassembly)

The Amiga New Zealand Story (Choice Software for Ocean, 1989) is hand-written
68000 assembly ported from the Atari ST version: every palette is in ST format
and doubled at run time, and all graphics are stored in ST interleaved layout
and converted to Amiga planes when loaded. Names below are in `docs/symbols.txt`
and appear in the generated code. "?" marks a role that is inferred, not proven.

## Memory map (512 KB chip RAM, no OS)
| range | contents |
|---|---|
| $000-$3FF | vectors; the stack grows down from $400 |
| $400-$3200 | resident kernel: jump table ($404 key down, $408 joystick, $40C load tracks, $414 next key), keyboard interrupt, disk loader, debugger ("CBM Amiga Monitor") |
| $4000-$F400 | game code; tables and animation scripts are interleaved with it |
| $E800-$F400 | sound driver (init $F10E, play $E808, tick from the VBL $E80C) |
| $F42C-$20676 | 18 IFF 8SVX samples (4 music instruments, 2 percussion, 12 effects) |
| $157D0 / $15830 | tune table (12 tunes) / pattern table |
| $22AA6 / $39AA6 | main sprite bank data / table (289 images) |
| $3CAA6.. | at boot: intro sprite bank (table $4CAA6) and the zoo picture ($4CCA6); later reused for the world graphics set and the map screen |
| $44AA6 | level map (128-byte header + rows, bottom row first) |
| $462A6 | 8x8 collision-code grid built from the map ($C5C0) |
| $64380 | object table: $47 slots x $3A bytes (slot 1, $643BA, is the player) |
| $641B8 | global variables (A6 base, see below) |
| $68000 | 32 KB scratch (picture unpacking, boss graphics at $6C000) |
| $70000 / $78000 | the two display buffers (4 planes x $2000, 320 x 200) |

## Frame structure
* VBL ($BDD8): input ($408), random-seed mixing, VBL countdown (0x24,A6), music tick.
* Level-6 interrupt ($BE8A) from CIA-B: timer B decrements (0x00,A6) about twice a
  second; the TOD alarm (counting scan lines) fires at the panel split line and
  applies a pending buffer flip (copies bitplane pointers into the copper list).
* Main loop (`level_loop`, $4298): `update_spawn_points`, `run_object_handlers`,
  `camera_follow_player`, `wait_flip_done`, `draw_map`, `animate_objects` (also
  draws), `draw_oxygen_bar`, `request_flip`. There is no fixed frame rate: one
  iteration takes 2 frames (25 Hz) in most of the game and 3 when busy
  (measured in the reference emulator, whose timing is an estimate).

## Global variables (offsets from A6 = $641B8)
| offset | meaning |
|---|---|
| $00 | countdown decremented by CIA-B timer B (~2 Hz) ? |
| $04/$06 | text cursor x (8 px columns) / y (pixels) |
| $08 | level number x 16 (0..19) |
| $0A, $0E/$10 | camera limits (y, x) |
| $0C | map offset of the bottom row ((h-1) x 64) |
| $12 | set by the VBL (wait_vbl) |
| $14 | panel split line |
| $16 | current palette pointer |
| $1A | lives (the cheat sets 1000) |
| $20 | draw buffer address ($70000/$78000, swapped by request_flip) |
| $24 | VBL countdown |
| $2C | start level |
| $2E / $30 | camera x / y (pixels) |
| $36, $3A, $3C | fine scroll: $36 = (x&15)+1 (object offset), $3A = (7-(x&15))&15, $3C = BPLCON1 ($3A in both nibbles, written into the copper list at flip). Map drawn in 16-px columns at x>>4; display DDFSTRT $34 |
| $6E | oxygen (0..$136), refilled on land |
| $70 | intro sequence step |
| $84 / $88 | bob table pointer / count |
| $8E | bob clip limit (bottom) |
| $94 | 50000 (score threshold?) |
| $B0 | free dynamic object slots |
| $C6 | spawn-point table (32 object pointers) |

## Objects ($3A bytes)
| offset | field |
|---|---|
| +$00 / +$02 | x / y (pixels) |
| +$04 / +$06 | dx / dy |
| +$10 | facing (flipped with `not.b`) |
| +$12 | current frame (image number) |
| +$14 | animation script pointer |
| +$18 | handler (code, called by `run_object_handlers`; 0 = free) |
| +$1C | object type |
| +$1E / +$20 | frame delay counter / reload |
| +$22 | script position |
| +$24 / +$25 | loop position / loop count |
| +$26 | linked object (rider / vehicle) |
| +$2E | life timer |

## Animation scripts (interpreted by `animate_objects`)
Word stream; a word without bit 15 is a frame number. Commands ($8000 | n):
$00 restart, $04/$08 set dx/dy, $0C/$10 add to x/y, $14/$18 set x/y,
$1C goto script, $20 set loop count, $24 loop, $28 set frame delay,
$2C/$30/$34/$38 conditional goto on x or y, $3C remove object, $40 flip,
$44 set field, $48 clear delay, $4C call code (used by enemies and effects).

## Copy protection and cheat
* `copy_protection_check` ($A742) decodes the value the loader leaves in the
  trace vector ($24). If it is wrong it overwrites the start of $65A8 so the game
  misbehaves. The crack's launcher supplies the expected value; so does the port.
* `title_wait_and_cheat` ($B9F0) compares keys typed on the title screen with a
  hidden list (raw key codes XOR $41) at $45B4: MOTHERFUCKENKIWIBASTARD. When it
  matches, the "3" in `new_game` is rewritten to 1000 lives and a sound plays.
