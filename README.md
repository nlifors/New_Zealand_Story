```
 ████████╗██╗  ██╗███████╗   ███╗   ██╗███████╗██╗    ██╗
 ╚══██╔══╝██║  ██║██╔════╝   ████╗  ██║██╔════╝██║    ██║
    ██║   ███████║█████╗     ██╔██╗ ██║█████╗  ██║ █╗ ██║
    ██║   ██╔══██║██╔══╝     ██║╚██╗██║██╔══╝  ██║███╗██║
    ██║   ██║  ██║███████╗   ██║ ╚████║███████╗╚███╔███╔╝
    ╚═╝   ╚═╝  ╚═╝╚══════╝   ╚═╝  ╚═══╝╚══════╝ ╚══╝╚══╝

███████╗███████╗ █████╗ ██╗      █████╗ ███╗   ██╗██████╗
╚══███╔╝██╔════╝██╔══██╗██║     ██╔══██╗████╗  ██║██╔══██╗
  ███╔╝ █████╗  ███████║██║     ███████║██╔██╗ ██║██║  ██║
 ███╔╝  ██╔══╝  ██╔══██║██║     ██╔══██║██║╚██╗██║██║  ██║
███████╗███████╗██║  ██║███████╗██║  ██║██║ ╚████║██████╔╝
╚══════╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═════╝

       ███████╗████████╗ ██████╗ ██████╗ ██╗   ██╗
       ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝
       ███████╗   ██║   ██║   ██║██████╔╝ ╚████╔╝
       ╚════██║   ██║   ██║   ██║██╔══██╗  ╚██╔╝
       ███████║   ██║   ╚██████╔╝██║  ██║   ██║
       ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝
```

```
                              ,
                             (_)
                              |
                        .-''''''''''-.
                    .-'                '-.
                  .'                      '.
                 /       .--.      .--.     \
                /       /    \    /    \     \
               |       |  .-. |  |  .-. |     |
               |       | (@  )|  | (@  )|     |
               |       |  '-' |  |  '-' |     |
               |        \    /    \    /      |
              _|___      '--'      '--'       |
             <_____\                          |
               \____)                         |
               |                              |
               |                              |
                \                            /
                 \                          /
                  '.                      .'
                    '-.__            __.-'
                         '--.____.--'
                         |  |    |  |
                     .--'   |    |   '--.
                    / ()  ()|    |()  ()  \
                   (________)    (________)
                ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

# The New Zealand Story — native macOS port

```
                    .--.
                 .-(    ).
                (___.__)__)
      @@@@@@@@
    @@########@@
   @###++++#####@   @@@@
  @##++++########@ @####@
 @##++############@@#####@
 @#################### o#@
@########################==
@##%########%###########@ ==
@######%###############@   ==
@##############%######@     =
 @##%################@
 @#######%##########@
  @###############@@
   @@###########@@
     @@@@@@@@@@
       |    |
       |    |
     ___  ___
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

A faithful port of the Amiga version of *The New Zealand Story* (Taito 1988;
Amiga conversion by Choice Software, code C. Gordon, graphics S. Connor) to
macOS, built by reverse engineering the original program.

This is a port, not a remake: the game logic is the original 68000 code,
translated to Swift and checked instruction by instruction against the
original running in an emulator.

**No game data is included.** Graphics, sound, levels and text are read from
your own disk image (`.adf`) at run time, and the translated program code is
generated from that same disk at build time. None of it is committed or put
in the app bundle.

## Requirements

- macOS 14 or later
- Swift 6 (the Command Line Tools are enough; Xcode is not needed)
- A disk image of the Amiga game, e.g. `Newzealand Story.adf`. The port was
  built from one specific (cracked) disk; other dumps may differ in layout.

## Build and play

```sh
./make-app.sh "Newzealand Story.adf"     # -> build/The New Zealand Story.app
open "build/The New Zealand Story.app"
```

The ADF argument defaults to `Newzealand Story.adf` in the project folder.
The first build takes a few minutes (the translated code is large).

On first launch the app asks for the disk image; it remembers it afterwards
(File ▸ Open Disk Image… to change it). To run without making a bundle:

```sh
tools/generate.sh "Newzealand Story.adf"   # once, and after changing the translator
swift run -c release NewZealandStory
```

### Controls

| | |
|---|---|
| Move | Arrow keys, or gamepad d-pad / left stick |
| Fire | Space, Option or Control, or gamepad A / B |
| Start game | Fire on the title screen |
| Pause | ⌘P |
| Reset | ⌘R |
| Save / load state | ⌘S / ⌘L (one quick-save slot) |
| Window size | ⌘2 / ⌘3 / ⌘4 |
| Full screen | ⌃⌘F |

High scores are kept between launches. Save states live in
`~/Library/Application Support/NewZealandStory/`.

### Original cheat

Type `MOTHERFUCKENKIWIBASTARD` on the title screen for 1000 lives. While it
is active, the Amiga Help key skips the level; on a Mac that is the Help /
Insert key (key code `0x72`), which most Mac keyboards lack.

## How it works

```
your .adf ──► NZSCore (disk, unpacking, asset formats)
         │
         ├─► nzs-recomp ──► Sources/NZSGame/Generated/*.swift   (gitignored)
         │     68000 code → one Swift function per original routine,
         │     original instruction as a comment on every line
         │
         └─► app: translated game  +  AmigaEmu (copper, bitplanes, sprites,
                                       blitter, Paula audio, CIAs)
```

