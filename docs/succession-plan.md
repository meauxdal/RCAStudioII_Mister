# Where this core goes next — the COSMAC machine succession

Written 2026-08-17. Companion to `CLAUDE.md` §7 (Roadmap). This is about which
*machines* to add after the Studio II, in what order, and what software we
already hold to test each one with.

The short version: **the CPU-side contract does not change.** MAME drives the
CDP1864 with the same three signals our CDP1861 already produces — `INT`,
`DMA_OUT`, `EFx` — into the same 1802 inputs. Every successor below reuses the
1802, the DMA-driven video model, the cartridge loader, the keypad scanning and
the profile system. What changes is the video chip, the memory map, and colour.
That makes these much cheaper than "a new core" suggests.

---

## 1. The lineage

```
  FRED / FRED II / FRED III        1971-75   Weisbecker prototypes, pre-silicon
        |
  RCA Studio II                    1977      <-- this core. CDP1861, mono, NTSC
        |
        +-- Toshiba Visicom COM-100  1978    Japan. Colour, own memory map
        |
        +-- RCA Studio III           1978    CDP1864: colour + tone, PAL & NTSC
        |        |
        |        +-- Soundic Victory MPT-02        (Austria)
        |        +-- Hanimex MPT-02                (France)
        |        +-- Mustang 9016 Telespiel        (Germany)
        |        +-- Sheen M1200 Micro Computer    (Australia)
        |        +-- Conic M-1200
        |        +-- Academy Apollo 80             (Germany)
        |
        +-- RCA Studio IV            1977    Prototype. Colour, 192-line mode
        |
  RCA COSMAC VIP                     1977    Sibling, not successor: same
                                             CDP1861, CHIP-8 in ROM
```

MAME puts Studio II, Visicom and the six MPT-02 badges in **one driver**
(`src/mame/rca/studio2.cpp`), which is the strongest signal about how close
they are. The six MPT-02 badges are one implementation — build the machine
once and six entries light up.

---

## 2. Order of work, cheapest useful first

### 2.0 PAL is *not* a prerequisite — it belongs to the CDP1864

An earlier draft of this plan (and `CLAUDE.md` §7.1 before it) had "add PAL"
as step zero, gating everything else. **That was wrong, and checking the
documentation is what caught it.**

There was no PAL Studio II. The CDP1861 is an NTSC part with no PAL mode
anywhere: MAME's `cdp1861.h` hard-codes `TOTAL_SCANLINES = 262` and mentions
neither PAL nor 312 nor 50 Hz; Emma 02 ships four Studio II configs
(`standard`, `multicart`, `chip8`, `test-cartridge`) and **not one of them is
PAL**; the AVI1861 hardware replacement has no PAL either. Adding a "PAL Studio
II" would be inventing a machine — and because Studio II games time themselves
off the 60 Hz interrupt, a 50 Hz mode would also slow every one of them by 17%.
MiSTer's scaler already handles PAL *displays* without touching core timing.

PAL arrives **with the CDP1864**, where it is native rather than optional — the
part is literally titled "COS/MOS PAL Compatible Color TV Interface" and MAME's
`cdp1864.h` hard-codes `TOTAL_SCANLINES = 312`. So PAL is not a step; it is part
of §2.1, and §2.1 is no longer blocked by anything.

It is per machine, not a global toggle:

| Machine | Field rate |
|---|---|
| Studio II | NTSC only |
| Studio III | **both** — Emma has paired `*-ntsc.xml` / `*-pal.xml` for every variant, and separate `studio3_ntsc.bin` / `studio3_pal.bin` |
| Soundic Victory MPT-02, Hanimex, Mustang 9016, Sheen M1200, Academy Apollo 80, Trevi M1200 | PAL |
| **Conic M-1200** | **NTSC** — the one NTSC badge in an otherwise PAL family |

Open questions to settle during §2.1 rather than guess at now:

- MAME models the 1864 as PAL-only, but Emma models an NTSC Studio III and an
  NTSC Conic M-1200. Different part, different crystal, or just a different
  config? Nobody's notes here say.
- The 1864 has **192 visible lines** against the 1861's 128, yet the MPT-02 runs
  Studio II software that only ever fills 32 rows. What the extra window does in
  practice is a bring-up question for the test cartridge.
- MAME's `SCANLINE_DISPLAY_START = 60; // ???` is flagged uncertain *by MAME*.
  Do not treat it as gospel; check it against the datasheet timing pages and the
  RCA test cartridge.

### 2.1 MPT-02 / Victory family — the big unlock

**Six machines for one implementation.** Needs:

| Piece | Effort | Notes |
|---|---|---|
| CDP1864 video | the bulk of it | Replaces the 1861. Same `INT`/`DMA_OUT`/`EFx` contract to the CPU, so our DMA and interrupt plumbing is unchanged |
| Colour output | moderate | Our chain is 1bpp mono (`video` → white). The 1864 fetches R/G/B from colour RAM per DMA byte; the mixer path has to widen |
| Memory map | small | ROM `$0000-$07FF`, RAM `$0800-$09FF`, **colour RAM 64 cells mirrored across `$0B00-$0BFF`** (§6), **ROM `$0C00-$0FFF`**. Our decode already handles `$0C00-$0DFF` as cart-or-mirror and 512 bytes mirrored across a wide window, so this is an extension of work already done |
| CDP1864 tone | small | The 1864 has its own tone generator; the 555 beeper goes away |
| PAL | see 2.0 | |

