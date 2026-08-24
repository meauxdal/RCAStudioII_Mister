# CLAUDE.md — RCA Studio II for MiSTer

Current engineering reference for this repository. Prefer current RTL and measured behaviour over old comments or assumptions. Do not edit anything under `sys/`; it is MiSTer framework code.

## Current state

The core is preparing for RC1 and supports four related machines:

| Machine | Video | Sound | Notes |
|---|---|---|---|
| Studio II | CDP1861, NTSC mono | discrete beeper | primary target |
| Studio III PAL | CDP1864 | CDP1864 tone | 312-line PAL timing |
| Studio III NTSC | CDP1861 + CDP1862 | CDP1863 | 1861 timing, colour added beside it |
| Visicom COM-100 | CDP1861 + second DMA bitplane | none | separate memory map and fixed four-colour palette |

The CDP1802 implements the instruction set required by the software corpus, interrupts, DMA and machine-cycle timing. Video is DMA-driven; there is no framebuffer scraper. `.bin`/`.rom` and paged `.st2` cartridges work. Studio II RAM mirroring, Studio III colour RAM, Visicom RAM/plane layout, four resident BIOS slots, joystick automapping, numstick input, aspect ratio and integer scaling are implemented.

All functionality that can currently be exercised has passed hardware testing. All four machine modes work, all known titles are compatible, integer scaling works, and HDMI sync is preserved through CLEAR, cartridge/firmware reloads, and machine changes that remain within the same video standard. Remaining RC1 items are verification gaps, hardware-accuracy questions, and incomplete automap coverage rather than known general compatibility failures; see **RC1 known issues / open verification** below.

## Non-negotiable repository rules

- **Never modify `sys/`, including `video_freak.sv`, `video_mixer.sv`, `hps_io.sv`, etc. Fix integration in the top level/core RTL.
- Quartus 17.0.x only.
- After changing RAM ports, verify the memory still infers as block RAM in `output_files/RCAStudioII.map.rpt`.
- When changing video/timing, state the hardware/emulator reference used.
- `bitmap_de` is a simulation/capture signal only. Normal MiSTer output uses raster blanking through `video_mixer`; do not route `bitmap_de` into the framework unless a deliberate border-crop feature is being added.

## Top-level architecture

`RCAStudioII.sv` is the MiSTer `emu` top. `rtl/rcastudioii.sv` contains the CPU, machine memory maps, keypad/controller mapping and machine video selection.

Important live video modules:

- `rtl/pixie/cdp1861.v` — Studio II, Studio III NTSC and Visicom timing/DMA.
- `rtl/pixie/cdp1862.v` — Studio III NTSC colour.
- `rtl/pixie/cdp1863.v` — Studio III NTSC tone and shared divider model for 1864 tone.
- `rtl/pixie/cdp1864.v` — Studio III PAL video/colour timing.
- `rtl/pixie/pixie_video.v` — 1861 wrapper.

Studio II, Studio III NTSC and Visicom all use the same 1861 timing path. Visicom differs in display-enable decode, memory map and colour data, not in raster timing.

## Clock and video path

Internal machine timing:

- `clk_sys` ≈ 7.040229 MHz.
- `ce_pix` divides this by 4, giving the ≈1.760 MHz 1861/CPU pixel-time base used by the core.
- CPU machine cycles are every eight `ce_pix` pulses.

MiSTer output runs from the PLL's `clk_vid` ≈ 42.24 MHz. The source stream is resampled into that domain and presented to `video_mixer` at ≈7.04 MHz (`ce_pix_vid`), repeating each native source pixel 4×. For the 1861 raster this turns the 88-pixel active line into 352 output samples.

Current top-level path:

```text
rcastudioii H/V sync + blanking + RGB
        ↓ resample clk_sys → clk_vid
video_mixer (LINE_LENGTH = 352)
        ↓ VGA_R/G/B, VGA_HS/VS, vga_de, CE_PIXEL
video_freak
        ↓ VGA_DE, VIDEO_ARX/VIDEO_ARY
MiSTer framework
```

