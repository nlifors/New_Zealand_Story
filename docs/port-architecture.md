# Port architecture and verification status

## Pieces
| module | role |
|---|---|
| `NZSCore` | ADF access, unpackers, asset decoders (verified) |
| `M68K` | 68000 interpreter: reference for tests and the translator's cycle oracle |
| `AmigaEmu` | PAL A500 chipset model: copper, bitplanes, sprites, blitter, Paula, CIAs |
| `NZSRecomp` + `nzs-recomp` | translator: 68000 code -> Swift |
| `NZSGame` | runtime for the translated code + generated sources |
| `NZSReference` | runs the original under the interpreter (reference) |
| `NewZealandStory` | the AppKit app (window, AVAudioEngine sound, input, menus, save states) |

## Why translation instead of a hand rewrite
The original is ~8,600 instructions of hand-written assembly whose behaviour
depends on instruction timing (frame pacing is load dependent; the VBL mixes
whatever is in D1 into the random seed; the screen flip happens at a raster
line). A translation that preserves the original's memory layout, stack and
cycle accounting lets the port be compared with the original *exactly*, frame
by frame, instead of approximately.

## How the translation works
* Code is found by control flow from known entries (symbols, interrupt
  handlers), execution coverage of the reference (`docs/code-entries.bin`,
  addresses only), handler pointers stored in object slots, animation-script
  "call" commands, and jump tables.
* Each routine becomes a Swift function with a `switch` over its block
  leaders; names come from `docs/symbols.txt`; every instruction keeps the
  original as a comment.
* Return addresses stay on the original 68000 stack in RAM. Swift calls are an
  optimisation: if a return goes elsewhere (the game pops return addresses or
  resets the stack) control unwinds to a dispatcher, so the original's control
  flow is always followed exactly.
* Cycle counts per instruction are taken from the interpreter itself, so
  interrupts arrive at the same instruction in both.
* Self-modifying code (found statically and dynamically): patched operands are
  read from memory at run time; instructions whose opcode can be overwritten
  are guarded and fall back to the interpreter if changed.
* Native replacements: the two track loaders (read the ADF) and the launcher's
  jump into the main image. The crack's two intros are not run.
* Safety net: an address the translator did not reach is run by the interpreter
  on the same state (logged); none occurs in normal play that was tested.

## What is verified, ported, or approximate
**Verified**
* Disk layout, boot chain, all decrunchers (exact unpack sizes).
* Asset formats: tiles, maps, sprite banks, pictures, 8SVX samples, font
  (rendered and compared with the emulated original's screens).
* 68000 interpreter: SingleStepTests (260k cases) except address-error cases
  (skipped) and STOP (a PC-recording artifact of the suite).
* Translation, instruction level: every translated instruction (8,649) matches
  the interpreter from ~100k random register/memory states (registers, flags,
  cycles, memory writes, next PC).
* Translation, whole game: identical complete machine state (RAM, registers,
  cycle count, chip registers) to the reference for 6,000 frames of random
  play on each of the 20 levels, the title, intro and the cheat code.
* Save states: save, play, load, replay gives byte-identical RAM.

**Ported from the disassembly (correct by construction, checked as above)**
* All game logic, drawing, sound driver, title/intro/map screens, high-score
  handling, cheat, copy-protection check.

**Approximate (hardware model, not measured against a real Amiga)**
* CPU timing: documented 68000 cycle counts, no wait states or DMA contention;
  the blitter is instantaneous and stalls the CPU for an estimated duration.
  Consequence: how often the game drops from 25 to ~17 updates per second
  under load is an estimate. Measured in the model (3000 frames of random
  play): level-table entry 0 almost always 25/s; entries 4 and 9 alternate between 2 and
  3 frames per update about half the time. Bitplane DMA stealing blitter
  slots is not modelled (would make real hardware slower), while the
  blitter's busy time is half its HRM duration when BLTPRI is off (makes the
  model faster). Net error unknown.
* Presentation (app): frames are shown on the Mac display's refresh (display
  link), timed by the audio clock. 50 Hz frames on a 60/120 Hz display cannot
  be shown for equal times, so motion is not as even as on a PAL monitor.
* Time-dependent hardware reads (beam position, blitter busy) use the cycle
  count at the start of the instruction.
* Display: copper and register changes take effect per scan line, not
  mid-line; sprite horizontal alignment uses the standard HSTART+1 relation.
* Lowres fine scroll (BPLCON1): modelled as the shifter loading on a fixed
  16-pixel beam grid where position matches the delay. With the game's
  unaligned DDFSTRT ($34) delays 8-15 land 16 pixels earlier than a plain
  "add the delay" model. INFERRED from the game: its scroll formula
  ((7 - x) & 15 over 16-pixel tile columns, draw_map $B55C) only scrolls
  smoothly under this model (the plain model shook 16 px side to side).
  Not measured on hardware.
* Audio: Paula sample stepping is exact in period; output filter is an
  approximation of the A500 RC/LED filters; volume is linear.
* Disk loading is instant (the original took seconds between levels).
* Keyboard: one key event per frame.
* Colours: exact (ST palette words doubled exactly as the game does).

**Not covered / untested**
* Reaching the ending and later boss fights through real play has not been
  exercised by the automated runs (random play does not finish levels); the
  translation covers that code statically, and the interpreter safety net
  would catch anything missed.