References: `refs/rca-studio2/Documents/cdp1864.pdf` (datasheet — distilled into
§6) and MAME's `src/devices/sound/cdp1864.cpp`. Note MAME files it under
*sound* — it is a combined video+sound part.

Pleasing continuity: our `CROSS` joystick profile is already the MPT-02
joystick layout (cross on 2/4/6/8, fire 5, second button 0), taken from the
MPT-02's own swappable controller. The controller work is done before the
machine arrives.

### 2.2 Visicom COM-100

Toshiba's Japanese variant. Smaller than MPT-02 but a genuinely different
memory map, so it does not fall out of 2.1 for free:

```
$0000-$07FF  ROM          $1000-$10FF  RAM
$0800-$0FFF  cartridge    $1100-$11FF  colour RAM 0
                          $1300-$13FF  colour RAM 1
```

Two colour planes rather than the 1864's palette. **No ST2 support** — MAME
notes this explicitly, so the cartridge loader needs a raw path.

### 2.3 Studio III proper

The RCA-badged CDP1864 machine the MPT-02s derive from. Once 2.1 exists this is
close to a BIOS swap plus whatever differences the test cartridge exposes. We
hold `studio3_ntsc.bin` and `studio3_pal.bin`.

### 2.4 Studio IV (prototype)