`video_mixer` derives the framework-facing raster DE from HBlank/VBlank. The core's `video_de` output is therefore intentionally not connected at the top level.

### Integer scaling fix (2026-08-23)

Scale modes are working on hardware.

Two integration defects were fixed without touching `sys/`:

1. `video_mixer.LINE_LENGTH` is 352, matching 88 active source pixels × 4 resampling.
2. The VS supplied only to `video_freak` is delayed by one `CE_PIXEL`.

The second point matters because the RCA raster begins VBlank on the same source edge that VSync rises. Unmodified `video_freak` counts a DE falling edge and a VS rising edge in the same always block; without separating them, the later `vcpt <= vcpt + 1` overwrites its `vcpt <= 0` reset. Delaying the VS seen by `video_freak` by one output pixel lets it first count the final active line, then latch/reset the vertical measurement cleanly on the following CE.

Do not "fix" this inside `sys/video_freak.sv`.

OSD scale field is intentionally two bits feeding modes 0–3:

```systemverilog
.SCALE({1'b0, status[12:11]})
```

Mode 4 is intentionally not exposed.

## Video geometry

### CDP1861 / NTSC path

- 112 native pixel times per line.
- 262 lines/frame.
- H active begins at native pixel 24, therefore 88 active raster pixels/line.
- Bitmap data is 64 pixels wide inside that raster; it is not the framework DE.
- Vertical blanking wraps around the frame; VSync is near the end of the frame.

The current 1861 DMA timing includes the phase work needed by real software:

- INT/EF timing leads according to AVI1861-derived behaviour.
- CPU honours DMA at instruction boundaries.
- DMA request stays asserted until the required cycles are serviced.
- Fetch/execute parity adaptation can move the request by one machine cycle.
- The line-buffer read window tolerates the observed interrupt-entry phase variation.

### CDP1864 / PAL path

- 112 native pixel times per line.
- 312 lines/frame.
- 192-line display area.
- PAL ↔ NTSC machine changes are genuine timing-standard changes and may break display sync; this is accepted.

## Reset policy and sync preservation

The reset policy is implemented and hardware-tested. CPU/machine reset and video-timing reset are deliberately separate: `reset` restarts machine state, while `video_reset` restarts raster counters and the CPU phase divider only for a hard reset.

| Event | Reset class | Video behaviour |
|---|---|---|
| Initial core/FPGA load | Hard | raster timing restarts |
| `Reset and close OSD` / MiSTer reset | Hard | raster timing restarts |
| Automatic boot firmware load (index 0) or an unknown download | Hard | raster timing restarts |
| Cartridge load (F1 / index 1) | Sync-preserving | raster remains live |
| Manual `Load Firmware` (F2 / index 2) | Sync-preserving | raster remains live |
| `Apply and reset` within the same standard | Sync-preserving | raster remains live |
| PAL ↔ NTSC `Apply and reset` | Hard | timing standard changes; display resync is expected |
| CLEAR (F3, OSD or gamepad Select) | Sync-preserving | raster remains live |

Studio II, Studio III NTSC and Visicom are all NTSC and can therefore switch among one another without dropping HDMI sync. Studio III PAL is the only PAL mode, so entering or leaving it is a hard reset.

During a sync-preserving reset:

- the CPU and machine state reset;
- the display is forced off;
- cartridge/firmware downloads hold reset for the transfer plus the post-download stretch;
- 1861/1864 raster counters keep running;
- `cpu_div` keeps counting so the CPU machine-cycle grid stays phase-coherent with the live raster.

Download type is latched through the post-download hold because `ioctl_index` is meaningful only during the transfer. Apply/reset captures whether the requested machine crosses PAL/NTSC before `machine_active` changes. Hard reset sources always dominate if reset causes overlap.

CLEAR is normal Studio software operation, not merely a developer reset. Its established special case also leaves the Studio III tone generator running; other sync-preserving resets reset the tone state while retaining raster timing.

Hardware testing passes for the exercised CLEAR, cartridge load, manual firmware load and same-standard machine-switch paths. PAL ↔ NTSC transitions intentionally use the hard-reset path.

