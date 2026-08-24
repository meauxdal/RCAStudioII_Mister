# Analog video: what is emitted, what is unverified, how to test it

Status as of 2026-08-19: **the core emits a full analog raster with correct
timings, and nobody has ever seen it on a display.** Everything below the
"Verified" line is checked against the datasheet and the simulator; everything
below "Unverified" needs a MiSTer with an analog IO board and ten minutes.

This is the one part of the core where the Verilator harness cannot help at all.
It captures `bitmap_de` — the 64×128 / 64×192 bitmap alone — precisely so the
recorded scores keep their meaning across raster changes. So the raster is
outside every test in the repo, by design.

---

## 1. What the hardware does, and why it matters

The CDP1861/1864 emit a **full-size TV raster with a small bitmap inside it**.
The border is not blanking — it is active video painted in the background
colour. Nothing scales anything:

- **Vertically**, software shows each logical row over several scanlines by
  rewinding `R(0)` — 4 lines a row on the NTSC 1861, 6 on the PAL 1864. That is
  what the BIOS ISR's repeated `DEC R0` / `PLO R0` is doing, and why 32 rows
  becomes 128 or 192 lines.
- **Horizontally**, pixels are simply *wide*: one per CPU clock, 568 ns each, so
  64 of them span 36.4 µs of a ~51 µs active line.
- **The rest of the raster is background colour.**

Sources: CDP1864 datasheet Fig. 4 (the `BACKGROUND` region around the
`DISPLAY AREA`), Fig. 6 (13.14 µs of horizontal blanking in a 64 µs line), and
MAME's `cdp1861.h` (`HBLANK_END = 12` of `SCREEN_WIDTH = 112`;
`SCANLINE_VBLANK_END = 16` of 262). The photographs of real Studio III output in
`docs/rca-technical/` show it too: picture in the middle, wide border, border in
the background colour.

The original defect was that we blanked everything outside the bitmap, so the
active area was 64×128 in a 112×262 frame. A display that locked to the sync
would have had almost nothing to draw. That is fixed (§8 of
`docs/succession-plan.md` has the diagnosis).

---

## 2. Verified: what the core emits today

Constants live in `rtl/pixie/cdp1861.v` and `rtl/pixie/cdp1864.v`. Both parts run
a 112-pixel line at the 1.76 MHz pixel clock (568 ns/pixel, 63.6 µs/line).

| | CDP1861 (NTSC) | CDP1864 (PAL) |
|---|---|---|
| line | 112 px | 112 px |
| frame | 262 lines | 312 lines |
| front porch | `0..8` = 4.54 µs | `0..8` = 4.54 µs |
| HSync | `8..16` = 4.54 µs | `8..16` = 4.54 µs |
| back porch | `16..24` = 4.54 µs | `16..24` = 4.54 µs |
| active | `24..112` = 49.99 µs | `24..112` = 49.99 µs |
| VSync | lines `254..258` (4 lines) | lines `0..4` (4 lines) |
| VBlank | 20 lines, wrapping `254..262`+`0..12` | 20 lines, `0..20` |
| line rate | 15.72 kHz | 15.72 kHz |
| frame rate | 59.99 Hz | 50.37 Hz |
| bitmap | `40..104` × lines `80..208` | `40..104` × lines `76..268` |
| **raster** | **88 × 242** | **88 × 292** |

Against datasheet Fig. 6 (PAL): front porch 3.14 µs, HSync 4.57, back porch 3.43,
active 50.86. Ours is within half a microsecond on sync and active; the porches
are evenly split where the real part is asymmetric.

Border colour: the **background colour** on the 1864 (Fig. 4's `BACKGROUND`
region, which is what makes the picture fill a TV) and black on the mono 1861.
The Visicom's border is its colour 0, a dark green.

### The one known deviation

**The picture is not horizontally centred**: 16 px of border on the left against
8 on the right. The bitmap is pinned at `40..104` because the BIOS ISR counts
cycles against the DMA burst, and moving the bitmap means moving the DMA phase.
Do not "fix" this without reading §10 of `CLAUDE.md` (2026-08-15 and 2026-08-16)
— the DMA phase is the most load-bearing timing in the core and two separate
classes of bug have already come out of it.

If centring is wanted, the safe change is to shift `H_ACTIVE_START`, `HSYNC_*`
and the porches *around* the fixed bitmap, not to move the bitmap.

---

## 3. Unverified: everything past this point

Nobody has run this on an analog display. What follows is what to do and what to
expect, not a report.

### How the signal gets out

`Studio-II.sv` wires:

```
CLK_VIDEO  = clk_sys                (7.04 MHz)
CE_PIXEL   <- video_mixer           (ce_pix = clk_sys/4 = 1.76 MHz)
video_mixer #(.LINE_LENGTH(140), .GAMMA(1))  scandoubler = forced_scandoubler
video_freak                          aspect ratio + integer scaling
VGA_SCALER  = 0
VGA_SL      = 0
VGA_DISABLE = 0
```

So the analog path is: core → `video_mixer` (optionally scandoubled) →
`video_freak` → `VGA_*`. `VGA_SCALER = 0` means analog gets the core's own
timings rather than the HDMI scaler's output.

Both machines run off the same 1.76 MHz pixel clock and the same 112-pixel line,
so the **line rate is 15.72 kHz on both**; only the frame count differs — 262
lines for **59.99 Hz** (NTSC) and 312 for **50.37 Hz** (PAL). That is a TV rate,
not a VGA-monitor rate. So:

| Display | What is needed |
|---|---|
| CRT TV / RGB SCART / component | Native 15 kHz. Analog IO board, `forced_scandoubler` **off**. This is the case the raster work was for. |
| VGA monitor | 31 kHz. Set `forced_scandoubler=1` in `MiSTer.ini`, or press the OSD's scandoubler toggle. `video_mixer` doubles it. |
| HDMI | Unaffected — `video_freak` scales whatever it is given, which is why HDMI has always looked right. |
| Direct Video | `direct_video=1` in `MiSTer.ini`. HDMI then carries the raw analog-timed signal for an external converter. The core needs nothing special beyond a valid raster. |

### Test procedure

1. Build: `tools/quartus-build.sh` → `output_files/Studio-II.rbf`. Copy to
   `/media/fat/_Console/`.
2. Fit an **analog IO board**. Without one the VGA connector is not driven.
3. Start with a CRT/SCART and `forced_scandoubler=0` in `MiSTer.ini`. Load the
   BIOS from the OSD (the core is held in reset until you do — §6.3).
4. Expected: a stable, centred-ish picture with a wide border. On Studio II the
   border is black; on Studio III PAL it is whatever background colour the
   program selected; on Visicom it is dark green.
5. Then repeat with `forced_scandoubler=1` on a VGA monitor.
6. Then `direct_video=1` on HDMI with a converter.

### If it does not lock — read these in order

| Symptom | Look at |
|---|---|
| No sync at all, black screen | Is the analog IO board fitted? Is `VGA_DISABLE` still 0? Does HDMI work (proves the core is running)? |
| Rolls vertically | VSync width or position. Both are inside blanking and correct on paper: NTSC blanks 20 lines wrapping `254..262` + `0..12` with VSync at `254..258`, PAL blanks `0..20` with VSync at `0..4`. So suspect the *width* first — 4 lines each, where NTSC broadcast wants 3 equalising + 3 serration + 3 equalising. A display that wants proper serrated vertical sync will roll on a plain 4-line pulse. The framework can synthesise composite sync for you — `module csync` lives in `sys/sys_top.v` (~line 1914) and is instantiated for both VGA and HDMI; it is enabled by the **`composite_sync=1`** option in `MiSTer.ini`, not by anything in this core. Try that before editing any timing. |
| Tears / no horizontal lock | HSync width and porch split. Ours are an even 4.54/4.54/4.54; Fig 6 wants 3.14/4.57/3.43. Try matching Fig 6 exactly. |
| Locks but the picture sits far off-centre | Expected to a degree — see "the one known deviation". Adjust the porches, never the bitmap. |
| Picture but wrong colours | That is not analog-specific; check the machine selection in the OSD first. |
| Only works with the scandoubler on | The display probably cannot do 15 kHz. That is a display limit, not a core bug. |

### What to change, and where

Everything is in the two `localparam` blocks at the top of
`rtl/pixie/cdp1861.v` and `rtl/pixie/cdp1864.v`. Changing them **cannot** move
any recorded score, because the harness captures `bitmap_de` rather than the
raster — that separation exists exactly so raster work is safe. After any change:

```sh
cd verilator && make lint && rm -rf obj_dir_headless && make headless
cd .. && tools/score-21.sh          # expect 26/48, unchanged
tools/visicom-test.sh               # expect all ok
```

If a raster change *does* move `score-21.sh`, you have moved the bitmap or the
DMA phase by accident. Revert and reconsider.

---

## 4. Recording the result

Whoever runs this: put the outcome in `CLAUDE.md` §10 with the date, the display
type, and the `MiSTer.ini` settings used. "Analog video does not work yet" is in
the Readme's limitations and should be edited to say what actually happens, not
deleted.