Now unusually well-documented for us, because the technical archive turned up
**Weisbecker's own typed I/O spec** (`docs/rca-technical/Studio II III IV/
IMG_0353.JPG`, 7-20-77) — see `CLAUDE.md` §2.1. It gives the whole port map:
`61` tone, `62` key select, `63` output port, `64` TV control (RGB background,
spot map, TV on/off, **192-vs-128 lines**), `65` DMA-out, `6B` input port, and
"TV off after reset". Plus his colour-chip sketch (`IMG_1535.JPG`).

Software here is BASIC/system images rather than cartridges, so it is a
different kind of target — closer to a computer than a console.

### 2.5 COSMAC VIP — sibling, and the biggest software payoff

Not a successor, but worth ranking because it **reuses our CDP1861 unchanged**.
It is a single-board computer: hex keypad, cassette, CHIP-8 interpreter in ROM.
The video is already built. Against that, it needs a keypad/cassette UI that
has nothing to do with the console work, and CHIP-8 emulators are abundant, so
the novelty is lower even though the file count is enormous.

---

## 3. Software we already hold

### Studio II — very well covered (this core)

| Set | Count | Where |
|---|---|---|
| No-Intro retail `.bin` | 18 | `software/carts/` |
| Public domain, committed | 48 | `pd_software/` |
| TOSEC `.st2` / `.bin` | 8 / 6 | `software/tosec/` |
| Paul Robson homebrew, **with asm source** | 8 | `refs/studio2-games/Games/` |
| Emma 02: cartridges / homebrew / Sarnoff | 11 / 15 / 7 | `refs/emma_02/data/St2/StudioII-*` |

### Studio III / MPT-02 family — enough to develop against

| Set | Count | Where |
|---|---|---|
| Conic/Studio III cartridges | 14 | `refs/emma_02/data/St2/Conic_StudioIII-Cartridges/` |
| Conic/Studio III homebrew | 1 | `.../Conic_StudioIII-Homebrew/` |
| Conic/Studio III Sarnoff Collection | 4 | `.../Conic_StudioIII-Sarnoff-Collection/` |
| BIOS: `studio3_ntsc.bin`, `studio3_pal.bin`, `chip8.bin` | 6 | `refs/emma_02/data/StudioIII/` |
| BIOS: `victory.rom`, `studio3.rom` | 5 | `refs/emma_02/data/Victory/` |
| **`RCA_TEST_CARTRIDGE_TESTER1.st2`** | 1 | `refs/emma_02/data/StudioIII/` — a real test cartridge, the best possible bring-up target |

The Conic set is the same catalogue as the Studio II one (pinball, speedway,
spacewar, tennis, star-wars, baseball…) rebuilt for colour, so **the same game
can be diffed across both machines** — a strong accuracy check that does not
exist for any other target here.

### Visicom

| Set | Count | Where |
|---|---|---|
| Cartridges | 6 | `refs/emma_02/data/St2/Visicom-Cartridges/` |
| BIOS `visicom.rom` | 1 | `refs/emma_02/data/Visicom/` |

### Studio IV / Studio 2020

| Set | Count | Where |
|---|---|---|
| Studio IV V2/V3 NTSC+PAL, `am4kbas` BASIC, super-chip | 12 | `refs/emma_02/data/StudioIV/` |
| Studio 2020 NTSC + PAL | 2 | `refs/emma_02/data/Studio2020/` |

### Adjacent, if the family is ever widened

| Machine | Count | Where |
|---|---|---|
| COSMAC VIP programs | 47 | `refs/emma_02/data/Vip/` (+7 VipII) |
| CHIP-8 / SCHIP programs | 410 | `refs/emma_02/data/Chip-8/` |
| FRED I / I.5 | 78 | `refs/emma_02/data/FRED1*/` |
| Coin Arcade (`.arc`, `.fd2`) | 11 | `refs/emma_02/data/CoinArcade/` |

Everything under `refs/` and `software/` is git-ignored; `pd_software/` is the
only set committed to the repo.

---

## 4. What to settle before starting

- **How to expose multiple machines.** One core with a machine selector, or
  separate `.rbf` per machine? Affects the OSD, the config string, and how the
  BIOS is chosen. Decide before writing the 1864, not after.
- **Colour in the video chain.** Widening past 1bpp touches `video_mixer` setup
  and the sim's frame grabber and ASCII output, which currently assume one bit
  per pixel. The §9 comparison harness needs a colour-aware mode or the whole
  regression stops working for the new machines.
- **What the reference emulator becomes.** Settled — see §5.

---

## 5. The reference emulator: extend Robson, don't adopt Emma 02

The §9 comparison diffs against Paul Robson's C Studio II emulator, which knows
nothing about the CDP1864 — so the harness goes dark exactly when the colour
machines arrive. Two obvious ideas, both investigated 2026-08-17, both rejected:

### Making Emma 02 the harness — no

Not an effort question. Emma's emulation is structurally welded to wxWidgets:

```
class Video : public wxFrame        // the video emulation IS a GUI window
class Pixie : public Video
void Video::drawPoint(wxCoord x, wxCoord y) { gc->DrawRectangle(x,y,0,0); }
```

Every pixel is painted straight into a wx device context. **There is no
framebuffer array to read back** — nothing to capture, hash or diff without
replacing the drawing substrate across 183 files and 135k lines. The entry point
is `IMPLEMENT_APP(Emu1802)` on `wxApp`; the `wxCmdLineParser` in there is
argument parsing inside the GUI, not a batch mode. And `Cdp1802 : public
IoDevice, public Memory, public Sound` means the CPU inherits memory and sound,
so a single machine does not lift out cleanly either.

### Porting Emma's 1864 into Robson — the wrong donor, technically

**Licensing is not the blocker.** Emma's headers carry a non-commercial clause
(and the repo ships a contradictory `agpl-3.0.txt`), but the harness is a local
debugging artefact that is never distributed: GPL obligations attach to
distribution, private modification is explicitly permitted, and a hobby core is
not a "commercial application". `refs/` is git-ignored, so none of it can reach
the repo by accident. If the harness ever *is* released, revisit this.

The real blocker is that **there is no CDP1864 in Emma to take.** It is not a
module — there is no `cdp1864.cpp`, and no `Pixie1864` class. The 1864 is
configuration state (`CDP1864Configuration`) threaded through the generic
`Pixie` class alongside the 1861 and 1862, driven by XML, and `Pixie` is:

- 1,682 lines, inheriting `Video : public wxFrame`
- 40 calls into the `p_Main` global and **81** into `p_Computer`

So "port Emma's 1864" means lifting the generic Pixie, its XML configuration
machinery, and two application-wide singletons. Compare MAME's `cdp1864.cpp`:
638 self-contained lines with exactly the interface we need
(`int_cb`, `dma_out_cb`, `efx_cb`, `rdata/bdata/gdata_cb`).

**Emma is still useful here, as data rather than code.** Its XML machine configs
are a port spec with no extraction problem at all —
`refs/emma_02/data/Xml/Conic/soundic_victory_mpt-02.xml` gives the MPT-02's tone
port (`OUT 4`, agreeing with MAME's `mpt02_io_map`), the full RGB palette
including the four background colours, and the colour RAM range. Use it to
cross-check the port.

The apparent Emma-vs-MAME disagreement over the colour RAM range turned out not
to be one — see §6.

### What to do instead: MAME's 1864 into Robson

| | Licence | Size | Fit |
|---|---|---|---|
| MAME `cdp1864.cpp`/`.h` | BSD-3-Clause (Curt Coder) | **638 self-contained lines** | Clean device interface; the same authority we already matched the 1861 against |
| Robson `studio2/` | MIT | 2,524 lines, no deps | Already extended with our `headless.c`; video is `CPU_GetScreenMemoryAddress()` into emulated RAM — the same DMA-reads-RAM model as the RTL |

Chosen on extractability, not licence — though it happens that both are
permissive, which keeps the option of releasing the harness open. Task #11.

**State this caveat with any accuracy claim.** If both the RTL and the reference
emulator derive from MAME's 1864, the comparison verifies *"the RTL matches our
C port of MAME"*, not that the model is independently right. It still catches
RTL timing, DMA and state-machine bugs — which is most of what the harness has
ever actually caught — but it is a weaker claim than the Studio II 18/21, where
Robson's emulator was written independently of MAME. Emma 02 stays as the
independent second opinion for eyeball checks; `tools/emma02.sh` already unpacks
it for that.

---

## 6. CDP1864 spec, from the datasheet

`refs/rca-studio2/Documents/cdp1864.pdf` is a scan with no text layer — render it
before searching: `pdftoppm -r 150 -jpeg cdp1864.pdf out`. Page 5 (sheet 89) is
the functional description of the terminals and answers most design questions.
**Settle conflicts here first**, rather than picking between emulators.

### Chip-level facts

| | |
|---|---|
| Part | "COS/MOS **PAL Compatible** Color TV Interface" — PAL is native, not an afterthought |
| Clock | **1.75 MHz** crystal (matches MAME's `1.75_MHz_XTAL` for both CPU and CTI) |
| Colour | Programmable **1-of-8 dot colours** plus **1-of-4 background colours** |
| Resolution | Bit-mapped, max **192 vertical × 64 horizontal** |
| `INLACE` | high = 625 lines/frame interlaced; low = **312 lines/frame non-interlaced** |
| Tone | 256 tones, **107 Hz – 13672 Hz**, from a programmable divider |
| `BURST` | 4.57 µs pulse on each h-sync back porch (blanked for 24 lines during v-sync) |
| `ALT` | toggles at each h-sync, driving PAL phase alternation |

### The port map, straight from the datasheet

- **`N0`** with `MRD`+`TPB` steps the background colour, and `N0·TPB` enables
  INTERRUPT and DMA. The datasheet spells out the opcodes: "a **61** instruction
  would step the background color, and a **61 or 69** instruction would enable
  the INTERRUPT and DMA requests."
- **`N2`** with `MRD`+`TPB` loads the tone-generator latch, and disables INT/DMA:
  "a **64** instruction would result in data being loaded into the tone-divider
  latch, while a **6C** instruction would disable the INTERRUPT and DMA requests."

So `OUT 4` is the tone latch and `OUT 1` steps the background — which is what
both MAME's `mpt02_io_map` and Emma's `soundic_victory_mpt-02.xml`
(`<out type="tone">4</out>`) already say. Three sources agree.

- **`EF`** emits two pulses per field, each four horizontal lines wide: one
  starting four lines before the display, one four lines before it ends. That is
  the same shape as the 1861's `EF1`, so **our existing EF model carries over**.
- **`CON` (Color On)** is "connected to the gated `MWR` signal of the color
  memory" — writing to colour RAM is what switches colour on. MAME fakes this
  with `m_cti->con_w(0); // HACK` on every DMA; worth doing properly.