## Machine selection and BIOSes

The OSD Machine field is staged. `machine_active` changes on **Apply and reset** (with a short boot-follow exception so Main can restore saved configuration during startup). An apply within the current video standard uses the sync-preserving reset path; crossing between PAL and NTSC uses the hard-reset path.

Four BIOS BRAMs are resident:

| Machine | boot file |
|---|---|
| Studio II | `boot0.rom` |
| Studio III PAL | `boot1.rom` |
| Studio III NTSC | `boot2.rom` |
| Visicom | `boot3.rom` |

Studio II BIOSes are normally 2 KB. Studio III/Visicom images may be 4 KB; the BRAMs are 4 KB. Manual `Load Firmware` is index 2 and writes to the currently active machine's BIOS slot. Boot autoload uses index 0 with `ioctl_index[7:6]` selecting the slot.

Do not regress this back to a single 2 KB BIOS buffer.

## Memory maps

### Studio II / Studio III NTSC base behaviour

- `$0000-$07FF` ROM/system+resident games.
- `$0800-$09FF` 512-byte RAM.
- `$0A00-$0BFF` cartridge window.
- `$0C00-$0DFF` RAM mirror unless cartridge ROM is paged there.
- `$0E00-$0FFF` cartridge window.
- undecoded/open bus reads high (`$FF`).

RAM answers where A9=0 and nothing stronger is decoded, which produces the documented mirrors above `$0FFF` as well.

### Studio III

- 4 KB BIOS images can cover the high ROM area.
- colour RAM is in the `$0B00-$0BFF` window (64×3-bit storage mirrored through the page).
- PAL uses CDP1864; NTSC uses 1861+1862+1863.

### Visicom

- `$0000-$0FFF` ROM/cartridge space.
- `$1000-$11FF` 512-byte main RAM; display plane 0 is in its upper half.
- `$1300-$13FF` second 256-byte display plane.
- `$1200-$12FF` empty.
- mirrors repeat according to the reduced decode.

Visicom video reads plane 0 and the byte `$200` above it during the same DMA cycle. The two bits select one of four fixed colours. The top level applies the final RGB palette.

## Cartridge loading

Raw `.bin`/`.rom` images load flat starting at `$0400`.

`.st2` is detected by `RCA2` magic and uses the 256-byte header page table at offsets 64–127. Blocks are written to their declared 256-byte pages. Cartridge page ownership is recorded so pages such as `$0C/$0D` can replace the normal RAM mirror when an image actually supplies ROM there.

Visicom accepts cartridge pages `$08-$0F`; the Studio II/III RAM/colour rules must not be applied to it.

CRC16-CCITT automapping is computed over the exact downloaded file bytes (poly `0x1021`, init `0xFFFF`). `.st2` and `.bin` containers therefore have different CRCs even when their payloads describe the same game; both hashes must be listed when known.

## Joystick / OSD profile system

`Mapping` and `Joystick` are separate OSD fields:

- Auto: core uses `auto_profile` and writes the detected profile back into OSD bits `[5:2]`.
- Manual: user selection in `[5:2]` drives the mapping.

The Joystick row is disabled while Auto is active. The mapping itself does **not** depend on successful OSD writeback; `auto_profile` drives gameplay directly.

`status_set`/`status_in` readback structure has been checked and is correct: the top level replaces only `[5:2]` with `auto_profile`, and `hps_io` snapshots the whole word on the rising edge of `status_set`.

Profiles currently include None, Cross, Space War, Freeway, Bowling, Baseball, Homebrew, Gunfighter, 8-way, Doodle, 2P Homebrew, Clear-only and Paddle.

### Profile coverage

Known profile entries are functional, but the table is not complete: not every game/mode has an automap profile and not all known software is represented in the CRC table. Add hashes only when the exact image and controls are identified. Because CRCs cover exact downloaded bytes, list both `.bin` and `.st2` hashes where both containers are known.

