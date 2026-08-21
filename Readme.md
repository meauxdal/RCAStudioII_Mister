# RCA Studio II for MiSTer

MiSTer FPGA core for the 2nd generation console **RCA Studio II** (1977). 
Includes full Studio III (MPT-02) and Visicom support.

![status](https://img.shields.io/badge/status-playable-brightgreen)

## Status

### Studio II

* Studio II: 100% software compatibility across known titles.
* CPU: CDP1802 is complete for Studio family software (including interrupts
and DMA) and runs at machine-cycle timing. 
* Video: CDP1861 is complete for Studio family software; no visual issues 
observed. 
* Sound: Beeper implemented; tuned to reference recordings.
* Memory: Proper address bus decoding: ROM, cartridge and the 512 bytes of RAM 
are separate, hardware-accurate RAM mirroring.

### Studio III

* Studio III: 100% software compatibility across known titles.
* Video: CDP1862/CDP1864 color works properly on NTSC / PAL / Visicom; no 
visual issues observed. 
* Audio: CDP1863/CDP1864 audio is implemented; tuned to datasheet specs.

### Visicom COM-100

* Visicom: 100% software compatibility across known titles.
* Video: Bespoke Visicom color implemented; no visual issues observed.

Toshiba's Japanese variant from 1978 has hardware design that notably diverges 
from other Studio III clones. Runs at NTSC timing but lacks the usual CDP1862. 
Color is instead implemented via DMA; two bytes are read per cycle, 512 
apart, and the two top bits pick one of four fixed colours. RAM sits at 
`$1000` rather than `$0800`.

## Features

* Most games will automap an appropriate joystick profile.
* Jaguar-style numstick option.
* Auto/1/2 player mapping options.

## Current limitations

* OSD settings do not save yet.
* Analog and direct video are implemented (88x242 NTSC, 88x292 PAL), but have 
not yet been tested.

## Installing

Copy a release from `releases/` to e.g. `/media/fat/_Console/` on your MiSTer.

Firmware is not embedded. Place the RCA Studio II BIOS in 
`/media/fat/games/RCA-StudioII` (assuming SD  card). Name it `boot.rom` to have 
it load automatically, or load it manually from the OSD. 

Known Studio II BIOS images:  
* **2KB, md5 `B37205BF19B197682F00619D05DA194B` (No-Intro): working, recommended**
* 2KB, md5 `B0010F722FC930D4F7D2F20703C8C80D` (studio2.rom): untested

| OSD slot | File | Loads at |
|----------|------|----------|
| `Load Cartridge` | `.st2`, `.bin`, `.rom` | `.bin`/`.rom` at `$0400`; `.st2` paged by header |
| `Load Firmware` | `.bin`, `.rom` | `$0000` |


The core also accepts Studio III BIOS images. These must currently be explicitly loaded 
via the `Load Firmware` option after switching to Studio III; they aren't automatically
loaded at time of writing.

Known Studio III BIOS images:  
* Studio III 4KB, md5 `849A484AA4B2784ECE5C35C39D9D51A8`: untested
* Studio III (PAL) 2KB, md5 `4CBC2F551D12709BB26D1500284C97C2`: working
* Studio III (NTSC) 2KB, md5 `F2EBBF8FA4A2F8509C041B6F07E55C5A`: working (select `Studio III NTSC`)
* **Victory (PAL) 4KB, md5 `5E261010D361A378EAB13F543A96D3C5`: working, recommended**
* Victory (NTSC) 4KB, md5 `85514FD09950DD8C0CC25238A862C8DC`: not working
* Visicom (NTSC) 2KB, md5 `AEEC6FE3934481E20EB7DB6D5FF56A54`: working (select `Visicom`)

## Controls

The Studio II has two 10-key keypads. In the official documentation, they are referred
to as "Keyboards". "Keypad" is used here to avoid confusion with the usual modern usage.
Keypad A is on the left (read through `EF3`), the right is keypad B (`EF4`); software 
scans them by writing the key number to `OUT 2` and testing the flags. See `docs/keyboard.txt`.

Each keypad is laid out to correspond with the existing jzIntv "[keyhack](https://forums.atariage.com/applications/core/interface/file/attachment.php?id=484005)" 
keypad-to-keyboard mapping. Seemed better to use this than invent a new one.

```
   Keypad A (left)        Keypad B (right)
    1  2  3                7  8  9
    Q  W  E                U  I  O
    A  S  D                J  K  L
       X                      ,
```

The original jzIntv keyhack layout this is based on can be seen here:  
![jzIntv keyhack.txt layout](https://media.invisioncic.com/r322239/monthly_01_2017/post-46336-0-51390500-1483262333_thumb.png).

In table form:

| Key | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Keypad A** | `1` | `2` | `3` | `Q` | `W` | `E` | `A` | `S` | `D` | `X` |
| **Keypad B** | `7` | `8` | `9` | `U` | `I` | `O` | `J` | `K` | `L` | `,` |

**CLEAR** is **F3**, or **Clear** in the OSD. Roughly equivalent to "reset" on other 
consoles. Select on the joystick is always Clear. 

The core attempts to maintain Pixie video timing to avoid television signal dropouts
during Clear events.

### Joystick

By default, keypad controls are dynamically mapped to gamepads per game. The core calculates a CRC16 for each cartridge and selects a profile from `rtl/rcastudioii.sv`. Joystick and keyboard input can be used simultaneously.

#### Profiles

| Profile | Up | Down | Left | Right | Fire | Extra | Start | Select | Default Players | Mapped Games / Use |
|---|---|---|---|---|---|---|---|---|---|---|
| `CROSS` | `2` | `8` | `4` | `6` | `5` | `0` | `A1` / `A2` | `CLEAR` | `2P` | Speedway / Tag, Star Wars, Pinball |
| `SPACEWAR` | — | — | `B4` | `B6` | `A2` | — | `A1` | `CLEAR` | `1P` | TV Arcade I – Space War |
| `FREEWAY` | `A2` | `A8` | `B4` | `B6` | — | — | `A3` | `CLEAR` | `1P` | BIOS Freeway |
| `BOWLING` | `A2` | `A8` | — | — | `A5` | — | `A4` | `CLEAR` | `1P` | BIOS Bowling |
| `BASEBALL` | `B2` | `B8` | — | — | `A5` / `B5` | — | `A0` | `CLEAR` | `2P` | TV Arcade IV – Baseball |
| `HOMEBREW` | `2` | `8` | `4` | `6` | `B0` | — | `A0` / `A5` / `A6` | `CLEAR` | `1P` | Asteroids, Berzerk, Invaders, Kaboom, Pacman, Scramble |
| `HB2P` | `2` | `8` | `4` | `6` | `0` | — | `A1` | `CLEAR` | `2P` | Hockey, Combat |
| `GUNFIGHTER` | `B2` | `B8` | `B4` | `B6` | `B5` | `B0` | `A1` | `CLEAR` | `1P` | TV Arcade Series – Gunfighter / Moonship Battle |
| `8WAY` | `2` | `8` | `4` | `6` | `5` | `0` | `A1` | `CLEAR` | `1P` | Flappy Pixel |
| `DOODLE` | `B2` | `B8` | `B4` | `B6` | `B5` | `B0` | `A1` / `A2` | `CLEAR` | `1P` | BIOS Doodle / Patterns |
| `PADDLE` | `B2` | `B8` | `B4` | `B6` | `B5` | — | `A1` | `CLEAR` | `1P` | TV Arcade III – Tennis / Squash |
| `CLEAR_ONLY` | — | — | — | — | — | — | — | `CLEAR` | n/a | Numerical-input games; BIOS Addition |
| `NONE` | — | — | — | — | — | — | `A1` | `CLEAR` | n/a | No automatic keypad mapping; useful with numstick |

`CROSS` is the standard 2/4/6/8 joystick layout with Fire on `5` and Extra on `0`, matching the official MPT-02 joystick layout and applying to either keypad.

`SPACEWAR`, `FREEWAY`, and `BOWLING` use asymmetric one-player layouts. `BASEBALL` uses A-side controls for batting and B-side controls for pitching/curve.

`HOMEBREW` is Paul Robson's 8-way layout, with Fire on `B0` and diagonal directions on `1`/`3`/`7`/`9`. `HB2P` is the two-player variant, with Fire on `0` on each player's keypad.

`GUNFIGHTER` uses a full directional cross with Fire on `5`; in one-player mode its controls collapse onto keypad B. `8WAY` adds diagonal inputs to `CROSS`. `DOODLE` uses the corresponding full layout on keypad B.

`PADDLE` is single-player and keypad-B-only. For Squash, movement is `B2`/`B8`, with Left/Fire/Right on `B4`/`B5`/`B6`. For two-player Tennis, start with `A2` and use two pads with `Mapping: Manual` and `CROSS`, or use the keyboard.

`CLEAR_ONLY` leaves Select available for `CLEAR` but disables controller-driven keypad presses. Keyboard, on-screen numstick, and direct key bindings remain available.

`NONE` is equivalent to `CLEAR_ONLY` with `A1` assigned to Start. It is useful with the numstick when the game requires only a Start press.

#### Cartridge Assignments

| Cartridge / Game | Profile | Start |
|---|---|---|
| BIOS – Doodle | `DOODLE` | `A1` |
| BIOS – Patterns | `DOODLE` | `A2` |
| BIOS – Bowling | `BOWLING` | `A3` |
| BIOS – Freeway | `FREEWAY` | `A4` |
| BIOS – Addition | `CLEAR_ONLY` | `A5` |
| TV Arcade I – Space War | `SPACEWAR` | `A1` |
| TV Arcade II – Fun with Numbers | `CLEAR_ONLY` | — |
| TV Arcade III – Tennis / Squash | `PADDLE` | `A1` |
| TV Arcade IV – Baseball | `BASEBALL` | `A0` |
| TV Arcade Series – Gunfighter / Moonship Battle | `GUNFIGHTER` | `A1` |
| TV Arcade Series – Speedway / Tag | `CROSS` | `A1` |
| TV Casino Series – Blackjack | `CLEAR_ONLY` | — |
| TV Casino Series – TV Bingo | `CLEAR_ONLY` | — |
| TV Mystic Series – Biorhythm | `CLEAR_ONLY` | — |
| TV School House I | `CLEAR_ONLY` | — |
| TV School House II – Math Fun | `CLEAR_ONLY` | — |
| Star Wars | `CROSS` | `A1` |
| Pinball | `CROSS` | `A1` |
| Concentration Match | `CLEAR_ONLY` | — |
| Demonstration Cartridge | `CLEAR_ONLY` | — |
| Asteroids | `HOMEBREW` | `A5` |
| Berzerk | `HOMEBREW` | `A5` |
| Invaders | `HOMEBREW` | `A0` |
| Kaboom | `HOMEBREW` | `A0` |
| Pacman | `HOMEBREW` | `A0` |
| Scramble | `HOMEBREW` | `A6` |
| Hockey | `HB2P` | `A1` |
| Combat | `HB2P` | `A1` |
| Flappy Pixel | `8WAY` | `A1` |

The built-in BIOS games are identified by the first key pressed after reset. The Demonstration Cartridge autoplays its point-of-sale animation and accepts no input other than `CLEAR`.

#### Mapping: Auto / Manual

`Auto` selects the profile associated with the detected game and updates the OSD Joystick field to show the active profile. The Joystick field is disabled while in Auto.

`Manual` enables the Joystick field and allows any profile to be selected.

#### Start, Select, and Players

`Start` presses the game's assigned Start key. `Select` sends the console's `CLEAR` input.

`Players` determines how a profile uses the two gamepads:

| Setting | Behavior |
|---|---|
| `1` | Gamepad 0 handles all controls |
| `2` | Two-sided profiles split across gamepads; `1P` profiles remain on gamepad 0 |
| `Auto` | Uses the profile's default player layout |

Keyboard input, the on-screen numstick, and direct per-key bindings remain active regardless of the selected profile. A joystick input and keyboard input may act simultaneously.

#### Direct Key Bindings

The button list exposes all 20 keypad keys individually, plus `Select` for `CLEAR` (21 inputs total). Individual keypad keys have no default bindings.

#### On-Screen Keypad

The OSD's `Stick Keypad` setting (`Off`, `Pad A`, `Pad B`) overlays the numstick keypad.

- Right stick: 1–9 keypad grid
- Left stick: `0`
- Nudge and release the right stick: `5`
- Hold the stick for approximately 0.5 seconds to register the key

With `Players: 2`, each player's analog sticks control their respective keypad.

## Building

Quartus **17.0.x** only. If you do not have it installed, the build runs in the
`raetro/quartus:mister` container:

```sh
tools/quartus-build.sh          # full build -> output_files/RCAStudioII.rbf
tools/quartus-build.sh map      # analysis & synthesis only
tools/quartus-build.sh clean
```

Last known-good build: **0 errors**, 10,003 ALMs (24 %), 444 kbit of block RAM (8 %), timing closed with +0.710 ns worst-case slack.

## Simulators

Two Verilator sims live in `verilator/` — an interactive SDL/ImGui one and a
headless one used for regression testing. Both take the same options.

```sh
cd verilator
make            # interactive -> ./obj_dir/Vtop
make headless   # batch       -> ./obj_dir_headless/Vtop

./obj_dir/Vtop --cart "../software/carts/TV Arcade I - Space War (USA).bin" --press a1@40:30
./obj_dir_headless/Vtop --frames 200 --press a5@40:20 --shot 200 --ascii
```

`--press KEY@FRAME[:HOLD]` scripts a keypress; `KEY` is `0`-`9`, optionally
prefixed `a`/`b` to pick the keypad. The headless sim also does PNG capture,
CPU instruction tracing and VRAM dumps — see `--help`.

## Documentation

- `CLAUDE.md` — the working document: hardware reference the RTL must match,
  source layout, build notes, remaining defects, roadmap, and how the core is
  verified against a reference emulator.
- `docs/` — hardware notes (memory map, I/O, video, cartridge format) scraped
  from the classicgaming Studio 2 technical pages, scanned cartridge manuals
  (`*.zip`), and the RCA Model 18V100 service manual, which has the console
  block diagram, the CLEAR button and the clock-adjustment procedure.

## Credits

### Core

- **Jason Coombes** ([@JasonA-dev](https://github.com/JasonA-dev)) — original
  author and by far the largest contributor. Created the core in June 2022 and
  developed it through March 2025: the first CDP1802 and CDP1861 Verilog, the
  keypad, the memory map and the Verilator simulation harness this work builds
  on.
- **Flandango** ([@Flandango](https://github.com/Flandango)) — MiSTer framework
  compatibility and early Pixie video work (September 2022).
- **Alan Steremberg** ([@alanswx](https://github.com/alanswx)) — 1802
  interrupts, DMA and machine-cycle timing; the DMA-driven CDP1861; the
  reference-emulator comparison harness; and the 2026 timing/video work that
  brought the core to its current playable state (August 2026).
- **Elle Ball** ([@meauxdal](https://github.com/meauxdal)) — profile automapping 
  work, hash table refactor, logical 3x4 keypad layout, OSD layout and logic 
  tuning, extensive software testing (August 2026).

### Emulators and hardware references

This core would not be correct without other people's work. In particular:

- **Paul Robson** — his C Studio II emulator (`refs/studio2-games`, 2013) is the
  reference the RTL is checked against frame by frame, and the source of the
  homebrew test software. The ST2 loader and headless harness added for this
  project are extensions of his emulator.
- **Curt Coder** and the **MAME team** — MAME's `cdp1861` device and `studio2`
  driver (BSD-3-Clause). The 1861's scanline windows and, critically, the
  free-running DMA cadence the BIOS interrupt routine synchronises against were
  taken from `cdp1861.cpp`; without it the display could not lock.
- **Marcel van Tongeren** ([Emma 02](https://www.emma02.hobby-site.com/)) — the
  definitive CDP1802 multi-system emulator, used as an independent second
  opinion, and the source of a large `.st2` test corpus.
- **Andrew Modla** ([@ajavamind](https://github.com/ajavamind)) — `rca-studio2`,
  documenting precise CDP1802 DMA timing.
- **Eric Smith** ([@brouhaha](https://github.com/brouhaha)) — his GPL-3 COSMAC
  VHDL 1802 and Pixie implementation, long the reference for a correct 1802.
- **dmadole** — AVI1861, a CPLD drop-in replacement for the 1861, useful as
  cycle-exact hardware truth.
- **kanpapa** — `cosmac_mbc`, a COSMAC MicroBoard with Pixie video.
- The **classicgaming Studio 2 technical pages** (via the Internet Archive), the
  source of everything in `docs/`.
- **Kevin Bunch** — invaluable insights, documentation, rare archives, 
  authorship attributions.

## Licence

GPL-2.0-or-later; see the file headers. Note `rtl/cosmac.v` and
`rtl/reference/cosmac.vhdl` are Eric Smith's GPL-3.0 code — compatible with
"GPL-2-or-later", but any release containing them is effectively GPL-3. They are
reference only and are not compiled into the core.
