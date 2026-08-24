# CLAUDE.md — RCA Studio II for MiSTer

Guidance for working in this repo. Read this before changing RTL.

**New to this repo? Read `docs/handoff.md` first** — it separates what is proven
from what is merely believed, lists the seven things that will bite you, and
ranks what to do next. This file is the working reference behind it.

---

## 1. What this is

A MiSTer FPGA core for the **RCA Studio II** (1977), an RCA CDP1802 ("COSMAC")
based console with CDP1861 "Pixie" video.

This repo continues and extends earlier work by **Jason Coombes** (original
core), **Flandango** (MiSTer integration), **Alan Steremberg** (2026 CPU/video
and DMA timing work), and **Elle Ball** (2026 controller/profile and input
layout work). The current playable core is a collaborative continuation of that
foundation, not a rewrite from scratch. Credit for the emulators and hardware
references this core is built and checked against is in §11 — read it before
assuming any timing number here was derived from first principles.

**State of the core: playable.** The CPU has the full instruction set the BIOS
needs, interrupts and DMA; the video is a real CDP1861 driven by DMA, not a RAM
scraper. Frames are checked against the reference emulator by
`tools/score-21.sh`, currently **26 of 48** (§9 explains why the rest differ and
why that is expected), the built-in BIOS games and controller profiles are in place,
the beeper and RTL ST2 loader are implemented, and the core builds clean in
Quartus with timing closed (§4).

Recent additions that matter for day-to-day use include the OSD-managed joystick
profile system with its Auto/Manual split (the menu shows the detected profile
instead of the word "Auto"), the default 8-way profile,
Gunfighter/8-way/Doodle special cases, the Clear-only profile for digit-entry
software, the memory decode, and config-versioning so old saved menu state does
not silently map to the wrong fields.

The core now covers four machines, selected from the OSD: Studio II, Studio III
PAL (a CDP1864), Studio III NTSC (a CDP1861 with a CDP1862 for colour and a
CDP1863 for tone — a different chipset, not the same part retimed) and the
Toshiba Visicom COM-100, whose colour comes from a second bit plane $200 above
the first rather than from colour RAM. See `docs/succession-plan.md`.

What is still missing: an embedded BIOS. (PAL is not missing — the Studio II
never had it; see §7.1.) See §6.

Licence: GPL-2.0-or-later (file headers). Note `rtl/reference/cosmac.vhdl` and
its translation `rtl/cosmac.v` are Eric Smith's GPL-3.0 code — compatible with
"GPL-2-or-later", but any release containing them is effectively GPL-3.

---

## 2. Hardware reference (the facts the RTL must match)

Authoritative notes live in `docs/*.txt` (scraped from the classicgaming
Studio 2 tech pages). Summary:

### CPU
- CDP1802 @ **1.7897725 MHz** (3.579545 MHz crystal ÷ 2). MAME uses 1760000 Hz
  for `studio2` because the real clock comes from an RC oscillator, not a crystal.
- **8 clocks per machine cycle**, 2 machine cycles per instruction
  (3 for long branch/skip). So ~110k instructions/sec.
- 16 × 16-bit register file R0–RF; P selects PC, X selects data pointer.
- DMA and interrupt are *bus* operations: they steal machine cycles from the CPU.

### Memory map
```
0000-02FF  ROM        System ROM: CHIP-8 interpreter
0300-03FF  ROM        System ROM: always present
0400-07FF  ROM        Built-in games  (replaced by cartridge when inserted)
0400-07FF  Cartridge  Cartridge games
0800-08FF  RAM        System/program memory
0900-09FF  RAM        Display memory (used as VRAM by software)
0A00-0BFF  Cartridge  Multicart space (rarely used)
0C00-0DFF  RAM/ROM    Mirror of 0800-09FF by default
0E00-0FFF  Cartridge  Multicart space (rarely used)
```
RAM is mirrored everywhere A9=0 and no ROM/cart is decoded (0C00, 1000, 1400, …).
There are only 512 bytes of it, so the mirror address is just A8-A0. The system
ROM is *not* mirrored above `$0FFF`; MAME's `studio2.cpp` maps RAM at
`0x0000-0x01ff` mirrored `0xfc00` across the whole 64K and then installs the ROM
handlers over `$0000-$07FF` alone, which is the same statement. Implemented in
`rtl/rcastudioii.sv`, tested by `tools/memdecode-test.sh`.

### I/O
| Signal  | Meaning |
|---------|---------|
| `INP 1` | Turn display on (CDP1861). BIOS does this via `CALL $0066`. |
| `OUT 1` | Turn display off. |
| `OUT 2` | Low 4 bits = key number (0–9) to scan, latched into a CD4515. |
| `EF1`   | CDP1861 display status — asserted for 4 line-times before the start and before the end of the 128-line display window. |
| `EF3`   | Selected key pressed on **left** keypad (player A). |
| `EF4`   | Selected key pressed on **right** keypad (player B). |
| `Q`     | Beeper on/off. NE555 astable, ~625 Hz nominal, pitch decays ~50% over 0.4 s (the "warpy" power-up sound). |

### 2.1 What the RCA block diagram says (primary source, 2026-08-17)

`docs/rca-technical/` (git-ignored, see §5) holds photographs of RCA/Weisbecker
documents. `Studio II III IV/IMG_0618.JPG` is **"Figure 1 — Studio II Block
Diagram"**, which is the authority for most of the above. It confirms:

- **Memory is exactly what §2 claims.** Four 512×8 ROMs — `IC11` `$0000-$01FF`
  and `IC12` `$0200-$03FF` labelled INTERPRETER, `IC13` `$0400-$05FF` and
  `IC14` `$0600-$07FF` labelled GAME ROM — and four 256×4 NMOS RAMs paired into
  512 bytes at `$0800-$08FF` and `$0900-$09FF`. There is a discrete **"RAM
  ADDRESS DECODE"** block fed by `TPA`, gated with `MRD`/`TPA2`, which is the
  thing our decode models.