`MAP_CLEAR_ONLY` can be selected by its known CRC entries or by the built-in Addition game. `playerA`/`playerB` key state is event-driven, so stale held-key state across reset remains relevant when diagnosing an unexpected built-in selection.

Do not rewrite the profile table speculatively. Prefer exact game identification and verified controls.

## RC1 known issues / open verification

### Visicom intermittent instability

All dumped Visicom games are playable. Some software can behave unexpectedly if certain keys are pressed at startup, including visual glitches or a hang. Pressing the intended game-start key avoids the problem; CLEAR or `Reset and close OSD` clears observed graphical corruption.

It is not yet known whether this is hardware-accurate behaviour. Do not change timing blindly: a real Visicom or trustworthy hardware trace remains the best reference. Investigate reset/input state, phase/reacquisition and cartridge-start conditions before changing the two-plane renderer, which produces correct gameplay during normal operation.

### Bottom horizontal line on some BIOS/software

A visible line has been observed at the bottom of the picture with the Studio II alternate BIOS and Studio III 4 KB BIOS dumps. It is not present with every BIOS/image.

Treat this as an open hardware-accuracy question. Because it varies with software/BIOS, it may be authored behaviour or a consequence of how that BIOS drives display memory/timing rather than a universal raster bug. Compare against reference emulators and, ideally, real hardware before changing blanking or active geometry.

### Beeper tuning

The Studio II beeper is functional but needs final tuning against real-hardware recordings. It currently begins around 300 Hz and decays immediately; the hardware reference is closer to E♭4 (311.127 Hz), with a subtly delayed and somewhat variable decay profile.

### Analog/direct video

Implemented and expected to work, but not yet verified on real analog hardware.

## Sound

Studio II uses the discrete beeper model, including the approximate NE555 pitch droop described by the hardware documentation.

Studio III NTSC uses the CDP1863 tone generator. Studio III PAL uses the CDP1864-compatible divider path. Visicom has no Studio III tone hardware.

## RC1 workflow

All new work must start from `preserve-sync-soft-resets`, use a separate topic branch, and return through a pull request targeting `preserve-sync-soft-resets`. Do not base RC1 work on `main`, `merge-prep`, or an older reset branch.

The current `releases/RCAStudioII_20260823.rbf` is the branch's tested release build. Replace or rename release artifacts deliberately when cutting RC1; do not treat the date-stamped file as an immutable source of truth.

## Build and regression

Quartus 17.0.x:

```sh
tools/quartus-build.sh
tools/quartus-build.sh map
tools/quartus-build.sh clean
```

After memory changes, check `Inferred altsyncram megafunction` in the map report. A RAM silently falling into logic can cost thousands of ALMs while still simulating correctly.

Useful regressions include:

- `tools/memdecode-test.sh`
- `tools/tone-test.sh`
- `tools/visicom-test.sh`
- `tools/score-21.sh`
- `tools/score-conic.sh`

The Verilator targets live in `verilator/`. If RTL changes appear to have no effect, clean `obj_dir`/`obj_dir_headless`; the Makefile has historically allowed stale generated builds.

## References

Use more than one source when timing is ambiguous.

- RCA/Weisbecker primary documentation in the local reference material.
- MAME `studio2`, `cdp1861`, CDP1864/Visicom implementations.
- Marcel van Tongeren's Emma 02, especially for Studio III and Visicom behaviour.
- Paul Robson's Studio II emulator/homebrew and the vendored comparison harness.
- Andrew Modla's `rca-studio2`.
- Eric Smith's COSMAC VHDL.
- dmadole's AVI1861 hardware replacement, especially for 1861 cycle/phase behaviour.

## Credits / provenance

The original core is by Jason Coombes, with MiSTer integration and early Pixie work by Flandango. Alan Steremberg and Elle Ball carried the later 2026 CPU/DMA/video, machine-support, controller/profile, OSD and hardware-testing work. See `Readme.md` for the user-facing credits.

GPL-2.0-or-later. Eric Smith's GPL-3 reference files under `rtl/reference` / `rtl/cosmac.v` are reference material and are not part of the compiled core.