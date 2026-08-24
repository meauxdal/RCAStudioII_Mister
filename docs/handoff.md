# Handoff — start here

You are taking over an RCA Studio II core for MiSTer that also runs three
related machines. It works. This document is orientation: what state it is in,
what is *proven* versus merely *believed*, what will bite you, and what to do
next.

Read this, then `CLAUDE.md` (the working reference), then the specific document
for whatever you are about to touch.

| Document | What it is for |
|---|---|
| `CLAUDE.md` | The working reference: hardware facts, file map, build, conventions, and a dated changelog in §10 that explains *why* the odd things are the way they are. |
| `docs/succession-plan.md` | The four machines: what each is, how each was implemented, what was measured. §8 analog video, §9 NTSC Studio III, §10 Studio IV (out of scope), §11 Visicom. |
| `docs/analog-video.md` | The one unfinished feature with real hardware risk. Implementation state, test procedure, failure table. |
| `Readme.md` | User-facing: controls, cartridge compatibility, BIOS hashes, limitations. |
| `docs/how-to-play.md` | Per-title controls. |
| `docs/*.txt` | Scraped hardware notes (I/O map, memory map, video, sound, cartridge format). |

---

## 1. What this is, in one paragraph

A CDP1802 ("COSMAC") console core. The CPU is a real 1802 with interrupts and
DMA at machine-cycle timing; the video is a real CDP1861/1864 driven by DMA with
**no frame buffer** — the 1802 streams display bytes through `R(0)` eight per
scanline and the video part shifts them out as pixels. Four machines share that
spine: Studio II (1861, NTSC, mono), Studio III PAL (1864 — video, colour and
tone in one part), Studio III NTSC (1861 + 1862 colour + 1863 tone — a different
chipset, not the same part retimed) and the Toshiba Visicom COM-100 (1861, but
colour from a second bit plane `$200` above the first).

---

## 2. State: proven vs believed

This distinction matters more than the feature list. Everything in the first
table has a script that will fail if you break it. Everything in the second does
not.

### Proven — run these before and after any change

| Script | Covers | Expect |
|---|---|---|
| `tools/memdecode-test.sh` | the memory decode, which **no cartridge in the corpus exercises** | 8/8 |
| `tools/tone-test.sh` | the CDP1863/1864 tone divider, which no frame can show | 7/7 |
| `tools/visicom-test.sh` | the Visicom, which has no reference emulator | all ok |
| `tools/score-21.sh` | Studio II vs the reference emulator, documented start sequences | 26/48 |
| `tools/score-conic.sh` | Studio III PAL vs the reference emulator, uniform A1 | 22/38 |
| `cd verilator && make lint` | — | 0 errors |

The last two are comparisons against `tools/refemu` and will move if its cycle
model does. The first three are directed tests and **should not move at all**.

`tools/contact-sheet.py` renders the whole library side by side with a per-title
percentage of differing scanlines — the way to tell "different game state" from
"broken" when a score moves.

### Known broken on hardware (first real-hardware run, 2026-08-19)

- **RESOLVED same day — root cause was CLEAR desynchronising the machine-cycle
  grid.** The CLEAR carve-out keeps the pixie's counters running while the CPU
  resets, and `cpu_div` used to zero on CLEAR, so on release the machine-cycle
  grid re-locked at an arbitrary pixel phase — silicon can't do that (CLEAR
  resets 1802 and 1861 together, CLAUDE.md §2.1). Reproduced by wiring CLEAR
  into the sim (`verilator/sim.v`) and sweeping the release phase with
  `--press-phase`: 3 of 8 phases left the Visicom blank or rotated. Fixed by
  giving `cpu_div` the pixie's own reset (`reset & ~clear_key`) so the grids
  stay locked through CLEAR; all 8 phases now render byte-identically, and the
  full battery (26/48, 22/38, visicom, tone, memdecode, lint) is unchanged.
  Gambler's manual says "press CLEAR" before playing, which is how hardware
  kept drawing bad tickets. The original description, kept for the record:

- **Visicom: the display is rotated by 13 bytes on the FPGA, and is clean in
  sim.** First observed by Alan playing Gambler I on a DE10: the dealer's card
  was split across the top/bottom edge of the bitmap and a stake number was
  split across the left/right edge. Decoding the framebuffer screenshot against
  the game's true layout (from the sim, which matches VRAM byte-for-byte)
  shows every element displaced by exactly **+13 bytes with wraparound** —
  the display renders `vram[i+13]`, i.e. the effective base is `$090D`.
  Constant across the session, both bit planes together, colours intact —
  so it is the Visicom BIOS ISR's display-base arithmetic locking to a
  different orbit on hardware, the same phase-lock family as the Hockey/
  Combat strobes (`CLAUDE.md` §10 2026-08-16), not a pixel-pipe bug.
  The sim cannot see it with `ce_pix` tied high; a first `--ce4` harness mode
  (run the FPGA's /4 enable, `verilator/sim.v` + `--ce4`) reproduces the
  hardware *clock structure* but still comes up clean — the missing degree of
  freedom is presumably the divider/counter phase at reset release, which is
  deterministic in sim and not on hardware (or interacts with the OSD machine
  switch). Next steps: give the harness a phase-offset knob (preset `ce_cnt`
  and the cpu_ce divider at reset), sweep all 32 phases over the Visicom CUT
  screen, and if one reproduces the +13 orbit, extend the INT/EFx-lead +
  parity-resync tolerance analysis (swept for the Studio II BIOS only) to the
  Visicom BIOS ISR. Studio II mode on the same build is verified clean on
  hardware (Invaders/Hockey/Combat, 2026-08-16).

### Believed, but not covered by anything

- **Analog video.** Emitted, timings check out against the datasheet, never seen
  on a display. `docs/analog-video.md`.
- **The `status_set` OSD write-back** (the Joystick row showing the detected
  profile). Verilator has no HPS, so this is untested in sim.
- **Audio**, beyond frequency. The beeper and tone divider are measured in Hz;
  nobody has listened on hardware.
- **Anything above `$0FFF` in a cartridge.** The `.st2` loader only models one
  4 K bank. The RCA test cartridge (`ST3CTA Tester 3.st2`) pages `$24-$2F` and
  therefore loads nothing — see §5.
- **Real hardware in general.** The last build was measured for fit and timing,
  not run.

---

## 3. Things that will bite you

Each of these has already cost someone a day.

1. **`ce_pix` is a 4× divide, and the sim does not use it.** The FPGA top divides
   `clk_sys` (7.04 MHz) by 4 to get the 1.76 MHz machine timebase. The Verilator
   harness ties `ce_pix` high instead — one pixel per clock, identical frames, 4×
   cheaper. **Do not "fix" either side to match the other.** Tying it high on the
   FPGA once made the whole console run 4× too fast and was the root of most
   beta-tester complaints.

2. **The DMA phase is load-bearing.** The BIOS ISR counts cycles against the
   1861's DMA burst. Two separate bug classes have come out of moving it (the
   Invaders wobble, the Hockey/Combat strobes — `CLAUDE.md` §10, 2026-08-15 and
   2026-08-16). The bitmap is pinned at pixels `40..104` for this reason. If you
   need to move the picture, move the porches around it.

3. **A RAM can silently fall out of block memory.** On 2026-08-19 the 512-byte
   main RAM was found to be built entirely from logic — 6,119 ALUTs, 0 block
   memory bits — because a second write port made mixed-port read-during-write
   unimplementable on an M10K. It still fitted, still closed timing, and passed
   every test. Fixing it took the design from 44% of the device to 25%. **After
   changing anything about a memory's ports, check it still appears in the
   `Inferred altsyncram megafunction` list in `output_files/*.map.rpt`.**