- **`RDATA`/`GDATA`/`BDATA`** "carry color information from the color RAM…
  latched concurrent with the latching of the luminance information from the
  data bus during the display interval". Colour is fetched **in parallel with
  each DMA luminance byte**, not on a separate pass.

### The colour RAM range: not a conflict

Emma declares `0xb00-0xbff`, MAME maps `0x0b00-0x0b3f`. The datasheet does not
adjudicate, because colour RAM size is a *board* choice, not a chip one — the
"typical color system" figure just shows a CDP1822 (256×4) as the colour map.

MAME's DMA handler shows what the MPT-02 board actually does:

```c
uint8_t addr = ((offset & 0xe0) >> 2) | (offset & 0x07);   // = {offset[7:5], offset[2:0]}
m_color = m_color_ram[addr];
```

A **6-bit index — 64 distinct cells.** With 8 bytes per 64-pixel row and 32
rows, `offset[2:0]` is the column and `offset[7:3]` the row; MAME keeps only
`offset[7:5]`, so colour is one cell per **8 columns × 4-row group**.

That makes the two descriptions the same hardware: 64 bytes of storage inside a
decoded window of one page, i.e. **mirrored four times across `$0B00-$0BFF`** —
exactly the window-versus-storage distinction we just implemented for the Studio
II's 512 bytes of RAM (CLAUDE.md §10, 2026-08-15). Emma names the window, MAME
names the storage. Implement 64 cells, mirror them across the page, and both are
satisfied.

### Method note

This is the general rule for the successor work: where two emulators disagree,
go to `refs/rca-studio2/Documents/`, `docs/rca-technical/` and the datasheets
before choosing. Every conflict hit so far — open bus `$00` vs `$FF`, the keypad
strobe, the built-in game order, and this one — was settled by paper, and in two
cases the paper contradicted what the RTL already did.

---

## 7. MPT-02 bring-up: where it stands (2026-08-17)

The machine runs. `--machine mpt02` in both the RTL sim and `tools/refemu`, and
`tools/compare-game.sh --machine mpt02 --bios <studio3_pal.bin>` diffs them.

**Use the PAL BIOS.** `studio3_pal.bin` or `victory.rom`. The NTSC images do not
run under PAL timing — an NTSC colour machine needs its own frame timing, not
just a different ROM (see `tools/refemu/README.md`).

Score against the reference, 2 frames per cartridge:

| Set | Cartridges | Frames matching |
|---|---|---|
| Conic/Studio III cartridges | 14 | **14 / 28** |
| Sarnoff Collection (`.st2` only) | 4 | 4 / 8 |
| Conic homebrew (`invsn.st2`) | 1 | 2 / 2 |

The Conic figure was 18/28 when first measured and dropped to 14/28 when the
reference emulator's cycle model was corrected (task #13). Nothing in the RTL
changed; the reference moved. That is the same effect the §9 Studio II score saw
(27 → 26 of 48) but larger, and for the same reason — the display window is
proportionally bigger on these machines, so giving the CPU its display-window
cycles shifts more software. **Read these numbers as "how far the two models
agree", not as an accuracy figure for the RTL.**

Frame rate comes out at **50.373 Hz** from the existing PLL (112 × 312 pixel
times at clk_sys/4), against the datasheet's 50.08 Hz — 0.6% fast, which is not
worth a second PLL output.

### `color-demo.st2`: chased and explained — the reference cannot arbitrate this

**Resolved 2026-08-17, and my first hypothesis was wrong.** I guessed the
reference's render-time colour lookup was at fault. It is not. The real cause is
the reference's *CPU budget*, and it disqualifies the reference for any
timing-sensitive comparison on this machine.

What was measured, in order:

1. The colour **RAM contents** differ, not the indexing — so the fault is
   upstream of display. (Colour index and the R/B/G→RGB permutation are provably
   identical on both sides.)
2. The demo **animates** its colour RAM, so phase was the obvious suspect.
3. But over frames 120–220 the two sides share **zero** colour states: the RTL
   cycles through 9 distinct ones, the reference only 4, mostly stuck on a single
   value. Not phase.