- **Translation, not reinterpretation.** The game's timing matters: frame
  pacing depends on how long each update takes, the random seed mixes in
  register contents at the frame interrupt, and the screen flip happens at a
  particular raster line. So the original 68000 code is statically translated
  to Swift with its memory layout, stack and cycle counts preserved, rather
  than rewritten by hand. Self-modifying code (the cheat, the copy-protection
  check) is handled with run-time operands and opcode guards.
- **Lockstep verification.** `Sources/M68K` is a full 68000 interpreter
  (validated against the SingleStepTests suite). The translated port and the
  interpreter running the original are compared, whole machine state, every
  frame.
- **Hardware model.** The game drives the Amiga chipset directly (no OS), so
  `Sources/AmigaEmu` models the parts it uses.
- **Presentation.** Frames are shown on the Mac display's refresh, timed by
  the audio clock, so picture and sound stay together.

Details: [`docs/port-architecture.md`](docs/port-architecture.md).

## What is verified, ported, and approximate

**Verified**
- The whole game, from boot through all 20 levels to the ending, matches the
  original running in the reference emulator, frame for frame (RAM, CPU
  registers, cycle count, chip registers). Also 6,000 frames of random play
  on every level.
- Every translated instruction (8,649) matches the interpreter from about
  100,000 random states.
- The 68000 interpreter passes about 260,000 SingleStepTests cases (address-error
  cases and STOP's recorded PC excluded).
- Save → play → load → replay is byte-identical.
- Colours are exact (the game's ST palette words, doubled as the game does).

**Ported from the disassembly** (correct by construction, checked as above)
- All game logic, drawing, the sound driver, title / intro / map screens,
  high scores, the cheat, the copy-protection check.

**Approximate** (my model of the Amiga, not measured on real hardware)
- CPU and blitter timing: no wait states or DMA contention. The game runs at
  25 updates/s and drops to about 17 when busy; how often it drops is an
  estimate.
- Display: register changes take effect per scan line, not mid-line.
- Fine scroll: the BPLCON1 behaviour with the game's unaligned DDFSTRT is
  inferred from the game's own scroll code (it only scrolls smoothly under
  this model), not measured.
- Audio output filters approximate the A500's.
- Disk loading is instant (the original took seconds between levels).
- Keyboard: one key event per frame.
- A 50 Hz game on a 60/120 Hz Mac display cannot hold every frame for
  equal time, so motion is slightly less even than on a PAL monitor.

**Not tested**
- Reaching the ending by actually completing levels. The automated runs
  get there with the cheat's level-skip key.

## Project layout

| path | contents |
|---|---|
| `Sources/NewZealandStory` | the Mac app (AppKit window, menus, input, audio output) |
| `Sources/NZSGame` | runtime for the translated code; `Generated/` is created from your ADF |
| `Sources/AmigaEmu` | Amiga chipset model |
| `Sources/M68K` | 68000 interpreter (reference and fallback) |
| `Sources/NZSCore` | disk image, unpackers, asset formats, PNG/WAV writers |
| `Sources/NZSReference` | runs the original from the disk in the interpreter |
| `Sources/NZSRecomp`, `nzs-recomp` | the 68000 → Swift translator |
| `Sources/nzs-dump`, `nzs-ref`, `nzs-lockstep`, `m68k-sst` | command-line tools (below) |
| `Tests/` | asset, boot, translation, lockstep and save-state tests |
| `docs/` | disk layout, game structure, architecture, symbols |
| `tools/` | Ghidra and disassembly scripts, code generation, coverage |
| `work/` | extracted data, listings, renders (gitignored) |

## Tools

| command | purpose |
|---|---|
| `swift run nzs-dump <adf> <dir>` | decode assets to PNG / WAV (tiles, maps, sprites, pictures, samples, font) |
| `swift run -c release nzs-ref <adf> <dir> [options]` | run the original in the reference emulator; write frames, audio and traces (`--music N`, `--level N`, `--random`, `--hold r`, `--blits`, `--watch lo,hi`, …) |
| `swift run -c release nzs-lockstep <adf>` | translated port against the reference, whole machine compared every frame |
| `swift run -c release m68k-sst <dir>` | 68000 core against the SingleStepTests suite |
| `tools/disasm.sh`, `tools/ghidra_nzs.sh` | Ghidra headless listings with `docs/symbols.txt` applied |
| `tools/lst.sh <start> <end>` | print a range of the disassembly listing |
| `swift tools/make-icon.swift <out.icns>` | draw the app icon (original pixel art, not game graphics); run by `make-app.sh` |

## Tests

```sh
tools/generate.sh "Newzealand Story.adf"
swift test
```

The tests need the ADF in the project folder. The whole-game lockstep test
takes about 40 seconds.

## Documentation

- [`docs/disk-layout.md`](docs/disk-layout.md): boot chain, track layout, packers, asset formats
- [`docs/game-structure.md`](docs/game-structure.md): memory map, variables, objects, scripts, protection, cheat
- [`docs/port-architecture.md`](docs/port-architecture.md): how the port works and what is verified
- [`docs/symbols.txt`](docs/symbols.txt): names for the original's routines and data