4. **Quartus rewrites `Studio-II.qsf` on every build.** It breaks `git stash`
   around A/B builds, and `git add -A` after a build will sweep it into a commit.
   New sources belong in `files.qip` (and `verilator/Makefile`'s `V_SRC`), never
   the qsf, because the qsf is regenerated.

5. **Never run `quartus_sh --flow compile` in the Docker image.** The image is
   amd64 under emulation on Apple Silicon and `NUM_PARALLEL_PROCESSORS ALL` makes
   Quartus fork helpers that crash, leaving the parent deadlocked on named pipes
   at ~4% CPU forever. `tools/quartus-build.sh` passes `--parallel=1`. A healthy
   build sits at ~100% CPU.

6. **The Verilator Makefile does not track RTL edits.** If a `.v` change appears
   to do nothing, `rm -rf obj_dir obj_dir_headless` and rebuild. This has run
   stale binaries more than once.

7. **The shell here is zsh**, which does not word-split unquoted variables. A
   variable holding `--flag value` arrives as one argument.

---

## 4. The reference emulator, and what it cannot settle

Accuracy is checked against Paul Robson's C emulator, vendored at `tools/refemu`
(MIT) and extended here with an ST2 loader, a headless front end, PNG capture, a
trace and scripted keypresses.

Its cycle model was corrected in 2026-08-17 and now matches hardware's
instruction rate — 1322 per frame against hardware's 1321. **But it has no
scanline counter.** Those cycles arrive in one lump before the next interrupt
rather than interleaved between DMA bursts, and `CPU_ReadEFlag(1)` returns a
constant. So it cannot arbitrate:

- software that spins on `EF1`
- software that counts cycles across the display window
- anything with a custom ISR (`race.st2` is the only one in the corpus)
- colour timing on the 1864

For those, the arbiters are **Emma 02** (behaviour; the only emulator that models
the Visicom) and **MAME** (`cdp1861.cpp`, `studio2.cpp`, `visicom.cpp`).

And there is a third, better than either: `refvideo/` holds **captures of real
hardware**. One of them already overruled an emulator — sampling the Visicom
Freeway longplay showed Emma 02's palette was wrong and MAME's right (summed RGB
distance 86 vs 225). Six more captures are sitting there unexamined:

```
refvideo/RCA Studio II Star Wars - direct capture.mp4
refvideo/RCA Studio II Resident Games - Bowling, Freeway, Doodle, Addition, Patterns.mp4
refvideo/Biorhythm, RCA Studio II.mp4
refvideo/Math Fun, RCA Studio II.mp4
refvideo/RCA Studio II Concentration Match.mp4
refvideo/RCA Studio II democart.mp4
```

Several of those titles are currently in the DIFFER column with only the
reference emulator's word against them. This is the cheapest accuracy work
available.

---

## 5. What to do next, ranked

**1. Verify on hardware.** Nothing else is blocked on it, but everything is
uncertain without it. The `.rbf` builds clean at 10,310 ALMs (25%), timing closed
at +0.567 ns setup. Analog video (`docs/analog-video.md`) is the specific thing
to check, plus audio by ear and the OSD profile write-back.

**2. Embed the BIOS.** The core is held in reset until a BIOS is loaded from the
OSD every boot (`Studio-II.sv`, `rom_loaded` latches on
`ioctl_index==0 && ioctl_addr==100`). `rom/studio2.rom` is already in the tree
and `rom/studio2.hex` is the same 2 KB as hex text. This is the largest remaining
piece of user-facing friction and is not technically hard. Note the other three
machines have their own BIOSes which cannot be embedded (not ours to
redistribute), so this needs a default-plus-override design, not a replacement.

**3. Check the remaining `refvideo/` captures**, as above.

**4. Cartridge banking above `$0FFF`.** `st2_pg_ok` in `rtl/rcastudioii.sv`
accepts only pages `$0x`. The RCA test cartridge pages `$24-$2F` and so loads
nothing at all — and that cartridge is the obvious way to validate the Studio III.
Neither our core nor the reference emulator models this.

**5. Profile consolidation** (`CLAUDE.md` §7.2). Once the library is reliable,
inventory every title's controls, merge profiles that subsume one another, and
reorder into a logical progression. That is the right moment to bump `CONF_STR`
from `v5` and reorder its profile entries — not before.

**6. Horizontal centring** of the analog picture, if hardware shows it matters.
See the warning in §3.2 above.

Deliberately **not** on this list: the Studio IV. It shares the 1802 and nothing
else — different video part, kilobyte colour RAM at a configurable address, up to
32 K of RAM, system images rather than cartridges. `docs/succession-plan.md` §10
explains, and preserves Weisbecker's own 1977 I/O spec for whoever does attempt
it in a core of its own.

---

## 6. Conventions worth not relearning

- Quartus **17.0.x only** (MiSTer requirement), via the `raetro/quartus:mister`
  Docker image. `tools/quartus-build.sh` handles it.
- **Do not edit anything under `sys/`** — shared MiSTer framework, overwritten on
  updates. Every remaining Quartus warning originates there.
- Add new sources to `files.qip` by hand; keep `verilator/Makefile`'s `V_SRC` in
  sync.
- Prefer deleting dead code to commenting it out. This tree is already hard to
  read because so much of it is commented-out history — git has that.
- **When you change timing or video, say which reference you matched against** in
  the commit message: MAME, Emma 02, rca-studio2, AVI1861, or a `refvideo/`
  capture. Every timing number in this repo is traceable to one of those, and
  keeping that true is what makes the core arguable rather than tuned by feel.
- Record what you measured, including when it *didn't* change. Several entries in
  `CLAUDE.md` §10 exist to stop a future reader "fixing" something back.

---

## 7. Credit

Jason Coombes wrote the original core — the CDP1802 and CDP1861 Verilog, the
keypad scheme, the memory map, the Verilator harness — and is the primary
contributor by far. Flandango did the MiSTer integration and early Pixie work.
Alan Steremberg and Elle Ball carried the 2026 timing, video, controller and OSD
work. `CLAUDE.md` §12 lists the emulators and hardware references this core is
checked against; read it before assuming any number here was derived from first
principles.