4. Cause: **the reference executes 854 instructions a frame where the RTL
   executes 1485 — a measured 1.74×.** Its model gives the CPU only
   `STATE_1 + STATE_2` = `(312-192)*14 + 29` cycles and **nothing at all during
   the 192 display lines**, where the RTL runs the CPU all frame and loses only
   the 8 machine cycles a line that DMA actually steals. A demo that paints colour
   RAM across the frame simply never gets those writes in on the reference.

This is the weakness `CLAUDE.md` §9 already documents for the Studio II
(~952 against 1321, a 1.39× gap) — but it is **worse here**, because the display
window is proportionally larger: 192 of 312 lines against 128 of 262.

Consequences, which matter for how the harness gets used:

- The RTL is very likely **right** here and the reference wrong. Not proven —
  proving it needs Emma 02, which ships this cartridge.
- The 24/38 score above measures agreement on **static** content and little else.
  Do not read it as an accuracy figure. Anything that computes during the display
  window will diverge for reasons that have nothing to do with the RTL.
- To make the comparison trustworthy for these machines, `tools/refemu` needs a
  real cycle model: execute during the display window too, minus the DMA steal.
  That is a change to Robson's timing model rather than a bug fix, so it is filed
  separately rather than done in passing.

### Also outstanding

- Tone generator (256 tones, 107Hz–13672Hz on `OUT 4`) in neither side.
- `BCKGND`, which lowers background luminance so one colour can serve as both
  background and data. Needs a fourth video bit.
- NTSC colour machines (Studio III NTSC, Conic M-1200) need their own timing.
- `grand-pack.st2` (CRC `1594`) has no joystick profile entry and falls to the
  default; the other 13 Conic CRCs were already in the table, paired with their
  Studio II equivalents.

---

## 8. Why analog video does not sync (2026-08-18)

The Readme lists "Analog video does not work yet" and "Direct video does not
work yet". The cause is not a sync polarity or a clock rate — **we are not
emitting a TV raster at all.**

Both video parts here blank everything outside the bitmap, so the active area we
present is 64×128 (Studio II) or 64×192 (Studio III) inside a 112×262 or 112×312
frame. Even a display that locks to the sync has no picture to draw.

### What the real part does

It emits a **full-size raster with the small bitmap inside it**, and the border is
active video painted in the background colour — not blanking. Three sources say
so independently:

- **Datasheet Fig. 4** (p6) draws it literally: `VERTICAL BLANKING` and
  `HORIZONTAL BLANKING` at the edges, a large region marked `BACKGROUND`, and the
  64×192 `DISPLAY AREA` inside that.
- **Datasheet Fig. 6** (p8): horizontal blanking totals 13.14 µs of a 64 µs line,
  leaving ~50.9 µs active. Vertical blanking is 24H of 312, with the 4H vertical
  sync inside it.
- **MAME's `cdp1861.h`**: `HBLANK_END = 12` against `SCREEN_WIDTH = 112`, so 100
  of 112 pixel times are active; `SCANLINE_VBLANK_END = 16` of 262, so 246 lines
  are active. The 64×128 display sits inside that.

And the photographs of real Studio III output confirm it: the picture occupies
the middle of the screen inside a wide border, and that border is the background
colour (black in most of those shots, because those programs selected black).

### There is no upscaler — that was the question

Nothing scales anything. The picture fills a TV screen by three plain means:

1. **Vertically**, software shows each logical row over several scanlines by
   rewinding `R(0)` — 4 lines a row on the NTSC 1861, 6 on the PAL 1864. That is
   what the ISR in datasheet Fig. 5 is doing with its repeated
   `DEC R0` / `PLO R0`, and why 32 rows becomes 128 or 192 lines.
2. **Horizontally**, pixels are simply *wide*: one per CPU clock, 568 ns each, so
   64 of them span 36.4 µs of a ~51 µs active line.
3. **The rest of the raster is background colour**, which is what makes the frame
   full-size.

### Measured gap

| | ours | should be |
|---|---|---|
| HSync | 3.98 µs | 4.57 (1864) / 4.7 (NTSC) |
| front porch | 0.57 µs | ~1.5–3.14 |
| back porch | **22.72 µs** | ~4.7 |
| active | 36.36 µs | ~50.9 |
| active lines | **128 of 262** | ~246 of 262 (NTSC), ~288 of 312 (PAL) |

Three faults at once: the sync pulse is narrow, the porches are so asymmetric the
picture would sit far right even if it locked, and the active window is a
fraction of the raster.

### Fixed 2026-08-18

Both parts now emit a real raster: **88×242** on the NTSC 1861 and **88×292** on
the PAL 1864, measured out of the sim. Line layout, against Fig 6:

| | ours | Fig 6 |
|---|---|---|
| front porch `0..8` | 4.54 µs | 3.14 |
| HSync `8..16` | 4.54 µs | 4.57 |
| back porch `16..24` | 4.54 µs | 3.43 |
| active `24..112` | 49.99 µs | 50.86 |

