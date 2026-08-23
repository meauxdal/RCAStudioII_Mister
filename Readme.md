# RCA Studio II for MiSTer

MiSTer FPGA core for the **RCA Studio II** (1977), with support for the Studio III family and Toshiba Visicom COM-100.

![status](https://img.shields.io/badge/status-playable-brightgreen)

## Status

| Machine | Status | Video / sound |
|---|---|---|
| **RCA Studio II** | Playable across known software | CDP1861 monochrome video; discrete beeper |
| **Studio III PAL / MPT-02 family** | Playable across known software | CDP1864 colour video and tone |
| **Studio III NTSC** | Playable across known software | CDP1861 + CDP1862 colour + CDP1863 tone |
| **Toshiba Visicom COM-100** | All dumped games can run correctly; intermittent startup/input instability remains under investigation | CDP1861 timing with Toshiba's two-plane four-colour video |

The CDP1802 implementation includes interrupts, DMA and machine-cycle timing. Cartridge and system ROM, RAM and machine-specific memory maps are decoded separately, including Studio II RAM mirroring, Studio III colour RAM and the Visicom's different RAM layout.

Video output includes aspect-ratio controls and working vertical / horizontal+vertical integer scaling. `CLEAR` resets the machine while keeping Pixie timing running, avoiding unnecessary HDMI resync during normal play.

### Known issues / open verification

- Automatic joystick profiles work and the detected profile is shown in the OSD, but some assignments still need further real-world testing.
- Visicom software can run and play correctly, but some sessions become glitchy after input until the machine/game is reset or reloaded. The exact hardware behaviour is not yet known.
- A line at the bottom of the picture has been observed with some BIOS/software combinations, particularly the Studio III NTSC BIOS. This needs comparison against a reference emulator or real hardware before treating it as a core video defect.
- Analog video output is implemented and has been confirmed to work. Direct video
should work but has not yet been tested at time of writing.

## Features

- RCA Studio II, Studio III PAL, Studio III NTSC and Visicom machine modes.
- `.bin`, `.rom` and paged `.st2` cartridge loading.
- Automatic per-game joystick profiles with Manual override.
- Auto / 1 / 2-player controller routing.
- Direct bindings for every key on both 10-key keypads.
- Jaguar-style analog-stick on-screen keypad (`Stick Keypad`).
- Original/full/custom aspect ratio and integer scaling modes.
- CLEAR on F3, OSD, or gamepad Select while preserving video sync.

## Installing

Copy a release from `releases/` to e.g. `/media/fat/_Console/` on MiSTer.

Firmware is not embedded. Put the BIOS files in `/media/fat/games/RCA-StudioII/` using the standard MiSTer boot slots:

| Machine | Automatic BIOS |
|---|---|
| Studio II | `boot0.rom` |
| Studio III PAL | `boot1.rom` |
| Studio III NTSC | `boot2.rom` |
| Visicom | `boot3.rom` |

All four BIOS slots are resident; changing machine selects the corresponding image. `Load Firmware` writes a `.bin` or `.rom` image into the currently selected machine's slot.

Known working images include:

- Studio II: 2 KB, md5 `B37205BF19B197682F00619D05DA194B` (No-Intro; recommended).
- Studio III PAL: 2 KB, md5 `4CBC2F551D12709BB26D1500284C97C2`.
- Studio III NTSC: 2 KB, md5 `F2EBBF8FA4A2F8509C041B6F07E55C5A`.
- Victory PAL: 4 KB, md5 `5E261010D361A378EAB13F543A96D3C5`.
- Visicom: 2 KB, md5 `AEEC6FE3934481E20EB7DB6D5FF56A54`.

| OSD slot | File | Behaviour |
|---|---|---|
| `Load Cartridge` | `.st2`, `.bin`, `.rom` | `.bin`/`.rom` load flat at `$0400`; `.st2` uses its page table |
| `Load Firmware` | `.bin`, `.rom` | Loads into the active machine's BIOS slot |

## Controls

The Studio II has two 10-key keypads. Keypad A is the left keypad (`EF3`) and keypad B is the right keypad (`EF4`).

```text
   Keypad A (left)        Keypad B (right)
    1  2  3                7  8  9
    Q  W  E                U  I  O
    A  S  D                J  K  L
       X                      ,
```

| Key | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Keypad A** | `1` | `2` | `3` | `Q` | `W` | `E` | `A` | `S` | `D` | `X` |
| **Keypad B** | `7` | `8` | `9` | `U` | `I` | `O` | `J` | `K` | `L` | `,` |

**CLEAR** is **F3**, `Clear` in the OSD, or gamepad Select. The core keeps video timing alive through CLEAR so games that use it as part of normal startup do not force an HDMI resync.

### Joystick profiles

In `Mapping: Auto`, the core computes a CRC16 of the cartridge and chooses a profile. The OSD Joystick row is updated to show the detected profile; in `Manual`, that row becomes editable. Keyboard, on-screen keypad and direct A0-A9/B0-B9 bindings remain active in either mode.

| Profile | Up | Down | Left | Right | Fire | Extra | Start | Typical use |
|---|---|---|---|---|---|---|---|---|
| `CROSS` | `2` | `8` | `4` | `6` | `5` | `0` | `A1` | MPT-02 cross-layout games |
| `SPACEWAR` | — | — | `B4` | `B6` | `A2` | — | `A1` | Space War |
| `FREEWAY` | `A2` | `A8` | `B4` | `B6` | — | — | profile-specific | Freeway-style asymmetric controls |
| `BOWLING` | `A2` | `A8` | — | — | `A5` | — | profile-specific | Bowling |
| `BASEBALL` | `B2` | `B8` | — | — | `A5` / `B5` | — | `A0` | Baseball |
| `HOMEBREW` | `2` | `8` | `4` | `6` | `B0` | — | game-specific | Robson 1P homebrew; diagonals use `1/3/7/9` |
| `HB2P` | `2` | `8` | `4` | `6` | `0` | — | `A1` | Hockey / Combat |
| `GUNFIGHTER` | `B2` | `B8` | `B4` | `B6` | `B5` | `B0` | `A1` | Gunfighter / Moonship Battle |
| `8WAY` | `2` | `8` | `4` | `6` | `5` | `0` | `A1` | General 8-way fallback |
| `DOODLE` | `B2` | `B8` | `B4` | `B6` | `B5` | `B0` | `A1/A2` | BIOS Doodle / Patterns |
| `PADDLE` | `B2` | `B8` | `B4` | `B6` | `B5` | — | `A1` | Tennis / Squash single-player mapping |
| `CLEAR_ONLY` | — | — | — | — | — | — | — | Addition / explicit no-controller cases |
| `NONE` | — | — | — | — | — | — | `A1` | No automatic keypad mapping |

`Players: Auto` uses each profile's natural layout. `1` keeps gameplay on gamepad 0; `2` splits two-sided profiles between the two gamepads.

### On-screen keypad

`Stick Keypad` can place the numstick overlay on keypad A or B.

- Right stick: keys 1-9.
- Left stick: 0.
- Nudge and release the right stick: 5.
- Hold for approximately 0.5 seconds to register a key.

## Building

Quartus **17.0.x** only.

```sh
tools/quartus-build.sh          # full build -> output_files/RCAStudioII.rbf
tools/quartus-build.sh map      # analysis & synthesis only
tools/quartus-build.sh clean
```

Two Verilator targets live in `verilator/`:

```sh
cd verilator
make            # interactive SDL/ImGui
make headless   # batch/regression
```

See `CLAUDE.md` for the detailed hardware references, regression procedures, timing notes and unresolved implementation questions.

## Credits

The original core was created by **Jason Coombes** ([@JasonA-dev](https://github.com/JasonA-dev)), with MiSTer integration and early Pixie work by **Flandango** ([@Flandango](https://github.com/Flandango)). Later 2026 CPU/video/timing work was carried by **Alan Steremberg** ([@alanswx](https://github.com/alanswx)), with controller/profile, OSD and extensive software testing work by **Elle Ball** ([@meauxdal](https://github.com/meauxdal)).

Accuracy work also relies heavily on Paul Robson's Studio II emulator and homebrew, MAME, Marcel van Tongeren's Emma 02, Andrew Modla's `rca-studio2`, Eric Smith's COSMAC VHDL, dmadole's AVI1861, kanpapa's `cosmac_mbc`, RCA documentation and community hardware research.

## Licence

GPL-2.0-or-later; see file headers. `rtl/cosmac.v` and `rtl/reference/cosmac.vhdl` are GPL-3.0 reference code and are not compiled into the core.