# RCA Studio II for MiSTer

MiSTer FPGA core for the **RCA Studio II** (1977), with support for the Studio III family and Toshiba Visicom COM-100.

![status](https://img.shields.io/badge/status-playable-brightgreen)

## Status

- Studio II (monochrome, NTSC) support
- Studio III (color, PAL & NTSC) support (Conic MPT-02 clones)
- Visicom (color, NTSC) support
- 100% compatibility with known titles

### Known issues / open verification

- Visicom software can behave unexpectedly (visual glitches, hanging) when pressing certain keys at game start. It is not currently determined if this is hardware accurate behavior. All Visicom software can be played without issue by pressing an intended game start key while the core is fresly loaded. Unresponsive states can be cleared by reloading the core if needed.
- Beeper frequency needs additional fine tuning. The core currently starts somewhere around 300 Hz (and decays instantly). Tuning a real hardware recording against a digital piano reveals the starting pitch should be closer to Eb4 (311.127 Hz) and the pitch decay profile should be delayed subtly. 
- Direct video should work but has not yet been tested at time of writing.
- Not every game and mode has an automap profile, and not all known software is present in the hash table.

## Features

- RCA Studio II, Studio III PAL, Studio III NTSC and Visicom machine modes.
- Headered `.st2` cartridge support (in addition to flat `bin` / `.rom`)
- Automatic per-game joystick profiles by game hash. Many games can be played with effectively no setup.
- Additional automapping for each game mode in the Studio II firmware.
- Auto / 1 / 2-player controller routing.
- Direct controller bindings for every key on both 10-key keypads.
- Jaguar-style analog-stick on-screen keypad (`Stick Keypad`).
- Integer scaling modes.
- HDMI video sync is preserved on `Clear` and game switches within the same region.

## Installing

Copy a release from `releases/` to e.g. `/media/fat/_Console/` on MiSTer.

Firmware is not embedded. Put the BIOS files in `/media/fat/games/RCA-StudioII/` using the 
standard MiSTer boot slots:

| Machine         | Boot slot / filename | Recommended BIOS image | Size | MD5                                |
| --------------- | -------------------- | ---------------------- | ---: | ---------------------------------- |
| Studio II       | `boot0.rom`          | Studio II              | 2 KB | `B37205BF19B197682F00619D05DA194B` |
| Studio III PAL  | `boot1.rom`          | Victory (PAL)          | 4 KB | `5E261010D361A378EAB13F543A96D3C5` |
| Studio III NTSC | `boot2.rom`          | Studio III (NTSC)      | 2 KB | `F2EBBF8FA4A2F8509C041B6F07E55C5A` |
| Visicom         | `boot3.rom`          | Visicom                | 2 KB | `AEEC6FE3934481E20EB7DB6D5FF56A54` |

`Load Firmware` writes a `.bin` or `.rom` image into the currently selected machine's slot.

## Controls

The Studio II has two 10-key keypads (called Keyboard A and B in official documentation;we use Keypad here instead to avoid confusion with the modern usage of keybooard). Keypad A is the left keypad (`EF3`) and keypad B is the right keypad (`EF4`).

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

The original core is the work of **Jason Coombes** ([@JasonA-dev](https://github.com/JasonA-dev)), whose initial efforts (2022-2025) remain load-bearing elements of the project. MiSTer integration and early Pixie work was done by **Flandango** ([@Flandango](https://github.com/Flandango)). 

Later 2026 CPU/video/timing work was carried by **Alan Steremberg** ([@alanswx](https://github.com/alanswx)), with controller/profile, OSD and extensive software testing work by **Elle Ball** ([@meauxdal](https://github.com/meauxdal)).

Accuracy work also relies heavily on Paul Robson's Studio II emulator and homebrew, MAME, Marcel van Tongeren's Emma 02, Andrew Modla's `rca-studio2`, Eric Smith's COSMAC VHDL, dmadole's AVI1861, kanpapa's `cosmac_mbc`, RCA documentation, and community hardware research.

Special thanks to Kevin Bunch for reference Studio II capture and critical hardware insight. 

Additional thanks to the Hagley Museum and Library.

## Licence

GPL-2.0-or-later; see file headers. `rtl/cosmac.v` and `rtl/reference/cosmac.vhdl` are GPL-3.0 reference code and are not compiled into the core.