The bitmap stays at `40..104` because the DMA phase pins it — the BIOS ISR counts
cycles against that burst — so it sits 16 pixels from the left of the active area
and 8 from the right rather than dead centre. Vertically the 1864 blanks 20 lines
(Fig 4's `20H`) and the 1861 wraps 20 lines around the end of the frame, keeping
its VSync at 254 so the sim's frame boundary does not move.

On the 1864 the border is painted in the **background colour**, which is the
BACKGROUND region of Fig 4 and the reason the picture fills a TV. On the mono
1861 it is black.

**The harness was protected rather than re-baselined.** The core now exports a
second `bitmap_de` alongside `video_de`, marking the 64×128 / 64×192 bitmap
alone, and the Verilator frame grabber captures that. So captured frames keep
their old size and every recorded score keeps its meaning: Studio II byte-identical
across all 71 images, §9 score 26/48 unchanged, Conic 14/28 unchanged, memdecode
8/8, tone test passing.

**This section is the diagnosis and the fix. For the current state, the test
procedure and what to do when it does not lock, see `docs/analog-video.md`.**

Still open: the picture is not horizontally centred (16 px left border against 8),
because centring it would mean moving the DMA phase that the ISR depends on. And
none of this has been seen on real analog hardware yet — it is verified against
the datasheet's figures and the sim, not a TV.

None of this affects HDMI, where `video_freak` scales whatever it is given — which
is why the core looks correct on HDMI and produces nothing usable on analog.

---

## 9. The NTSC Studio III is a different chipset (2026-08-18)

`#16` was written as "give the CDP1864 a second, NTSC set of timings". That
premise is wrong, and Emma 02's machine XML says so outright.

`refs/emma_02/data/Xml/StudioIII/standard-ntsc.xml` against `standard-pal.xml`:

| | PAL Studio III / MPT-02 | **NTSC Studio III** |
|---|---|---|
| video | `<video type="1864">` | **`<video type="cdp1861">`** |
| colour | inside the 1864 | **`<video type="cdp1862">`** |
| sound | inside the 1864 | **`<sound type="cdp1863">`** |
| frame | 312 lines, display 76..267 (192) | 262 lines, display 64..191 (128) |
| interrupt | line 74 | line 62 |

So the PAL machine integrates video, colour and tone into one part, and **the NTSC
machine is three separate chips**: the CDP1861 we already have, plus a CDP1862
colour generator and a CDP1863 tone generator. That is why `studio3_ntsc.bin`
will not run under PAL timing — not a timing tweak, a different video subsystem.
It is also why MAME cannot help: it has no NTSC Studio III at all.

### The good news: we have already written most of it

MAME's device headers show the 1862 and 1863 are exactly the halves of the 1864
we implemented:

- `cdp1862.h` has `rdata_cb` / `bdata_cb` / `gdata_cb`, `bkg_w` and `con_w`, and
  `BKG LUM` / `BKG CHR` pins. Same colour RAM at `$0B00-$0BFF`, same background
  step on `OUT 1`, same CON, same background-luminance idea as BCKGND.
- `cdp1863.cpp` takes its latch on `OUT 4` as the 1864 does. Its divider differs:
  `clock/8/(latch+1)/2` against the 1864's `clock/8/4/(latch+1)/2`, so the same
  latch gives four times the frequency.

So the work is mostly *re-attaching* logic we have, not writing new logic.

### What it actually takes

1. A third machine value in the OSD row, and the memory decode (`$0C00-$0FFF`
   ROM, colour RAM at `$0B00`) driven by "is a Studio III" rather than by
   "is the 1864", which is how it is gated today.
2. The colour path — colour RAM lookup, border, CON, BCKGND — factored out of
   `cdp1864.v` so the 1861 can use it too. That is the bulk of it.
3. The 1863 divider, which is the 1864's with one fewer division stage.
4. **The risk:** Emma puts the NTSC Studio III display at 64..191 with the
   interrupt at 62, where our 1861 uses 80..208 and 78 (MAME's numbers, tuned
   against real software). Same structure, 16 lines apart. Making the 1861's
   geometry machine-dependent touches the timing that took many iterations to
   settle — see its `INT_LEAD` / `EFX_LEAD` / `DMA_ADAPT` commentary. Do that
   part last and behind an A/B against the Studio II corpus.

### Implemented, and the decomposition is confirmed (2026-08-19)

Built, and it boots — which is the proof the documentary evidence could not give.
`studio3_ntsc.bin` now runs under `--machine studio3ntsc` and renders Conic
pinball in full colour at 64×128, against the PAL machine's 64×192: blue field,
yellow border, green and red bumpers, magenta targets, cyan lanes. Before this it
would not start at all.

How it went together, in the order it was done:

1. **`rtl/pixie/cdp1863.v`** — the tone generator lifted out of `cdp1864.v`,
   since both machines need it and only one has an 1864 to hold it. A `div4`
   input picks the chain: the 1864's integrated generator has an extra
   divide-by-4 that the standalone part does not, so the same latch sounds four
   times higher on NTSC.
2. **The machine select widened to two bits** — Studio II, Studio III PAL, Studio
   III NTSC — with the memory map (`$0C00-$0FFF` ROM, colour RAM at `$0B00`) and
   the tone now keyed off *"is a Studio III"* rather than *"has an 1864"*, which
   is how they had been gated. CONF_STR to `v5`.
3. **The 1861 latches a colour and a CON bit with each DMA byte** and shifts them
   beside the luminance, exactly as the 1864 does. That has to live where the DMA
   is. It is inert on a Studio II, which drives `con` low.
4. **`rtl/pixie/cdp1862.v`** — deliberately thin, because step 3 does the hard
   part: it only chooses between the dot colour and the background, which is what
   the real part does with its RDATA/BDATA/GDATA inputs and its BKG pin.

Nothing regressed: Studio II byte-identical across all 71 images, §9 score 26/48,
Conic PAL 14/28, memdecode 8/8, tone test passing.

**Still to do on this machine.** Emma puts the NTSC Studio III display at 64..191
with the interrupt at 62, where our 1861 uses 80..208 and 78. It currently runs on
the Studio II's geometry, which is why it works at all — making that
machine-dependent touches the `INT_LEAD` / `EFX_LEAD` / `DMA_ADAPT` timing that
took many iterations to settle, and wants an A/B against the Studio II corpus
behind it. Conic M-1200, which Emma lists as NTSC, comes along once that is
settled. And none of the NTSC side is checked against the reference emulator,
which models only the PAL machine.

---

## 10. Studio IV: out of scope for this core (2026-08-19)

`#9` asked whether the Studio IV is worth attempting. Having read both
Weisbecker's own I/O spec and Emma 02's machine configs: **not in this core.** It
shares the 1802 and almost nothing else.

Emma's `data/Xml/StudioIV/*.xml`:

| | Studio II / III | Studio IV |
|---|---|---|
| video | `pixie` / `cdp1861` / `1864` | **`st4`**, its own part |
| colour RAM | 64 cells at `$0B00` | **1 KB**, at `$2800-$2BFF` or `$1000-$13FF` — *configurable* |
| RAM | 512 bytes | up to **`$97FF`** on the 32 K builds |
| ports | `OUT 1` background, `OUT 4` tone | `OUT 4,6` colour, `OUT 5` DMA |
| software | cartridges | BASIC and CHIP-8 **system images** |

The software on disk says the same thing: `am4kbas` (4 K BASIC) in 1978, 2020 and
32 K variants, `super-chip`, and Studio IV V2/V3 system ROMs. There is not a
cartridge among them.

So none of what this core is built around applies — not the ST2 loader, the CRC
profile table, the keypad model, the 512-byte RAM decode, nor the cartridge
paradigm itself. It is a computer that happens to share a CPU, and it belongs in
its own core.

**What we do have, for whoever takes it on**, is unusually good: Weisbecker's
typed "STUDIO IV INSTRUCTIONS" of 20 July 1977 (`docs/rca-technical/Studio II III
IV/IMG_0353.JPG`, transcribed in `CLAUDE.md` §2.1) gives the whole port map —
`61` tone, `62` key select, `63` output port, `64` TV control with RGB background,
spot map and the 192-vs-128 line select, `65` DMA-out, `6B` input port, and "TV
off after reset". Emma's `<out type="dma">5</out>` agrees with his `65`, so the
production machine kept at least part of that prototype map. His colour-chip
sketch (`IMG_1535.JPG`) and the "III A — STUDIO II COMPATIBLE" design
(`IMG_1536.JPG`) are the surrounding context.

---

## 11. Visicom COM-100: done (2026-08-19)

`#8`, and the last machine on the list. It was deferred once as "a bigger job
than it looks", on the strength of MAME's `visicom.cpp`: RAM above `$0FFF` where
our decode stopped, a 2bpp planar path through the 1861's shifter, and a
four-entry palette of arbitrary RGB values the 3-bit video bus cannot express.
All three were real; none was as bad as it looked, because Emma 02 states the
video rule in five lines where MAME states it in bitfields.

### What it actually is

`Cdp1802::visicomDmaOut` (Emma 02, `src/cdp1802.cpp`):

```cpp
*vram1 = readMem(scratchpadRegister_[0]);
*vram2 = readMem(scratchpadRegister_[0]+0x200);
scratchpadRegister_[0]++;
```

and in `src/pixie.cpp`, per pixel: `if (vram1 & 128) color |= 1; if (vram2 & 128)
color |= 2;`. So DMA reads two bytes rather than one, 512 apart, and each pixel
is one of four colours instead of on/off. There is no colour RAM, no CDP1862, no
`CON`, no background stepping — none of the Studio III colour machinery applies.

Memory, from `data/Xml/Visicom/standard.xml`:

```
$0000-$07FF  ROM   BIOS, built-in games at $0400-$07FF
$0800-$0FFF  ROM   cartridge
$1000-$11FF  RAM   512B: scratch at $1000, bit plane 0 at $1100
$1300-$13FF  RAM   256B: bit plane 1              ($1100 + $200, as above)
$1200-$12FF        nothing
```

Both RAM windows repeat every `$400` to `$FFFF`. Emma spells every mirror out in
`<map>`; decoding A9-A0 inside each 1K page is the same statement.

I/O differs in one place that matters: `<out type="on">1</out>` where the Studio
II has `<out>1</out>` and `<in>1</in>`. Emma's parser turns that into
`PIXIE_OUT_OUT` with only the enable populated, so **`OUT 1` turns the display
on** and there is no disable port at all.

### How it was built

- `rtl/pixie/cdp1861.v` gained `vis_mode`, `data_in2` and a `vis_index[1:0]`
  output: a second line buffer and shift register beside the first, clocked
  together. `video` becomes "either plane set", because colour 0 is a dark green
  background rather than black.
- Plane 1 is **its own 256-byte array**, addressed by A7-A0. That works because
  the low byte is the same in both of its roles: the video reads it during a DMA
  cycle, when the address bus holds `R(0) = $11xx`, and the CPU reads or writes
  it at `$13xx`. The CPU is not driving the bus during a DMA cycle, so a single
  port serves both and both planes arrive in the same cycle with matched latency.

  This started as port B of the main RAM, whose read half was unused, and that
  was wrong in a way nothing in simulation could show — see "the 8,000 ALMs"
  below.
- The palette is applied in `Studio-II.sv`, which is the only place wide enough
  for it. `video[2:0]` still carries a 3-bit approximation so the Verilator
  harness and anything else with three wires keeps working.
- `st2_pg_ok` had to learn that `$08` and `$09` are cartridge space here. All six
  dumped cartridges page exactly `$08-$0F`; under the Studio II rule the entire
  image was dropped and the machine booted to its built-ins as though empty.

### The palette: a hardware capture overrules Emma 02 (2026-08-19)

The four colours first shipped as Emma 02's, from `Visicom/standard.xml`. They
are wrong. `refvideo/Freeway [Toshiba Visicom COM-100 Longplay] (1978).mp4` is a
capture of the built-in Freeway on a real machine, and sampling it gives:

| | captured | Emma 02 | dist | MAME | dist |
|---|---|---|---|---|---|
| background | `#003700` | `#004000` | 9 | `#004000` | 9 |
| colour 1 | `#B1ECE6` | `#70D0FF` | 75 | `#AFDFE4` | **13** |
| colour 2 | `#DCE12D` | `#D0FF70` | 74 | `#B9C42F` | **45** |
| colour 3 | `#FF3D46` | `#FF7070` | 66 | `#EF454A` | **18** |
| | | | 225 | | **86** |

So the core now uses MAME's `VISICOM_PALETTE`. The capture is a composite NTSC
encode and its absolute levels are not trustworthy — but colour 1's *hue* is not
a capture artefact: Emma has it blue-cyan, the hardware is a pale green-cyan.

The capture is also a structural check, and the core passes it: same dark green
field, same two dashed lane lines, same car sprites in the same two colours. Only
the horizontal inset differs, which is the capture's own framing. Note the frame
comparison could not have caught the palette — `tools/visicom-test.sh` works in
colour *letters*, and the RGB values live in `Studio-II.sv`, which the Verilator
harness does not even compile.

### Verification

There is no frame-by-frame reference for gameplay: `tools/refemu` covers the
Studio II and the two Studio IIIs, and Emma 02 has no headless mode (§5). `tools/visicom-test.sh`
covers it instead — every built-in and every cartridge, locked to the exact set
of colours it puts on screen. Colours 2 and 3 need plane 1's bit, so any screen
listing one is direct evidence the second read happened.

The screens were checked by eye against Emma's own descriptions before being
locked: Addition really is a two-player scoreboard, in cyan and yellow;
`cas-190` really is a cyan border round the word HOROSCOPE; `cas-130` is a
baseball diamond with a red bat and three scoreboards. That the two score groups
come out solidly cyan and solidly yellow is also the evidence for the `+$200`
offset specifically — a misaligned second plane would break them up.

Start keys are Emma's (`Helpfiles/FaqVisicom*.htm`): built-ins on 1 Doodle,
2 Bowling, 3 Patterns, 4 Freeway, 7 Addition, and every cartridge on 0. The
gamepad Start button presses 0 on this machine rather than the usual 1.

### The RAM that was never in block RAM

Reading plane 1 through port B of the main RAM simulated perfectly and cost
nothing visible: lint clean, every test green, frames correct. The Quartus build
is where it showed — and it showed something older than this work.

`output_files/RCAStudioII.map.rpt` reports which arrays became block memory. The
main RAM was not among them:

```
Info (276009): RAM logic "...|dpram:sram|mem" is uninferred due to
               unsupported read-during-write behavior

dpram:sram   12,384 combinational ALUTs   6,160 registers   0 block memory bits
```

Reverting the plane-1 change did not fix it — the same message, at half the size
(6,119 ALUTs). So the 512-byte RAM had **already** been built out of logic before
any of this; using port B doubled the array and therefore doubled the damage,
but did not cause it. The cause is that the CLEAR-clears-VRAM sequencer writes
through port B: two active write ports mean mixed-port read-during-write, which
an M10K cannot honour. The ROM `dpram` and the new `sram2` use the same module
with port B tied off, and both infer cleanly — which is what identified it.

Two fixes, measured separately against a full build each:

| | ALMs | of device | block memory |
|---|---|---|---|
| plane 1 on port B (first attempt) | 18,384 | 44 % | 457,103 |
| plane 1 in its own array | 14,096 | 34 % | 459,151 |
| CLEAR wipe moved to port A | **10,310** | **25 %** | 463,247 |

Timing closed on all three (+0.761, then +0.567 ns worst setup). The last row is
within a few hundred ALMs of the 10,003 recorded before any colour work existed,
which puts the real cost of the CDP1864, CDP1862, CDP1863 and the Visicom in
perspective: a few hundred ALMs between them, against four thousand for one
mis-inferred RAM.

The second fix leaves `rtl/dpram.sv` alone and needs no `ramstyle` attribute: the
wipe drives port A, which is safe because CLEAR is folded into reset, so the CPU
is held in reset for its whole duration and is not driving the bus. Port B is now
tied off entirely, matching the two instances that always worked.

**The general lesson, because the Verilator harness cannot see any of this:**
after changing anything about a memory's ports, check that it still appears in
the `Inferred altsyncram megafunction` list in `output_files/*.map.rpt`. A RAM
that falls into logic still fits, still closes timing, and passes every test in
this repo.

### One number that moved, and did not

The Conic PAL sweep reads **16/28** over the Cartridges directory, against the
14/28 recorded in §8. That is not a regression: stashing this work and re-running
the identical command also gives 16/28, so the two figures are different metrics
rather than a change. The old one was measured by hand and cannot be reproduced
from the note.

`tools/score-conic.sh` now defines it, and it covers all three Conic sets --
Cartridges, Homebrew and the Sarnoff Collection -- so **it prints 22/38**. The
16/28 above is the Cartridges subset of that. Quote the script's number, with the
date.
