I have an Amiga disk image of New Zealand Story in New Zealand Story.adf.
I want a faithful native macOS port in Swift, built by
reverse engineering the original program, so I can play it on this Mac.

Ground rules
- Faithful port, not a remake. Game logic must come from the original's
  disassembly and be checked against the original code wherever possible.
  When something is a guess or a stand-in, say so in the code and in your
  reports.
- Never commit or ship original game data. Graphics, sound, levels and text
  are read from my .adf at run time. Keep extracted files and disassembly
  output in gitignored folders.
- Tell me plainly what is verified, what is only ported from the disassembly,
  and what is approximate (timing, colours, anything you could not see or hear).
- You can't hear audio or watch the app run. Render frames to PNG and audio
  to WAV and inspect them, and ask me to listen and look.

Environment notes
- macOS, Swift 6, Command Line Tools only (no Xcode). Swift Testing needs
  `-plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/t
  via unsafeFlags in Package.swift.
- Ghidra is installed via Homebrew with openjdk@21; run it headless.
- Use AppKit for the window and AVAudioEngine/AVAudioSourceNode for sound.

Pitfalls from last time
- Find out what the disk really holds first: the startup-sequence, which
  programs run in what order, crack intros or loaders, crunched (packed)
  executables, and whether the main program is a hunk exe or a raw memory
  image (Populous's was a raw snapshot of a running game, so its static data
  was not pristine).
- Check the compiler conventions. Aztec C used 16-bit ints and A4-relative
  small data. Far calls via `jsr (d16,A4)` through a jump table. Ghidra's
  emulator treats `jsr (d16,An)` wrongly, so intercept those calls. The
  decompiler merges 16-bit stack arguments (`param_1._0_2_`); read the listing
  for real argument order.
- Hardware details matter: Paula sample latching and periods (PAL clock
  3546895 Hz), 50 Hz vertical-blank pacing, hardware-sprite pointers taking
  colours 16-31, copper palettes.
- The original's frame rate is often not obvious. Measure it from the code
  if you can; otherwise mark it as an estimate.
- Pin behaviour with tests: compare against emulator dumps, then fingerprint
  long runs so regressions show up.

Plan
1. Inspect the ADF: list files, identify programs, crunchers, formats.
   Report what you find and propose a roadmap before writing much code.
2. Asset pipeline in Swift (decode graphics, palettes, sounds, levels, text),
   plus a CLI that dumps them to PNG/WAV for checking.
3. Disassembly in Ghidra, recovering names into a symbols file.
4. Static world and rendering, checked against rendered frames.
5. Game rules / simulation, verified against the emulated original.
6. The remaining game systems (enemies, powers, scoring, levels).
7. Audio (sequencer/effects as the original drives them).
8. Original screens and UI (title, menus, dialogs, pointer), save/load, then
   Mac polish: menu bar, full screen, remembered disk path, a make-app.sh
   that builds an .app containing no game data.

Start with step 1 and show me what's on the disk.