- **The data bus has 22 kΩ pull-ups** ("The data bus uses pullup resistors,
  22K ohms"). So an undecoded read floats **high**: open bus is `$FF`, not `$00`.
  This vindicates the change in `0563df6`; the `$00` this core shipped
  originally (chosen to match the C reference emulator's zeroed array) was wrong
  on hardware grounds.
- **The keypad strobe is `N1 AND TPB`**, not a decode of `N == 2`. The CD4515's
  strobe comes from a gate driven by `N1` and `TPB`, and it takes 4 data-bus
  bits. On real hardware `OUT 3`, `OUT 6` and `OUT 7` therefore latch the key
  select as well as `OUT 2`. Our `rtl/rcastudioii.sv` tests `io_n == 3'd2`,
  which is a deliberate-looking divergence introduced when an earlier bit test
  was "fixed" — the bit test was closer to the hardware. **Measured neutral:**
  patching it to `io_out && io_n[1]` gives byte-identical frames across 71
  images (5 built-ins, 18 retail, 48 PD), so no real software executes those
  ports. Fidelity nicety, not a bug — but do not "fix" it back without reading
  this.
- The **1861 is selected by `N0`**, and `CLEAR` goes to *both* the 1802 and the
  1861 (which is why CLEAR resets the pixie here). `Q` drives the 555 sound
  circuit into the speaker. `EF3`/`EF4` are keyboards A/B.
- `IMG_0619.JPG` is **"Figure 2 — How the RAM is mapped on to the TV"**:
  `$0900` at top-left, 8 bytes (64 bits) per row, 32 rows, `$09FF` at
  bottom-right, **bit 7 leftmost**. Exactly the video path we implement.
- `IMG_0620.JPG` is "Figure 3 — Plug-in PROM card Schematic": a Harris 7641
  cartridge with `A8` latched from `TPA2` by a CD4042, enabled by `CE1` + `MRD`
  off the 22-pin socket. Useful if the cartridge window is ever revisited.

Also in there, and worth knowing about:

- `IMG_0353.JPG` — Weisbecker's typed **"STUDIO IV INSTRUCTIONS"** (his
  letterhead, 7-20-77): the Studio IV I/O map. `61`=tone, `62`=key select
  (B3-B0), `63`=output port, `64`=TV control (RGB background, spot map,
  TV on/off, 192-vs-128 lines), `65`=DMA-out, `6B`=input port, and
  "**TV OFF AFTER RESET**". Relevant if PAL/Studio III/IV ever gets attempted.
- `IMG_0354.JPG` — his handwritten Studio IV memory test, whose interrupt
  routine starts `C4 22 78` — `C4` as a real NOP at ISR entry, independent
  corroboration of the `Cx` long-skip decode fixed in `d1eb75b`.
- `IMG_1535.JPG` — the "COLOR CHIP" sketch (JAW 1-77), 22 pins, **3.58 MHz
  crystal generating the CPU clock**, "A8 not req'd for 32×64 format". Note this
  is the colour machine; the Studio II's own clock is still the slug-tuned RC
  oscillator of the service manual (§10, 2026-08-12), so it does not change the
  1.76 MHz figure here.

### Video — this is the part that matters most
The CDP1861 does **not** have its own frame buffer. It asserts `DMA_OUT` and the
**1802** performs 8 DMA-OUT machine cycles per scanline, reading bytes through
**R(0)** and handing them to the 1861, which shifts them out as pixels.
Software sets R(0) in the 60 Hz interrupt handler.

- 64 × 32 logical pixels (each row displayed 4× → 128 active lines).
- 262 lines/frame, ~14 bytes (112 pixel-times) per line, NTSC 60 Hz.
- Display window: lines 64–191 active; interrupt fires ~2 lines before.
- BIOS ISR entry is `$001C`; it sets `R0 = $09xx` and streams `0900-09FF`.

The Studio II BIOS ISR, disassembled from `rom/studio2.rom`:
```
001B: 70           RET            ; end of previous ISR
001C: 22           DEC R2         ; <-- interrupt vector
001D: 78           SAV            ; save T (X,P) to M(R(X))
001E: 22           DEC R2
001F: 73           STXD
0020: C0 00 23     LBR $0023
0023: 7E           SHLC
0024: 52           STR R2
0025: 19           INC R9
0026: F8 09        LDI $09
0028: B0           PHI R0         ; <-- R0 = $09xx, the DMA display pointer
0029: F8 D0        LDI $D0
002B: A8           PLO R8
...  A0 E2 20 A0 E2 20 ...        ; 1861 DMA wait/timing loop
```
**Any correct Studio II core must implement 1802 interrupts, `SAV`, `RET`, and
DMA-OUT cycles.** The current core implements none of them (§6.1).

### Cartridge formats
- **`.bin` / `.rom`** — raw dump, loads flat at `$0400`. 512 or 1024 bytes.
- **`.st2`** — paged format with a 256-byte header (`docs/cartridge.txt`):
  ```
  0-3    "RCA2"
  4      total number of 256-byte blocks (incl. header)
  5      format code (1)
  6      video flag: non-zero = non-standard video driver
                     1 = RAM used normally but no scrolling
  8,9    author initials     10,11  dumper initials
  16-25  RCA catalogue code (ASCIIZ)
  32-63  title (ASCIIZ)
  64-127 page address for each following 256-byte block
  256+   block data
  ```
  Valid target pages are `04-07`, `0A-0B`, `0E-0F` in each 4K bank.

---

## 3. Source layout

### Files actually compiled (`files.qip`)
| File | Role |
|------|------|
| `RCAStudioII.sv` | MiSTer `emu` top: hps_io, PLL, OSD config string, video chain (video_mixer + video_freak), on-screen keypad |
| `rtl/rcastudioii.sv` | Core glue: CPU + pixie + memory decode + keypad + joystick profiles + cartridge loader |
| `rtl/cdp1802.v` | The CPU: full BIOS instruction set, interrupts, DMA, machine-cycle timing |
| `rtl/dpram.sv` | Dual-port block RAM — instantiated **three** times: the 4 KB ROM/cartridge image, the 512 B RAM, and the Visicom's 256 B second bit plane. Port B must stay tied off on any instance that has to infer as block RAM (§8) |
| `rtl/numstick.sv` | Analog-stick on-screen keypad (Jaguar core's, via ColecoAdam) |
| `rtl/pixie/pixie_video.v` | Thin wrapper around `cdp1861.v` |
| `rtl/pixie/cdp1861.v` | The NTSC video: a real CDP1861, DMA-fed, no frame buffer. Also carries the Visicom's second bit plane |
| `rtl/pixie/cdp1864.v` | The PAL video: CDP1864 — video, colour and tone in one part. A sibling of `cdp1861.v`, deliberately not a parameterisation of it |
| `rtl/pixie/cdp1862.v` | Colour generator for the NTSC Studio III |
| `rtl/pixie/cdp1863.v` | Tone generator: the standalone 1863, and the 1864's internal divider |

### Files present but NOT compiled (dead / reference)
`rtl/cosmac.v`, `rtl/dma.v`, `rtl/keypad.v`, `rtl/debounce.v`, `rtl/rom.v`,
`rtl/beep.sv`, `rtl/pixie/pixie_video_old.v`, `rtl/pixie/pixie_dp_*.v{,hdl}`,
`rtl/reference/`.

`rtl/cosmac.v` (Eric Smith's GPL-3 1802, via X-HDL) was once the planned
replacement CPU. It is no longer needed — `rtl/cdp1802.v` now has the
instruction set, interrupts, DMA and cycle timing the BIOS requires. Keep it
only as a cross-reference.

Note `rtl/pixie/cdp1861.v` is the *live* video module; the old
`pixie_video_studioii.v` RAM scraper has been deleted.

### Clocks
`rtl/pll/pll_0002.v`: `outclk_0 = 7.040229 MHz` (`clk_sys`),
`outclk_1 = 42.241379 MHz` (`clk_vid`, now unused). 7.040229 = 4 × 1.760229 MHz.
`RCAStudioII.sv` divides `clk_sys` by 4 into the `ce_pix` enable — the 1.76 MHz
pixel/CPU timebase everything inside `rcastudioii.sv` is gated on. The Verilator
sim ties `ce_pix` high instead (one pixel per clock): frame contents are
identical, the sim is just 4× cheaper per frame. Don't "fix" either side to
match the other.

---

## 4. Build & test

### Quartus
Quartus **17.0.x** only (MiSTer requirement). Project `Studio-II.qpf`, top
entity `sys_top` (from `sys/`). Quartus is not installed natively here; it runs
in the `raetro/quartus:mister` Docker image (Quartus 17.0.2):

```sh
tools/quartus-build.sh          # full build -> output_files/Studio-II.rbf
tools/quartus-build.sh map      # analysis & synthesis only (~1.5 min)
tools/quartus-build.sh clean
```

Last known-good build (2026-08-19, all four machines): **0 errors**, timing
closed (worst setup slack +0.567 ns, hold +0.242 ns), **10,310 ALMs (25 %)**,
463 kbit of block RAM (8 %), 74 RAM blocks, whole flow ~6 minutes. Most of that
is the MiSTer framework; `numstick` alone is ~940 ALMs.

That is within a few hundred ALMs of the 10,003 recorded before any of the
colour work, which is not a coincidence and is worth reading §10 (2026-08-19)
for: the CDP1864, CDP1862, CDP1863 and the whole Visicom together cost a few
hundred ALMs, while a single RAM that had quietly fallen out of block memory was
costing four thousand. Three builds isolated it — 18,384 ALMs (44 %), then
14,096 (34 %), then 10,310 (25 %) — and the check that catches it is in §8.

An older note here put the memory decode at **+86 ALMs and +4 kbit** over the
pre-decode core, which is just the 512-byte RAM.

**Do not run `quartus_sh --flow compile`.** The image is amd64 under emulation
on Apple Silicon, and the qsf's `NUM_PARALLEL_PROCESSORS ALL` makes Quartus fork
helper processes that crash there — they end up `<defunct>` beside
`[crashreporter]`, and the parent deadlocks forever on named pipes from the dead
helpers at ~4 % CPU. It looks like a slow build but never finishes. The script
passes `--parallel=1` to each stage to avoid this; a healthy build sits at
~100 % CPU.

`Studio-II.qsf` needs `PRE_FLOW_SCRIPT_FILE = quartus_sh:sys/build_id.tcl`;
without it synthesis dies on the missing generated `build_id.v`.

### Verilator sims (`verilator/`)
Two targets, both working. `verilator` 5.x and `sdl2` come from Homebrew.

```sh
cd verilator
make            # interactive SDL/ImGui sim -> ./obj_dir/Vtop
make headless   # batch sim                 -> ./obj_dir_headless/Vtop
make clean
```

Both accept `--bios FILE`, `--cart FILE` (raw `.bin`, flat at `$0400`) and
`--press KEY@FRAME[:HOLD]`, where KEY is `0`-`9` optionally prefixed `a`/`b`
for the two keypads. The headless sim adds `--frames`, `--shot`, `--shot-every`,
`--ascii`, `--vram`, `--frame-log`, `--trace-cpu`, `--trace-from`; see `--help`.

```sh
./obj_dir/Vtop --cart "../software/carts/TV Arcade I - Space War (USA).bin" --press a1@40:30
./obj_dir_headless/Vtop --frames 200 --press a5@40:20 --shot 200 --ascii
```

Keyboard in the GUI: **player A = number row `0`-`9`**, **player B =
`P Q W E R T Y U I O`**. With no cart the built-in games start on **3/4/5**;
most cartridges start on **1** or **2**.

**The Makefile does not track RTL edits into `obj_dir`.** If a `.v` change
appears to do nothing, `rm -rf obj_dir obj_dir_headless` and rebuild — this has
silently run stale binaries more than once.

Lint:
```sh
cd verilator && make lint
```

### Loading software
The OSD (`RCAStudioII.sv:206`) exposes:
- `F0,rom` → BIOS, loaded to `$0000`
- `F1,bin` → cartridge, loaded to `$0400`

The BIOS is **not** embedded; it must be loaded from the OSD every boot, and
`rom_loaded` (`RCAStudioII.sv:291`) only latches when `ioctl_index==0 &&
ioctl_addr==100`, so the core is held in reset until a BIOS is loaded.

---

## 5. Reference material on disk

### `refs/` — emulator and HDL references (git-ignored, ~950 MB)
| Path | What | Why it's here |
|------|------|---------------|
| `refs/emma_02/` | **Emma 02** (etxmato) — the definitive CDP1802 multi-system emulator: Studio II/III, Visicom, MPT-02, VIP, Elf. C++/wxWidgets, AGPL-3. | Best behavioural reference. `src/cdp1802.cpp`, `src/video.cpp`. |
| `refs/rca-studio2/` | **ajavamind/rca-studio2** (Andrew Modla, an original RCA game developer). Processing/Java. Claims precise CDP1802 DMA timing, NTSC/PAL. Handles `.st2 .bin .rom .ch8 .c8x .vip .arc .fd2`. | Best reference for *timing* and for the ST2 loader. |
| `refs/cosmac-vhdl/` | **brouhaha/cosmac** — Eric Smith's GPL-3 VHDL 1802 + `pixie/` (a real CDP1861 front/back end) + Elf SoC. | This is where `rtl/cosmac.v` and `rtl/pixie/pixie_dp_*` came from. The upstream is complete; our copies are partial. |
| `refs/AVI1861/` | **dmadole/AVI1861** — drop-in CDP1861 replacement, ATF1504 CPLD (`pld/frame.pld`, `pld/line.pld`). | Cycle-exact 1861 sync/DMA timing from a working hardware replacement. |
| `refs/cosmac_mbc/` | **kanpapa/cosmac_mbc** — COSMAC MicroBoard incl. Pixie video. | Secondary HDL reference. |
| `refs/studio2-games/` | **paulscottrobson/studio2-games** — homebrew Studio II games with full 1802 asm source + `asmx` assembler. | Test material you can rebuild and instrument. |

**MAME is deliberately not cloned here** — use the existing checkout at
`/Users/alans/Documents/development/lbmactwo_MiSTer/mame`. Relevant files:
`src/mame/rca/studio2.cpp`, `src/devices/cpu/cosmac/cosmac.cpp`,
`src/devices/video/cdp1861.cpp`.

### `software/` — test corpus (git-ignored)
| Path | Contents |
|------|----------|
| `software/RCA - Studio II (20200201-121822)/` | No-Intro set, 17 commercial cartridges (zipped) |
| `software/carts/` | Same set, extracted `.bin` (512 / 1024 bytes, load at `$0400`) |
| `software/tosec/RCA Studio 2 [TOSEC]/` | TOSEC 2012-04-23: BIOS + games as `.st2`, `.bin` and `.asm` |
| `software/RCA - Chip-8.zip`, `RCA - Superchip.zip`, `RCA - COMSAC VIP.zip` | CHIP-8 / VIP software |

### `docs/rca-technical/` — photographed RCA documents (git-ignored, ~220 MB)

Photographs of primary RCA/Weisbecker paperwork, unpacked from
`RCA Technical docs.zip`. **Git-ignored deliberately** — `/*.zip` and
`docs/rca-technical/` are in `.gitignore` because the archive is ~220 MB, over
GitHub's 100 MB hard limit, and none of it is ours to redistribute. It got swept
into a commit once by a `git add -A`; that is what the ignore rules prevent.

| Folder | Files | What |
|--------|-------|------|
| `Studio II III IV/` | 21 | **The useful one.** Studio II block diagram and RAM/TV map, Studio IV I/O spec, colour chip sketch — see §2.1 |
| `Technical Reports/` | 57 | RCA technical reports (HEIC) |
| `Coin Arcade and FRED III/` | 33 | Coin-op and FRED III, incl. `RCA_paper2.pdf` |
| `Cosmac VIP stuff/` | 11 | VIP photos |
| `FRED and FRED II/` | 2 | Weisbecker's *Microprocessor Manual System 00* and the July 1972 FRED manual, both searchable PDFs |

Mostly `.HEIC`, so convert before viewing:
`sips -s format jpeg -Z 1800 in.HEIC --out out.jpg`.

The two FRED PDFs carry their own provenance: the System 00 manual is courtesy
of the **Hagley Museum and Library** from the David Sarnoff Library Collection
(Acc. 2464), published to cosmacelf.com with permission granted to Dave Ruske in
2016; the FRED manual was scanned and cleaned by **Herb Johnson** from the
Sarnoff Collection and Anthony "Toni" Robbi's papers. Cite them properly if any
of it is quoted.

`rom/studio2.rom` is md5 `b37205bf19b197682f00619d05da194b`, byte-identical to
the TOSEC `RCA Studio II BIOS (1976)(RCA).bin`. Good. `rom/studio2.hex` is the
same 2 KB as space-separated hex text (6144 bytes).

**Suggested smoke-test ladder** (easiest → hardest):
1. `TV School House I (USA).bin` (512 B) — simple, mostly static display.
2. `TV Arcade I - Space War (USA).bin` — needs working keypad + timing.
3. `TV Arcade III - Tennis + Squash (USA).bin` — fast-moving sprites, timing-sensitive.
4. `Space Invaders (2000)(Paul Robson).st2` — homebrew, source in `refs/studio2-games`.
5. Any `.st2` with a non-zero video flag — exercises the paged loader.

---

## 6. Known defects

Most of the original defect list is fixed — see §10 for what changed. What
remains, ordered by impact.

### 6.1 Homebrew flicker -- does not currently reproduce

The previous entry here claimed Paul Robson's homebrew flickered (45 of 101
frames blank on `invaders.st2`) and blamed the missing memory mirroring. Both
halves of that turned out to be wrong, so the entry is kept as a warning rather
than deleted.

Re-measured on 2026-08-15 across all eight homebrew titles, before *and* after
the decode was implemented, the numbers are identical and clean:

    invaders.st2   frames 300-400   0 blank, 53 distinct hashes (it is animating)
    combat/hockey/scramble                   0 blank,  1 hash   (static, correct)

The mirroring argument was also wrong on its own terms: `$0A00` has **A9 = 1**,
so it is cartridge space, not a RAM mirror — the mirror is `$0C00-$0DFF`, where
A9 = 0. If a flicker is seen on hardware, start the trace again from scratch;
do not assume the R(0) story above.

### 6.2 Memory decode -- done (2026-08-15)
Implemented; see §10. `tools/memdecode-test.sh` covers it.

### 6.2b Tennis/Squash is mapped to PADDLE -- a design choice, not a bug (2026-08-17)

An earlier version of this entry called Elle's `6b5b999` a regression on the
grounds that it folded "two different cartridges" onto one line. **That was
wrong, and this records the correction**, because the wrong version was published
and could otherwise get acted on.

The line in question:

```
-16'h88FB: begin map_profile <= MAP_CROSS;  start_key <= 4'd2; end
-16'hFB76: begin map_profile <= MAP_PADDLE; start_key <= 4'd1; end
+16'h88FB, 16'hFB76: begin map_profile <= MAP_PADDLE; start_key <= 4'd1; end
```

`88FB` and `FB76` are **the same cartridge in two containers**, not two
cartridges. Measured: `88FB` is TV Arcade III Tennis + Squash as a 512-byte
`.bin`; `FB76` is the same title as a 768-byte `.st2`, whose payload is
byte-identical to that `.bin` and whose header title field reads
"TV ARCADE III TENNIS". They hash apart only because the CRC covers the file as
downloaded, header and all -- which is exactly why the table already pairs
`.st2` with `.bin` elsewhere (`16'hFBEF, 16'h2B4D` for Asteroids, and so on).
So grouping them is *consistent with the table's own convention*, and there is
no "homebrew tennis": nothing by Paul Robson of that name exists in any corpus
here.

What is left is one design question about one game, not a conflation. The
cartridge holds two games: **Tennis** is two-player and starts on `A2`,
**Squash** is one-player and starts on `A1` (Readme, from the RCA manual).
`MAP_PADDLE` is keypad-B-only and sits in `profile_1p`, and the new start key is
`A1`. That is a coherent package: it gives a gamepad user **Squash**, which one
stick can actually play, instead of Tennis, which needs two keypads. The previous
`MAP_CROSS` + `A2` gave Tennis, which a single pad plays only half of.

So both mappings are defensible and the choice is Elle's to make. Left as-is.
If it is ever revisited, the trade is "Squash with a pad" against "Tennis with
two pads", not correct against incorrect. Note the frame harness cannot
distinguish them: retail Tennis does not visibly respond to held stick input in
these scenarios.

### 6.3 Top level — `RCAStudioII.sv`
- **The BIOS is not embedded**, so the core is held in reset until one is loaded
  from the OSD. This is the single biggest piece of user-facing friction left.
- **Analog video is emitted but has never been seen on a TV.** The raster is
  right against the datasheet and the sim; nobody has plugged in an analog IO
  board. See `docs/analog-video.md` for what to do and how to tell.
- PAL is no longer missing — it arrived with the CDP1864 (Studio III PAL). It was
  never a Studio II feature; see §7.1.
- The rest of the old list — aspect ratio, `CE_PIXEL`, the dead `clk_1m76` — is
  fixed; see §10 (2026-08-14).

### 6.4 Minor
- `sys/` is shared framework code and must not be edited; the remaining Quartus
  warnings (unused SDRAM/SDIO pins, open-drain removal) all originate there and
  are present in every MiSTer core.
- `RCAStudioII.sdc` has no core-specific constraints beyond `derive_pll_clocks`.

---

## 7. Roadmap

### 7.1 Polish
Embedded BIOS, analog-video verification on real hardware
(`docs/analog-video.md`), and any final top-level cleanup around default OSD
behaviour and naming consistency. `docs/handoff.md` §5 ranks these.

**"PAL option" used to be listed here and has been removed as a mistake.** There
was no PAL Studio II: the CDP1861 is NTSC-only (MAME hard-codes 262 scanlines
and has no PAL path), Emma 02 ships four Studio II configs and none is PAL, and
the AVI1861 replacement has none either. A 50 Hz Studio II would also slow every
game by 17%, since they time off the 60 Hz interrupt, and MiSTer's scaler
already handles PAL displays without touching core timing. PAL is native to the
**CDP1864** instead — see §7.4 and `docs/succession-plan.md` §2.0.

### 7.4 The next machines — see `docs/succession-plan.md`

**Done as of 2026-08-19.** All four machines the core will carry are in: Studio
II, Studio III PAL (CDP1864), Studio III NTSC (CDP1861 + 1862 + 1863) and the
Toshiba Visicom COM-100. The Studio IV is deliberately *not* — it shares the
1802 and nothing else, and belongs in its own core (succession plan §10).

Which machines follow the Studio II, in what order, and what software we hold
for each. Headline: the CPU-side contract does not change (MAME drives the
CDP1864 with the same `INT`/`DMA_OUT`/`EFx` our 1861 already produces), so the
1802, DMA video model, cartridge loader, keypad and profile system all carry
over. PAL comes with the 1864 rather than being a step of its own. The MPT-02/Victory family is one implementation for six machines, and
`refs/emma_02/data/StudioIII/RCA_TEST_CARTRIDGE_TESTER1.st2` is a real test
cartridge to bring it up against. Read that document before starting any of it —
particularly §4, which lists the decisions to settle first (one core or many,
how colour widens the 1bpp video chain, and what replaces the §9 reference
emulator for the colour machines).

### 7.2 Controller/profile parity
The profile system is intentionally explicit and tested across the common
cartridges, but every new title is still a chance to discover a missing special
case. Keep the profile table aligned with the actual manuals and the reference 
emulator.

Once the full software library runs reliably, make a deliberate consolidation
pass: inventory every title's controls, merge profiles that can completely
encompass one another, then reorder the remaining minimal set into a logical
progression. That is the right time to bump the `CONF_STR` version and reorder
its profile entries.

### 7.3 Keep the comparison green
Any RTL change should be re-checked against the reference emulator (§9) before
committing. The regression is cheap — a few seconds per cartridge. The full set,
in the order they are cheapest to run:

| Script | What it covers | Expected |
|--------|----------------|----------|
| `tools/memdecode-test.sh` | the memory decode, which no cartridge in the corpus exercises (§9) | 8/8 |
| `tools/tone-test.sh` | the CDP1863/1864 tone divider, which no frame can show | 7/7 |
| `tools/visicom-test.sh` | the Visicom, which has no reference emulator | all ok |
| `tools/score-21.sh` | the §9 Studio II score, documented start sequences | 26/48 |
| `tools/score-conic.sh` | the Studio III PAL sweep, uniform A1 | 22/38 |

The last two are comparisons against `tools/refemu` and will move when its cycle
model does; the first three are directed tests and should not move at all.

---

## 8. Conventions

- Quartus 17.0.x. Do not edit anything under `sys/` — it is the shared MiSTer
  framework and is overwritten on updates.
- Add new sources to `files.qip` by hand (Quartus writes them into
  `Studio-II.qsf` instead; move them). Keep `verilator/Makefile`'s `V_SRC` in
  sync with `files.qip`.
- Keep the PLL in `rtl/pll*`; the framework requires it there.
- Prefer deleting dead code over commenting it out. This tree is already hard to
  read because so much of it is commented-out history — git has that.
- After changing anything about a memory's ports, run at least
  `tools/quartus-build.sh map` and check the RAM still appears in the
  `Inferred altsyncram megafunction` list in `output_files/RCAStudioII.map.rpt`.
  A memory that falls out of block RAM into logic costs thousands of ALMs, still
  fits, still closes timing, and is invisible to every simulation in this repo
  (§10, 2026-08-19).
- When changing timing or video, state which reference you matched against
  (MAME / Emma 02 / rca-studio2 / AVI1861) in the commit message.

---

## 9. Verifying against the reference emulator

The core is checked frame-by-frame against Paul Robson's C emulator, **vendored
into this repo at `tools/refemu/`** (MIT; see its README for provenance and for
why it is vendored rather than left in `refs/`). It was extended for this
purpose: an ST2 loader, a headless front end (`headless.c`, no SDL), PNG capture,
an instruction trace and scripted keypresses — all of which are part of this
project, not upstream's.

```sh
cd tools/refemu
make headless          # -> ./studio2_headless   (links libc only)
./studio2_headless --help
```

It used to live only under the git-ignored `refs/`, *untracked*, in a checkout
whose remote is upstream's — so the harness behind every accuracy figure below
was one `git clean` away from being lost. `tools/compare-game.sh` prefers
`tools/refemu` and still falls back to the old `refs/` path if a stale build is
there.

Both it and the RTL sim take the same `--frames`, `--press KEY@F[:H]`, `--shot`
and `--ascii` options, so a comparison is a plain `diff`. The C emulator renders
32 logical rows; the RTL renders 128 scanlines, so expand each reference row 4x:

```sh
# reference -> 128 lines
./studio2_headless --frames 200 --press a5@40:20 --shot 200 --ascii --quiet \
  | grep -E "^  [.#]+$" | sed 's/^  //' | tr '.' ' ' \
  | awk '{for(i=0;i<4;i++) print}' > /tmp/c.txt

# RTL -> 128 lines
cd ../../../../verilator
./obj_dir_headless/Vtop --frames 200 --press a5@40:20 --shot 200 --ascii \
  | grep -E "^ *[0-9]+ \|" | sed 's/^ *[0-9]* |//; s/|$//' > /tmp/r.txt

diff /tmp/c.txt /tmp/r.txt        # expect no output
```

Current score: **26 / 48 frames**, from `tools/score-21.sh` — 5 built-in games
and 19 cartridge scenarios, two frames each, each driven with its documented
start sequence. (An older note here said "18 / 21"; that was a different,
hand-run set and is not comparable. The script defines the number.)

Most of what differs is game state rather than rendering: the BIOS updates an RNG
seed in its ISR, so any timing difference deals different cards, drops different
pieces and puts sprites elsewhere. `tools/contact-sheet.py` renders the whole
library side by side with a per-title percentage of differing scanlines, which is
the way to tell state from breakage — anything under ~30% is almost always the
former.

Note on `86677b` and `87201`: the reference emulator renders **full-screen
random noise** for both from the first frame, before any input. They are not
working images there either, so neither side is a reference for the other, and
their output is free to change without that meaning anything. Do not chase them.

**What the frame comparison cannot see.** Nothing in the corpus — 18 retail
cartridges, 8 homebrew, 5 TOSEC `.st2` — reads or writes a RAM mirror, or any
address above `$0FFF`. The whole memory decode is therefore invisible to it:
the old truncate-to-12-bits version scored exactly the same. That is what
`tools/memdecode-test.sh` is for — a hand-assembled 90-byte native-1802
cartridge that pokes each case and checks the result out of the simulated RAM.
It fails 4 of its 8 checks against the pre-decode core.

**The reference's cycle model was corrected on 2026-08-17 and now matches
hardware's instruction rate, but it is still not cycle-accurate.** It used to give
the CPU no cycles at all during the 128 display lines, so it ran ~952
instructions/frame against hardware's 1321 -- a 28% shortfall, and the reason the
old warning here said "do not fix the RTL to match 952". It now also gets the 6
of every 14 cycles that the CPU keeps while DMA takes the other 8, and measures
**1322/frame** against hardware's 1321.

That fixed the *total* and not the *distribution*. The model has no scanline
counter, so those display-window cycles all arrive in one lump before the next
interrupt rather than interleaved between DMA bursts, and `CPU_ReadEFlag(1)`
still returns a constant 1 -- so software that spins on EF1 or counts cycles
across the display window still cannot be modelled. Measured effect: the §9 score
did not move (27 -> 26 of 48 frames, three cases shifting by one frame each,
which is animation-phase noise), while on the CDP1864 colour demo the reference
went from 4 distinct colour states to 7 against the RTL's 9 -- closer, but still
with none in common. So it is a fidelity improvement rather than an accuracy one.
`tools/score-21.sh` measures the score; there was no script for it before.

For CPU debugging both sims emit the same trace layout; strip the differing
first and last columns to diff them:

```sh
diff <(awk '{$1="";$NF="";print}' c.trace) <(awk '{$1="";$NF="";print}' rtl.trace)
```

Also useful: `tools/emma02.sh` unpacks Emma 02 (the definitive CDP1802
multi-system emulator) from its own installer into `refs/emma_02/dist` with no
build and no system install — handy as a second opinion, and it ships 38 `.st2`
cartridges including an RCA test cart.

---

## 10. What changed

### 2026-08-19 — the Toshiba Visicom COM-100, and two bytes per DMA cycle

The fourth and last machine. It is sold as a Studio III relative and Robson's
`visicom.txt` calls it a "clone of the Studio 3", but it is neither: it has the
plain monochrome CDP1861, no colour RAM, no CDP1862 and no tone generator, and
its RAM is at `$1000` rather than `$0800`. `is_studio3` had to stop meaning "not
a Studio II", which would have handed it all three.

Colour comes from somewhere no other machine here puts it. Emma 02's
`Cdp1802::visicomDmaOut` reads **two** bytes per DMA cycle — `M(R(0))` and
`M(R(0)+$200)` — and takes the top bit of each, so the picture is two bit planes
512 apart and every pixel is one of four fixed colours. Implemented as a second
line buffer and shift register inside `cdp1861.v`, fed from **its own 256-byte
array** addressed by A7-A0 — the same low byte serves both of its roles, since
the video reads it during a DMA cycle (address bus = `R(0)` = `$11xx`) and the
CPU at `$13xx`, and the CPU is not driving the bus during DMA. Both planes
arrive in the same cycle with matched latency.

The four colours are fixed RGB values, not combinations of three colour pins, so
they cannot ride the `{R,G,B}` bus the 1864 defined. `RCAStudioII.sv` applies the
palette; the bus still carries a 3-bit approximation so the Verilator harness
keeps working unchanged.

Two smaller things the machine needed: `OUT 1` enables its display where every
other machine here uses `INP 1` (Emma's `<out type="on">1</out>` parses to
`PIXIE_OUT_OUT` with only the enable populated, and there is no disable port at
all); and `st2_pg_ok` had to learn that `$08`/`$09` are cartridge space rather
than RAM. All six dumped cartridges page exactly `$08-$0F`, so under the Studio
II rule the whole image was dropped and the machine booted to its built-ins as
though nothing were inserted.

Matched against **Emma 02** for behaviour — it is the only emulator that models
this machine, and it states the video rule in five lines where MAME's
`visicom.cpp` states it in bitfields. But **not** for the palette: Emma's four
colours and MAME's differ, and `refvideo/Freeway [Toshiba Visicom COM-100
Longplay] (1978).mp4` — a capture of the built-in Freeway on real hardware —
settles it at summed RGB distance 86 for MAME against 225 for Emma. Emma has
colour 1 blue-cyan where the machine is a pale green-cyan, which is a hue
difference rather than a capture artefact, so the core uses MAME's values. The
same capture is a structural check the core passes: same field, same two dashed
lanes, same car sprites. Nothing in the test suite could have caught this —
`tools/visicom-test.sh` works in colour *letters*, and the RGB lives in
`RCAStudioII.sv`, which the Verilator harness does not compile.

Verified by `tools/visicom-test.sh` (new): five built-in games and six
cartridges, each locked to the exact set of colours it puts on screen, after the
screens were checked by eye against Emma's own descriptions. Colours 2 and 3
require plane 1's bit, so any screen listing one is direct evidence the second
read happened. The Studio II side is unmoved: §9 26/48, memory decode 8/8, tone
8/8, and Invaders still animates from its `.st2`.

**A synthesis defect the simulator could not see — and it predates this work.**
Plane 1 was first read through port B of the main RAM, whose read half was
unused. That simulated perfectly and cost 8,000 ALMs. But reverting it did not
restore them: `output_files/RCAStudioII.map.rpt` still said

```
Info (276009): RAM logic "...|dpram:sram|mem" is uninferred due to
               unsupported read-during-write behavior
```

with the 512-byte RAM at 6,119 ALUTs and **0 block memory bits**. So it had
already been built out of logic; using port B doubled the array and doubled the
damage rather than causing it. The cause is the CLEAR-clears-VRAM sequencer
writing through port B — two active write ports give mixed-port read-during-
write, which an M10K cannot honour. The ROM `dpram` and the new `sram2` use the
same module with port B tied off and both infer, which is what identified it.

Fixed by moving the wipe to port A, which is safe because CLEAR is folded into
reset so the CPU is held in reset throughout. No `ramstyle` attribute and no
change to the shared `rtl/dpram.sv`. Measured across three full builds:
18,384 ALMs (44%) with plane 1 on port B, 14,096 (34%) once plane 1 got its own
array, and lower again with the wipe moved.

**The lesson: after changing anything about a memory's ports, check the
`Inferred altsyncram megafunction` list in `output_files/*.map.rpt`.** A RAM that
falls into logic still fits, still closes timing, and passes every test here.

Also here: `tools/score-conic.sh`, because the "14/28" recorded for the Studio
III PAL sweep could not be reproduced from the note. The obvious uniform-A1 sweep
over the Cartridges directory gives **16/28** both with and without this work —
measured by stashing it and re-running the identical command — so the two are
different metrics, not a regression. The script defines the number from here on,
and because it covers all three Conic sets (Cartridges, Homebrew, Sarnoff) it
prints **22/38**; 16/28 is the Cartridges subset of that.


### 2026-08-16 — Hockey/Combat "flashing strobes": INT/EFx lead the line by one cycle (AVI1861), parity-adaptive DMA request, open bus = $FF

Elle's "flashing strobes in Hockey and Combat" were frames where the BIOS
ISR's cycle-counted display machinery broke down for particular
interrupt-entry phases, rendering whole frames from the wrong addresses.
Combat strobed 2 frames in every 8 during ordinary play. Three stacked causes,
three fixes, each grounded in a reference:

- **INT and EFx now lead their nominal lines by one machine cycle**, matching
  the AVI1861 hardware replacement: its 74HC4040 line counter is clocked by
  the active-low HCLOCK asserted in line states 14+0, so it increments one
  machine cycle *before* the line boundary, and INTREQ/DISP_STATUS decode off
  it. That cycle is exactly the entry margin the BIOS ISR preamble needs
  (27 cycles + up to 4 cycles of entry latency vs a 31-cycle window when INT
  rises at line 78 sharp): without it, worst-case entries had the line-80
  burst preempt the preamble before `PLO R0` loaded the display base, and the
  whole frame displayed from stale $09F8/$0A00.
- **The DMA request is fetch/execute-parity adaptive** (lines 81+ only), the
  request-side analogue of the AVI1861's state-14 resync: the real 1861 slips
  its line phase one cycle when the CPU fetches where it should execute, so
  the burst always interleaves the ISR's `SEX/DEC R0/PLO R0` display loop at
  the intended instruction. We keep the HDMI line rigid and instead assert
  DMAO one machine cycle early on odd-parity lines. Without this, odd-parity
  frames ran the loop one instruction out of phase — R(0) was rewound every
  line and Hockey rendered entire frames as the solid border row. Line 80 is
  exempt so the request can never preempt the ISR preamble.
- **Open bus reads $FF** (was $00), matching MAME's `unmap_value_high` and
  plausible floating-bus behaviour. The remaining marginal frames read
  display data from outside $0900-$09FF; with $00 they rendered as black
  frames with an 8-pixel bar (very visibly broken), with $FF they render as
  clean full-screen white flashes. `tools/memdecode-test.sh` expectations
  updated.

The three knobs were swept empirically (INT lead × EFx lead × adapt on/off,
plus sub-cycle leads): 8/8/on is the clear optimum; every other combination
strobes hundreds of frames of a 700-frame hockey rally.

Verified: Combat gameplay strobe frames 54 → **0**, and its steady-state
frames now match the reference emulator pixel-for-pixel (`compare-game.sh`,
frames 250/350). Hockey retains ~6 marginal frames per 700 during fast
rallies — the same count as the previous build — from entry phases whose
misalignment is at whole-instruction (mod-3) granularity, which no
SC-parity-visible mechanism (ours or real hardware's) can correct; the
reference emulator confirms neither game ever sets the scroll register, so
those frames are the games' own timing marginality (both are Robson's 2000
builds, authored against his emulator's abstract ISR model). A/B against the
previous build: 5 built-ins, 18 retail carts, and all homebrew byte-identical
except Combat (the fix) — Race's custom ISR included; memdecode 8/8; lint
clean. The reference §9 sweep (builtins + 18 retail, same recipe pre/post) is
outcome-identical cart for cart.

Also from this session: the reference emulator now builds on this box
(`cd tools/refemu && make headless`; it lived under `refs/` at the time), and its
`--frame-log` prints the per-frame scroll register — that's how the "is the
flash authored?" question was settled. Emma 02 turns out to force-sync
(`setCycle0()` at interrupt and after each DMA line) so it cannot arbitrate
cycle-level races; the AVI1861 PLDs (`refs/AVI1861/pld/{frame,line}.pld`) are
the hardware ground truth for 1861 sync/DMA/INT timing and settled both the
INT lead and the parity resync.

### 2026-08-15 — the Invaders wobble WAS a core bug: fixed-slot shifter vs ISR entry jitter

**This entry supersedes (and reverses) the earlier "the wobble is the game's
own dirty redraw" diagnosis from the same day.** That analysis correctly showed
VRAM clean at every frame boundary and R0 per-line traces identical across
phases, and wrongly concluded the display path was exonerated. Both
observations were true and the conclusion still wrong, because the defect
lived *below* the per-line traces, in sub-line phase:

- The 1802 honours interrupts only at instruction boundaries, so the ISR's
  whole cycle-counted stream lands 0 or 1 machine cycle late depending on
  which instruction the game's main loop was in when INT asserted. Robson's
  2000-build Invaders (md5 350e8332...) drifts across both phases in ~14-frame
  runs; most software sits in one phase forever, which is why 18/21 never saw
  it.
- The 1861's DMA burst therefore latches byte k at hcount 31+8k on some frames
  and 39+8k on others (`--trace-cyc` on line 80 shows it directly). The
  shifter read the line buffer at fixed 32+8k — one pixel of tolerance — so on
  late frames every slot was read 8 px before its byte landed and each line
  displayed the *previous line's* buffer: picture down one scanline, and
  screen row 0 replaying the previous frame's bottom row ($09F8 = the `# #`
  fragment). "The bottom line draws at the top" was literal.
- Fix (rtl/pixie/cdp1861.v): read the buffer one machine cycle later
  (ACTIVE_START 32→40, DE follows, HSync moved to 105..111 to stay in
  blanking). Both phases now render identically; the real 1861 shifts bytes
  out as DMA delivers them, so on silicon the late phase is an 8-px horizontal
  nudge a CRT hides — the fixed window one cycle later gives the same
  tolerance with zero jitter. A burst can still theoretically land two cycles
  late ([40+]); no known software does.

Verified: A/B old-vs-new RTL over 5 built-ins, 18 retail carts, 15 homebrew
`.st2` and the 2013 Invaders rebuild — byte-identical everywhere except the
2000 Invaders (73 of 74 late frames are exactly the old frame shifted up one
scanline; fragment frames 76→0, topmost content row constant) and **Combat**,
whose diffs have the same one-scanline-shift signature: Elle's reported Combat
jitter was this same bug. memdecode test passes. New sim flag `--trace-vwr`
logs CPU writes to the display page's top/bottom rows with the writing PC
(`VWR_ALL=1` env widens it to the whole page).

Also learned the hard way: this build starts/restarts on **B0**, not A0 —
keysend keycode 51 (comma) on the MiSTer, `--press b0@F` in the sims. A0 does
nothing at the game-over "00000" screen.

### 2026-08-15 — the Cx row decoded as all-long-branch (Race), and Elle's list

Elle's problem list was Combat, Hockey, Scramble, Race. Triage against MAME:

- **Race (Andy Modla)** was a real CPU bug. The Cx decode treated the whole row
  as long branch, but N2=1 is the long-skip family (reference cosmac.vhdl):
  C4 NOP, C5-C7/CC-CF conditional long skips -- 3 cycles, P moves by 0 or 2,
  the operand bytes are never read. Race's custom ISR at $0F00 executes C4, so
  the "NOP" jumped to whatever two bytes followed and the machine ended up
  executing open bus. Fixed with a LSKIP state; the ??00 condition base is IE
  when N3 is set, per the reference, giving CC (LSIE) skip-if-IE. Race now
  shows its title and starts on B0-pad key 2, matching MAME. No retail or
  Robson title uses the skip family, which is why 18/21 never saw it.
- **Hockey works and always did** -- its start is two-step: game select (1-4 on
  pad A) *then* an option key (8 or 9). hockey.txt only documents the first
  step; every single-key probe misses it. Traced the scan loops to find the
  8/9 wait at $0434.
- **Combat and Scramble** respond correctly in sim (Combat: code then B0;
  Scramble: 6 starts each level) and are frame-identical to the verified
  corpus copies. The reported flicker/stalling is consistent with the
  pre-DMA-fix builds they were observed on; retest on current.
- The library's five other titles (Climber, computer, outbreak, rocket,
  tv-arcade-2012) are blank here and show uniform garbage in MAME's studio2
  too -- likely Studio III / different-hardware or key-dependent; unresolved,
  but not obviously a core defect.

### 2026-08-15 — DMA honoured at instruction boundaries only (the real flicker)

There are two builds of Paul Robson's Invaders in circulation; the one in
`software/` runs clean, the other (user library, 756/1024 payload bytes differ)
blanked 26 of every 28 frames in this core while MAME ran it clean. The chain:
the game waits on the ISR frame counter in a 6-cycle loop, so the interrupt
entry phase drifts each frame; the CPU was inserting the 1861's DMA burst
*mid-instruction* (between S0 and S1), which for some phases put the burst one
machine cycle early relative to the BIOS ISR's cycle-counted `PLO R0/SEX/DEC`
display loop — its `GLO R0` then sampled the row pointer before the line's
burst instead of after, R(0) rewound to $0900 every line, and the frame showed
whatever was at $0900 for a frame the game never drew into. VRAM was fine the
whole time.

A real 1802 honours DMA and interrupts only *between* instructions
(`rtl/reference/cosmac.vhdl` `state_fetch` → always `state_execute`; MAME's
cosmac does the same). Fixed in `rtl/cdp1802.v` (FETCH no longer yields to DMA;
`resume_exec` deleted) with the matching 1861 change: `DMAO` now stays asserted
until its 8 cycles are actually serviced rather than for a positional window,
dropping at the 7th acknowledge because the CPU commits one more cycle after
the request falls — holding it a cycle longer ran 9 cycles/line and R(0)
drifted +1 a line (Doodle lost its dot; that is the symptom to check).

Verified: the whole corpus — 5 built-ins, 8 homebrews in both formats — is
**pixel-identical to the pre-fix RTL** at the test frames, the memory-decode
directed test passes, and the second Invaders build goes from 328 blank frames
of 540 to zero, matching MAME. Diagnosed with three new headless-sim tools:
`--trace-r0` (per-scanline R0/DMAO/INT), `--trace-cyc FROM:TO` (per-machine-
cycle state/register-writeback), and `--swap FILE@FRAME` (mid-run cartridge
load, like an OSD swap).

### 2026-08-15 (OSD shows the detected profile)

**"Auto" is gone from the Joystick list.** It was a value inside the profile
enum, which meant the menu could tell you the core was auto-detecting but never
*what it had detected*. Now there are two rows: `Mapping` (Auto/Manual, bit 6)
and `Joystick` (the profile itself, bits 5:2, no Auto entry). On Auto the core
pushes the detected profile into bits 5:2 through hps_io's `status_set`, so the
row reads "Gunfighter" after Gunfighter loads; on Manual the row is the user's,
and it starts from whatever was last detected rather than a stale value.

Freeing value 0 from meaning "auto" also makes every one of the 16 encodings
selectable, `MAP_NONE` included — it is listed as "None" and differs from
"Clear-only" in that Start still works.

The write-back is one pulse at startup and per change (new detection, or
Manual→Auto), delayed ~0.3 s past the end of the download so `map_profile` has
settled and the HPS is no longer busy. Deliberately *not* a retry loop that
pushes until the row agrees: that would fight the user if they scrolled the row,
and would pulse forever on a Main that ignores `status_set`. Shape copied from the NES core
(`status_in`/`statusUpdate`) and Apple IIgs (`status_mirror`). A dropped pulse
only leaves the row stale — nothing about the mapping itself depends on it,
because the core plays from `auto_profile` directly.

CONF_STR bumped `v2` → `v3`, since bit 6 is new and bits 5:2 changed meaning.

**Verified in sim, with one gap.** For five cartridges, `Manual` + the detected
profile number gives byte-identical frames to `Auto` (the override path reaches
the mapping and agrees with detection), and `Auto` vs `Clear-only` differs on
Gunfighter and Star Wars (the pad is genuinely driving input). **The `status_set`
write-back itself is not simulated** — Verilator has no HPS — so that the OSD
row actually updates needs checking on hardware.

### 2026-08-15 (memory decode)

**The core finally decodes its address bus.** Everything used to come out of one
4 KB dpram with the address truncated to `ram_a[11:0]`: ROM and RAM shared the
array, `$1000` read the system ROM, the documented `$0C00-$0DFF` mirror did not
exist, and a write outside `$0800-$09FF` was silently dropped. Now:

- The ROM/cartridge image and the 512 bytes of RAM are separate arrays, so a
  cartridge can no longer be written over.
- RAM answers wherever **A9 = 0** and nothing else is decoded — `$0800-$09FF`,
  `$0C00-$0DFF`, `$1000-$11FF`, `$1400-$15FF` and so on up through 64K, at
  `A8-A0` inside the 512 bytes.
- The system ROM is decoded at `$0000-$07FF` in the first 4 K bank only, and is
  not mirrored above `$0FFF`.
- `$0A00-$0BFF` / `$0E00-$0FFF` are cartridge windows; `$0C00-$0DFF` is the RAM
  mirror unless the cartridge pages ROM over it. The `.st2` loader records which
  of pages `$0A-$0F` it actually filled, which is what makes that distinction —
  `asteroids`, `berzerk`, `pacman` and `scramble` page `$0C/$0D`, the other four
  homebrew do not and get the mirror.
- Undecoded space (A9 = 1 with no cartridge) reads back `$00`.

Matched against **MAME** `src/mame/rca/studio2.cpp`, which states the same rule
in its header comment and implements it as `map(0x0000, 0x01ff).mirror(0xfc00).ram()`
plus ROM handlers installed over `$0000-$07FF` alone. MAME returns `$FF` for
undecoded space (`unmap_value_high`); this core returns `$00` instead, matching
the C reference emulator's flat array so the §9 frame comparison stays honest,
and giving a blank scanline rather than a white one if a DMA wanders.

Verified three ways: `tools/memdecode-test.sh` (new, 8 directed checks, 4 of
which fail on the old core); the §9 comparison unchanged at 18/21; and an
A/B of every image in the corpus — 5 built-in games, 18 retail cartridges,
8 homebrew `.st2`, 8 TOSEC `.st2`, four frames each — byte-identical before and
after except `86677b` and `87201`, which render noise in the reference emulator
too. The `.st2` == `.bin` equivalence for the five TOSEC titles that exist in
both formats still holds.

Also here: `tools/compare-game.sh` could not run its no-cartridge (`-`) case on
macOS, because bash 3.2 treats an empty array expansion under `set -u` as an
unbound variable.

### 2026-08-14 (beta-tester round)

**The machine ran 4× too fast on hardware.** `ce_pix` — the 1.76 MHz timebase
the whole core is gated on — was tied high in the FPGA top, so the console ran
at 7.04 MHz: 240 Hz frames, 4× game speed, 4× beeper pitch. The Verilator
regression never saw it because the sim ties `ce_pix` high on purpose and
frame-relative behaviour is unchanged. The top now divides clk_sys by 4
(sim output verified bit-identical before/after). This is the likely root of
most beta-tester complaints, "homebrew not working properly" included.

**Real video chain.** `CLK_VIDEO = clk_sys` with `CE_PIXEL` from `video_mixer`
(GAMMA=1, scandoubler for 31 kHz analog when forced) into `video_freak`:
aspect-ratio OSD options (4:3 default, full-screen, custom) and the four
integer-scaling modes. Native output is 64×128 in a 112×262 frame at 15.7 kHz /
59.98 Hz.

**Input, per the beta testers' list.** Start presses the cartridge's start key
(per-CRC, from the manuals in the Readme; A1 default), Select is CLEAR. A
Players setting (Auto/1/2) picks which stick drives keypad B's half of split
profiles; permanently one-player profiles stay on gamepad 0 — Auto reproduces
the previously verified behaviour exactly. The J list
now carries A0–A9/B0–B9 as default-unbound buttons for direct custom mapping.
The homebrew `tennis.st2` uses its single-player keypad-B `MAP_PADDLE` profile,
which is distinct from the retail Tennis/Squash `MAP_CROSS` profile:
up/down are B2/B8, and left/Fire/right select racket sizes B4/B5/B6.
The Jaguar core's numstick (via ColecoAdam, `rtl/numstick.sv`) gives an
analog-stick on-screen keypad, OSD-selected onto pad A or B; left row reduced
to the single "0" the Studio II has. All equivalences verified in sim
(stick == matching keypress, byte-identical frames).

**Homebrew mapped, but not yet reliable on hardware.** The profiles cover all
8 Paul Robson games (both `.st2` and `.bin`, including page `$0C/$0D` games),
but Combat and Hockey show flicker/jitter, Scramble does not progress reliably,
and Invaders has minor flicker. Resolving these homebrew issues is the next major
core priority. They all fire/start on `0`, so the profiles are `MAP_HOMEBREW`
(8-way pad A with corner keys on diagonals for Berzerk, fire on B0 — never A0,
which restarts Invaders) and `MAP_HB2P` (Hockey/Combat: cross + own-pad 0). The
profile field is 4 bits internally; the OSD override stays 3.

**Extra button (MPT-02).** The Soundic/Hanimex MPT-02 Studio III machines had
swappable joysticks with the official mapping: cross on 2/4/6/8, fire 5, second
button 0. Fire/Extra mirror that; Extra presses same-pad 0 in CROSS
only (0 pauses Tennis) — never HOMEBREW, where A0 restarts Invaders. J-list
bits: 4=Fire 5=Extra 6=Start 7=Select, A0..A9=17:8, B0..B9=27:18.

**OSD fixed.** The Joystick option did nothing because `J1,Fire;` sat mid-list:
Main's menu draw pass skips `J` entries but its selection pass counts anything
`>= 'A'`, so every row after it acted on the previous entry. Non-OSD entries
(`J`/`jn`/`V`) must be last, per the docs.

### 2026-08-12

**Joystick support, mapped per cartridge.** A CRC16 of the image is taken during
`ioctl_download` and looked up at the end of the transfer to pick one of six
profiles. This is necessary rather than ornamental: the Studio II has no
joystick, so each game chose its own keys -- Tennis moves the racquet on 2/8 but
uses 4/5/6 for racquet size, and Space War fires on keypad A while steering on
keypad B. Presses are OR'd with the keyboard. Unknown cartridges get `8WAY`.

The five BIOS built-ins have no cartridge to CRC, so they are told apart by the
key that starts them (A1 Doodle, A2 Patterns, A3 Bowling, A4 Freeway, A5
Addition), latching on the first press after reset only -- those keys are reused
during play. An OSD "Joystick" setting overrides the whole thing, since the table
can only be as good as its entries.

Eight cartridges are mapped explicitly; ten are deliberately left on the default
because they are number-entry games a stick cannot drive, or are unidentified.
See the Readme for the breakdown and the reasoning.

Verified by equivalence rather than inspection: driving the stick produces
byte-identical frames to the matching keypress and both differ from no input,
including the asymmetric Space War case where fire lands on keypad A and steering
on keypad B.

**3x4 keypad layout** contributed by Elle Ball (@meauxdal), cherry-picked from
their fork -- no PR was opened. Player A's layout matches the C reference
emulator's table exactly, which helps the comparison harness.


**Sound.** The beeper is implemented: a square wave gated by the 1802's Q line,
with the pitch decay `docs/sound.txt` describes (NE555 astable whose control pin
sits on a 10uF cap, drooping to about half pitch over ~0.4s -- the "warpy"
power-up sound). ~625Hz fresh, ~312Hz fully decayed, recharging whenever Q drops.
MAME uses a flat 300Hz beeper and marks the discrete circuit unimplemented, so
this follows the hardware description instead.

Q itself was verified against the reference emulator before wiring anything up,
by logging every edge in both (`--trace-q`, in both simulators). On the built-in
Addition game they agree on edge count, on beep durations (3, 3, 2 frames) and
exactly on the third beep's frames; the small offset on the first two is the
usual instruction-rate phase difference. Measured output is ~580-600Hz.


**ST2 cartridge loader, in RTL.** `rtl/rcastudioii.sv` now parses the paged
`.st2` format during `ioctl_download`, so it works on the FPGA and not just in a
host-side loader. Triggered purely by the `RCA2` magic in the first four bytes —
the OSD extension index is deliberately not used, since a valid `.st2` always
carries the magic and going on the magic alone means a mis-named file still
loads. `CONF_STR` is `"F1,ST2BINROM"` so the browser offers all three. The page table at header offsets 64-127 is
latched into a 64-byte array as it streams past, then each 256-byte block is
written to `page << 8`.

Page validity follows the C reference, **not** `docs/cartridge.txt`: reject only
the system ROM (`$00-$03`) and RAM (`$08-$09`) pages, plus `$00` as the unused
marker. `$0C`/`$0D` are legal — `race.st2` pages ROM over the default RAM mirror
there.

Verified the strongest way available: for the five TOSEC titles that exist in
both formats, loading the `.st2` gives **byte-identical output to the `.bin`**.
The `.bin` regression is unchanged at 18/21.


**CLEAR key.** Added, mapped to **F1** and an OSD "Clear" button, folded into
`reset` (which drives the 1802's `CLEAR_N`). `docs/RCA_Studio_II_Service_Manual.pdf`
Figure 1 shows it as a console pushbutton between the two keypads, and the test
procedure on page 5 — "press and hold Clear... release Clear" — confirms it is a
momentary reset, which is what this implements. Note this does **not** change
simulator behaviour: both sims already reset at power-on, so scripted sequences
were never missing a CLEAR. It matters on real hardware and in the GUI sim, where
there was previously no way to reset without reloading the core.

The same manual settles a timing question: the Studio II clock is a **slug-tuned
RC oscillator**, adjusted by eye for "zero waveform drift" against the 60 Hz line
(§13, Figure 33). There is no exact crystal frequency, which is why MAME uses a
round 1760000 Hz.

The core went from "puts a picture on screen but most of the machine is
stubbed" to pixel-identical output. Briefly, so the history is not lost:

**CPU.** Interrupts never fired, for four stacked reasons: the transition into
`INTERRUPT` was commented out; the commented test used `INT_N == 1` though it is
active low; `IE` was never initialised (reset leaves it 1); and the `INTERRUPT`
state never set `X=2`/`P=1`. `WAIT_N`'s run/pause test was inverted and only
worked because the glue tied it low. `RET`, `DIS`, `SAV`, `MARK` were missing and
`IDL` decoded as `LDN R0` — the BIOS ISR uses `RET` and `SAV` every frame, and
`RET` was flagged `unsupported`. `SC` was driven with `<=` inside `always @*`
and unassigned on most paths, inferring a latch, so the 1861 could never see a
DMA or interrupt state code.

**Timing.** The CPU ran one state per `clk_sys` (~16x too many instructions per
frame) and `EXECUTE2` made every memory-reading instruction 3 machine cycles
instead of 2, so the ISR's cycle-counting DMA sync loop could never lock. It now
runs from a machine-cycle enable with 2-cycle instructions and lands on 1321
instructions between interrupts, matching hardware.

**Video.** `pixie_video_studioii.v` was not a 1861 at all — it ignored the CPU
and scraped `$0900-$09FF` over a second dpram port, so DMA never stole cycles
and the display base was hardwired. `rtl/pixie/cdp1861.v` replaces it: no frame
buffer, DMA-driven, timing matched to MAME's `cdp1861` including the
free-running DMA cadence the ISR synchronises against. Uniform pixel counters
fixed a 74-pixel-wide active window (the old state machine bumped the horizontal
counter from seven places and stalled); frames are now exactly 64x128. `INP 1` /
`OUT 1` actually enable the display, and `INT`/`EF1` are gated on it.

**Glue.** `SC` was a `reg` with an initialiser while driven by the CPU's output
port, so the video saw a constant "DMA" state code. The keypad latch used a bit
test so it also latched on `OUT 3/6/7`, with a blocking assignment; `EF` indexed
the 10-bit player vectors with a 4-bit latch, reading past the end for keys
10-15.

**Build.** The `.qsf` was missing the `build_id.tcl` pre-flow hook, so synthesis
could not start. Four core-specific Quartus warnings were cleared (undriven
`cpu_din` and `LED_USER`, dead `mem_r`, a `casez` overlap). The SDL sim had never
built on macOS: unquoted `-CFLAGS`, missing SDL2/OpenGL2 ImGui backends, a
Verilator-4 `verilated_heavy.h`, a `NONE` macro colliding with
`VerilatedTraceSigDirection::NONE`, internal signals needing `rootp->`, and
`VGA_WIDTH` of 128 against a 64-pixel display — which is why it looked like
garbage.

---

## 12. Credit

Jason Coombes is the original author and primary contributor by far. He
created the original CDP1802 and CDP1861 Verilog, the keypad scheme, the memory 
map, and the initial Verilator harness. Flandango handled MiSTer framework 
integration and early Pixie work. This repo is an extension of their work and 
deeply depends on it.

Alan Steremberg and Elle Ball carried the later 2026 timing, video, 
controller/profile, and OSD work that brought the core to its current playable 
state. 

Recent accuracy refinement work heavily references the following projects:

| Who | What | How it was used here |
|-----|------|----------------------|
| **Paul Robson** | C Studio II emulator, `refs/studio2-games` (2013) | The frame-by-frame reference (§9). The ST2 loader and headless harness added there are extensions of his code. Also the homebrew test software. |
| **Curt Coder** / MAME | `cdp1861.cpp`, `studio2.cpp` (BSD-3-Clause) | Scanline windows, and the free-running DMA cadence (`2*8` start, `8*8` active, `6*8` wait) the BIOS ISR synchronises against. Without this the display cannot lock — it was the last blocker. |
| **Marcel van Tongeren** | Emma 02 | Independent second opinion; `tools/emma02.sh` unpacks it. Ships 38 `.st2` carts including an RCA test cartridge. |
| **Andrew Modla** | `ajavamind/rca-studio2` | CDP1802 DMA timing documentation. |
| **Eric Smith** | `brouhaha/cosmac` VHDL 1802 + Pixie (GPL-3) | The long-standing reference for a correct 1802; `rtl/cosmac.v` is its X-HDL translation. |
| **dmadole** | AVI1861 CPLD 1861 replacement | Cycle-exact hardware truth for 1861 sync/DMA. |
| **kanpapa** | `cosmac_mbc` | Secondary HDL reference. |

`docs/` is scraped from the classicgaming Studio 2 technical pages (via the
Internet Archive).

When changing timing or video, say which reference you matched against in the
commit message — MAME, Emma 02, rca-studio2 or AVI1861 (§8).
