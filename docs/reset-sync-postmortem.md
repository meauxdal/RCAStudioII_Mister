# Sync-preserving soft resets: 1.0 postmortem

**Date:** 2026-08-23

**Scope:** cartridge/firmware reloads and machine changes within one video standard

**Decision:** defer the generalized reset work until after the 1.0 MiSTer-devel submission

## Summary

The core already had one deliberately narrow sync-preserving reset: **CLEAR**
resets the CPU and blanks the display while leaving the active Pixie timing and
`cpu_div` running. This is important because CLEAR is part of normal Studio II
game operation, and the implementation had been exercised on hardware and in a
phase-sweep simulation.

We attempted to extend that behavior to two quality-of-life cases:

1. loading another cartridge or firmware image without changing video standard;
2. applying another machine within the same video standard.

Initial boot, explicit Reset-and-close-OSD, and NTSC/PAL crossings were intended
to remain full resets. The resulting hardware builds produced no usable HDMI
sync from startup and did not recover. Two follow-up changes did not restore
video. The experiment has therefore been removed for 1.0, returning the reset
path to the last hardware-working implementation.

This is a scope decision, not a conclusion that generalized sync preservation
is impossible. It is a convenience feature whose present risk and diagnostic
cost exceed its value at the release boundary.

## Known-working baseline

Before this experiment, reset was one top-level signal. CLEAR was the only
exception inside `rtl/rcastudioii.sv`:

- the CPU received the normal reset;
- the CDP1861 and CDP1864 received `reset & ~clear_key`;
- `cpu_div` used the same `reset & ~clear_key`, preserving CPU/video phase;
- CLEAR drove each active video part's display-off input, blanking pixels while
  its raster counters continued to generate HSync and VSync.

All other reset causes—including downloads, Apply-and-reset, initial boot and
video-standard changes—reset the CPU and video timing together. HDMI may
briefly reacquire sync for those uncommon actions. That behavior is acceptable
for 1.0.

## What we tried

### 1. Classify hard and soft reset sources

Commit `b304815` split the top-level reset sources into two classes:

| Event | Intended class |
|---|---|
| Initial boot/boot firmware | Full reset |
| Reset and close OSD | Full reset |
| MiSTer reset button | Full reset |
| NTSC ↔ PAL Apply | Full reset |
| F1 cartridge load | Sync-preserving |
| F2 firmware load | Sync-preserving |
| NTSC ↔ NTSC machine Apply | Sync-preserving |
| CLEAR | Sync-preserving |

Download classification was latched across the post-download reset hold because
`ioctl_index` is only meaningful during the transfer. Apply classification used
PAL membership: machine 1 is PAL; machines 0, 2 and 3 are NTSC.

### 2. Add a separate video-reset input

Commit `37abb34` added `video_reset` to `rcastudioii` while retaining `reset`
for the CPU and general machine state. The video parts and `cpu_div` used
`video_reset`; soft resets blanked the active display while leaving raster
timing alive. The tone generator was reset on non-CLEAR soft resets.

Commit `c6ddf30` then made PAL/NTSC Apply classification effective immediately
on the initiating edge, before `machine_active` changed and obscured the
crossing.

### 3. Initialize the Apply path and synchronize the simulation wrapper

PR #6 initialized the new Apply reset state explicitly and connected the new
`video_reset` port in `verilator/sim.v`. This corrected a real verification gap:
the wrapper had not been updated when the core interface changed. It did not
restore HDMI output on hardware.

### 4. Bound hard video reset duration

PR #7 tested the hypothesis that a hard-reset source was holding both raster
generators at counter zero indefinitely. It changed hard video reset from a
level into a bounded pulse so HSync and VSync would resume even while the CPU
remained held. The hardware result was still broken, so the PR was closed
without merging.

### 5. Restore the baseline

PR #8 removes the generalized hard/soft split, the additional core port and the
wrapper changes. The three affected files return to commit `e2bea5a`, the last
hardware-working state before this experiment, apart from whitespace in one
comment.

## What went wrong

The hardware symptom is established: builds with the generalized reset work
failed to produce HDMI sync from startup and never recovered. The exact RTL
cause is **not established**. In particular, the failed bounded-pulse hypothesis
means we should not record “video reset was stuck high” as the root cause.

The investigation exposed several process and design problems:

- **The change crossed too many responsibilities at once.** `reset` controls
  the CPU, DMA relationship, display enable, colour/audio state, RAM-clearing
  behavior and raster phase. Replacing the proven local CLEAR exception with a
  generalized reset class changed all of those relationships together.
- **The important failure was above the existing simulation boundary.** The
  reset classifier lives in `RCAStudioII.sv`; the Verilator harness instantiates
  `rcastudioii` directly. Core-level tests therefore could not exercise initial
  HPS boot ordering, `ioctl_index`, boot-follow machine selection or the
  top-level hard/soft classification.
- **The wrapper initially drifted from the core interface.** The missing
  `video_reset` connection should have been caught before hardware testing.
- **There was no hardware visibility into the failing signals.** Without a
  SignalTap capture of reset sources, selected machine, raster counters and
  HSync/VSync, follow-up changes were hypotheses rather than measured fixes.
- **The first implementation combined both requested QoL cases.** Cartridge
  reload and machine switching should have been introduced and tested
  separately, beginning with the smaller same-machine cartridge case.

No change under `sys` was made or is required. The failure belongs within the
core's reset integration and should be investigated there when work resumes.

## Why this is deferred for 1.0

The core's emulation features are otherwise complete enough for MiSTer-devel.
The proposed behavior improves transitions between games and closely related
machines, but it does not affect gameplay after a successful load. The existing
behavior is conventional and recoverable: HDMI reacquires after a load or
machine Apply. CLEAR—the reset action software uses routinely—continues to keep
sync alive.

For 1.0, the priority order is therefore:

1. reliable startup and video output;
2. stable gameplay across all four supported machines;
3. a reviewable MiSTer-devel submission based on hardware-proven behavior;
4. deeper transition-quality improvements afterward.

The generalized reset work is explicitly **not a 1.0 blocker**.

## Conditions for revisiting after 1.0

Do not begin by restoring the abandoned patch series. Rebuild the feature from
the known-working baseline with observability and one event class at a time.

1. Add a top-level simulation or directed reset-classifier test that models:
   boot ROM uploads, saved-machine boot-follow, cartridge downloads, firmware
   downloads, Apply, explicit reset and overlapping events.
2. Update every simulation instantiation in the same commit as any core port
   change; make missing pins a fatal lint condition if practical.
3. Add SignalTap probes for the individual reset sources, combined CPU reset,
   video-part reset, `machine_active`, `ioctl_download`, `ioctl_index`,
   `hcount`, `vcount`, HSync and VSync.
4. Implement only same-machine cartridge reload first. Verify startup, CLEAR,
   cartridge reload and repeated reloads on real hardware.
5. Add same-standard machine Apply only after the first case is proven. Test all
   NTSC pairs in both directions and PAL staying PAL.
6. Test NTSC/PAL crossings and explicit reset as regression cases; both must
   remain full resets.
7. Run the full existing simulation battery, then perform cold-boot and repeated
   transition testing over HDMI on the DE10-Nano before merging.

The acceptance condition is not merely that gameplay returns. HSync and VSync
must remain valid throughout each intended soft event, and every full-reset
event must reacquire reliably from a cold core start.
