# CLAUDE.md — RCA Studio II for MiSTer

Current engineering reference for this repository. Prefer current RTL and measured behaviour over old comments or assumptions. Do not edit anything under `sys/`; it is MiSTer framework code.

## Current state

The core is playable and supports four related machines:

| Machine | Video | Sound | Notes |
|---|---|---|---|
| Studio II | CDP1861, NTSC mono | discrete beeper | primary target |
| Studio III PAL | CDP1864 | CDP1864 tone | 312-line PAL timing |
| Studio III NTSC | CDP1861 + CDP1862 | CDP1863 | 1861 timing, colour added beside it |
| Visicom COM-100 | CDP1861 + second DMA bitplane | none | separate memory map and fixed four-colour palette |

The CDP1802 implements the instruction set required by the software corpus, interrupts, DMA and machine-cycle timing. Video is DMA-driven; there is no framebuffer scraper. `.bin`/`.rom` and paged `.st2` cartridges work. Studio II RAM mirroring, Studio III colour RAM, Visicom RAM/plane layout, four resident BIOS slots, joystick automapping, numstick input, aspect ratio and integer scaling are implemented.

Current hardware testing indicates the four machine modes and known software are broadly playable. Automatic joystick profiles work but still deserve cleanup/verification. Visicom has an unresolved intermittent startup/input issue described below.

## Non-negotiable repository rules

- **Never modify `sys/`, including `video_freak.sv`, `video_mixer.sv`, `hps_io.sv`, etc.** Fix integration in the top level/core RTL.
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

## CLEAR and reset policy

CLEAR is part of normal Studio software operation, not merely a developer reset. Some games effectively begin immediately after CLEAR, so dropping HDMI sync on every CLEAR makes them unpleasant or impossible to use normally.

Current implementation resets the CPU while keeping Pixie timing alive:

- `clear_request` reaches the CPU reset path.
- the 1861/1864 reset inputs exclude CLEAR (`reset & ~clear_key`);
- display is forced off during CLEAR;
- `cpu_div` continues counting through CLEAR so its machine-cycle grid stays phase-coherent with the live raster.

This is shared by Studio II, Studio III NTSC and Visicom because all three use the same 1861 path. The existing DMA parity/reacquisition work is therefore applicable to all three.

The broader sync-preserving reset policy is deferred until after the 1.0
MiSTer-devel submission. The 2026-08-23 attempt caused complete HDMI sync loss
on hardware and was rolled back to the last working implementation. See
`docs/reset-sync-postmortem.md` before revisiting it.

Desired post-1.0 reset policy:

**Full reset**
- initial core/FPGA load;
- PAL ↔ NTSC transition;
- anything that genuinely changes the output timing standard.

**Sync-preserving reset where possible**
- cartridge load;
- Apply and Reset when remaining within the same video standard;
- normal user reset/CLEAR-style restart.

For a sync-preserving reset, stop/reset CPU and machine state and blank the display, but keep raster counters, sync generation and the CPU phase divider running. Hold the machine reset through the cartridge download so code cannot execute while BRAM is being rewritten.

This policy is not implemented for every reset source; do not confuse the
existing CLEAR behaviour with completion of the broader reset-policy work. It
is not a 1.0 blocker.

## Machine selection and BIOSes

The OSD Machine field is staged. `machine_active` changes on **Apply and reset** (with a short boot-follow exception so Main can restore saved configuration during startup).

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

### Profile caveats

Profiles are functional but still somewhat provisional. Hardware testing has shown occasional surprising OSD/profile selections. The readback mechanism itself is not presently the leading suspect.

`MAP_CLEAR_ONLY` can currently be selected by its known CRC entries or by the built-in Addition game. Note that `playerA`/`playerB` key state is event-driven and should be considered when investigating unexpected built-in selection; stale held-key state across reset is a possible source of confusing observations.

Also review the cartridge-download completion logic if profile state appears to survive unrelated ioctl activity: CRC accumulation is cart-gated, but profile update/reset semantics must remain cart-specific.

Do not rewrite the profile table speculatively. Prefer exact game identification and known controls.

## Current unresolved hardware observations

### Visicom intermittent instability

All dumped Visicom games have been observed working correctly and can play perfectly. However, on some starts/sessions a game becomes glitchy after a keypress or otherwise behaves incorrectly until some combination of CLEAR, Reset, cartridge reload or core reload is performed.

Important facts:

- This is intermittent rather than a deterministic incompatibility.
- The same software can run flawlessly once it starts in a good state.
- Current simulation/reference work does not establish what the real Visicom does during reset, cartridge insertion or initial display/CPU phase acquisition.

Do not "fix" this by changing timing blindly. A real Visicom or a trustworthy hardware trace is the best next reference. Investigate reset/input state, phase/reacquisition and cartridge-start conditions before changing the two-plane renderer, since the renderer demonstrably produces correct gameplay in good sessions.

### Bottom horizontal line on some BIOS/software

A visible line has been observed at the bottom of the picture with some BIOS/software combinations, particularly the Studio III NTSC BIOS. It is not present with every BIOS/image.

Treat this as unresolved. Because it varies with software/BIOS, it may be authored behaviour or a consequence of how that BIOS drives display memory/timing rather than a universal raster bug. Compare Studio III NTSC against Paul Robson's emulator / other reference emulators and, ideally, real hardware before changing blanking or active geometry.

### Analog/direct video

Implemented but not yet verified on real analog hardware.

## Sound

Studio II uses the discrete beeper model, including the approximate NE555 pitch droop described by the hardware documentation.

Studio III NTSC uses the CDP1863 tone generator. Studio III PAL uses the CDP1864-compatible divider path. Visicom has no Studio III tone hardware.

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
