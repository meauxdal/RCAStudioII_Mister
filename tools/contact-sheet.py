#!/usr/bin/env python3
"""
Render the whole software library as a contact sheet: reference emulator beside
the RTL core, one late frame each, with a MATCH/DIFFER verdict per title.

    tools/contact-sheet.py [outdir]

The scores in CLAUDE.md §9 and docs/succession-plan.md are single numbers -- 26/48
Studio II, 16/28 Conic PAL -- which say how many frames agree but not whether the
ones that disagree are broken or merely at a different point in the game. This
turns that into something you can triage by eye.

Both sides are rendered by the code below from each simulator's own --ascii dump,
using one palette, so any visible difference is a real difference and not two
renderers disagreeing. The reference draws 32 logical rows; those are expanded to
the RTL's scanline count (4x on the NTSC machines, 6x on the PAL CDP1864) before
either comparing or drawing, which is what tools/compare-game.sh does too.

The Visicom has no reference emulator, so it appears RTL-only.
"""
import base64, os, struct, subprocess, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF  = os.path.join(ROOT, "tools/refemu/studio2_headless")
RTL  = os.path.join(ROOT, "verilator/obj_dir_headless/Vtop")
CART = os.path.join(ROOT, "software/carts")
ST2  = os.path.join(ROOT, "refs/emma_02/data/St2")
S3P  = os.path.join(ROOT, "refs/emma_02/data/StudioIII/studio3_pal.bin")
VIS  = os.path.join(ROOT, "refs/emma_02/data/Visicom/visicom.rom")

# One palette, both sides. The letters are what each simulator prints.
PAL_STD = {" ": (0,0,0), "#": (255,255,255), "B": (0,0,208), "G": (0,208,0),
           "C": (0,208,208), "R": (208,0,0), "M": (208,0,208), "Y": (208,208,0)}
# The Visicom's four are fixed hardware values, and its G is the dark green
# background rather than a foreground green. These are MAME's VISICOM_PALETTE,
# which a hardware capture backs over Emma 02's -- see the note in RCAStudioII.sv.
PAL_VIS = {" ": (0,0x40,0), "G": (0,0x40,0), "C": (0xAF,0xDF,0xE4),
           "Y": (0xB9,0xC4,0x2F), "R": (0xEF,0x45,0x4A)}


def png(rows, pal, sx=5, sy=1):
    h, w = len(rows), max(len(r) for r in rows)
    raw = bytearray()
    for line in rows:
        line = line.ljust(w)
        for _ in range(sy):
            raw.append(0)
            for ch in line:
                raw += bytes(pal.get(ch, (255, 0, 255))) * sx
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", w*sx, h*sy, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def run(cmd):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return p.stdout
    except Exception as e:
        print("  ! %s" % e, file=sys.stderr)
        return ""


def ref_frame(machine, cart, presses, frames, shot):
    cmd = [REF, "--machine", "studio2" if machine == "studio2" else "mpt02"]
    if machine != "studio2":
        cmd += ["--bios", S3P]
    cmd += ["--frames", str(frames)]
    for p in presses:
        cmd += ["--press", p]
    cmd += ["--shot", str(shot), "--ascii", "--quiet"]
    if cart:
        cmd += [cart]
    out = run(cmd)
    rows = [l[2:].rstrip("\n") for l in out.splitlines()
            if l.startswith("  ") and l[2:].strip("  .#BGCRMY") == "" and len(l) > 60]
    return [r.replace(".", " ") for r in rows]


def rtl_frame(machine, bios, cart, presses, frames, shot):
    cmd = [RTL, "--machine", machine, "--bios", bios, "--frames", str(frames)]
    for p in presses:
        cmd += ["--press", p]
    cmd += ["--shot", str(shot), "--ascii"]
    if cart:
        cmd += ["--cart", cart]
    out = run(cmd)
    rows = []
    for l in out.splitlines():
        s = l.strip()
        if "|" in s and s.split("|")[0].strip().isdigit():
            rows.append(s.split("|", 1)[1].rsplit("|", 1)[0])
    return rows


def expand(rows, n):
    return [r for r in rows for _ in range(n)]


# ---------------------------------------------------------------------------
# The library. Studio II start sequences are the documented ones from the RCA
# manuals, the same list tools/score-21.sh uses. Conic gets a uniform A1, which
# is what tools/score-conic.sh measures. Homebrew keys are from CLAUDE.md §10.
# ---------------------------------------------------------------------------
C = lambda n: os.path.join(CART, n)
H = lambda n: os.path.join(ST2, "StudioII-Homebrew", n)

STUDIO2 = [
    ("Doodle",              None, ["a1@40:20"]),
    ("Patterns",            None, ["a2@40:20"]),
    ("Bowling",             None, ["a3@40:20"]),
    ("Freeway",             None, ["a4@40:20"]),
    ("Addition",            None, ["a5@40:20"]),
    ("Space War",           C("TV Arcade I - Space War (USA).bin"), ["a1@40:20","a2@150:20"]),
    ("Tennis",              C("TV Arcade III - Tennis + Squash (USA).bin"), ["a2@40:15","a5@90:15","b5@140:15"]),
    ("Squash",              C("TV Arcade III - Tennis + Squash (USA).bin"), ["a1@40:15","b5@90:15"]),
    ("Speedway",            C("TV Arcade Series - Speedway + Tag (USA).bin"), ["a1@40:20","a2@150:60"]),
    ("Tag",                 C("TV Arcade Series - Speedway + Tag (USA).bin"), ["a2@40:20","a6@150:60"]),
    ("Gunfighter",          C("TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe).bin"), ["a1@40:20","a5@150:20"]),
    ("Moonship Battle",     C("TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe).bin"), ["a3@40:20","a5@150:20"]),
    ("Baseball",            C("TV Arcade IV - Baseball (USA).bin"), ["a0@40:20","b5@150:20"]),
    ("Blackjack",           C("TV Casino Series - Blackjack (USA).bin"), ["a1@40:20","b5@150:20"]),
    ("Star Wars",           C("Star Wars (Europe).bin"), ["a1@40:20","a2@120:20"]),
    ("Fun with Numbers",    C("TV Arcade II - Fun with Numbers (USA).bin"), ["a1@40:20","b1@150:15","b2@180:15"]),
    ("Biorhythm",           C("TV Mystic Series - Biorhythm (USA, Europe).bin"), ["a0@40:20","b1@120:15","b2@150:15"]),
    ("Pinball",             C("Pinball (Europe).bin"), ["a1@40:20"]),
    ("Speedway + Tag (EU)", C("Speedway + Tag (Europe).bin"), ["a1@40:20","a2@150:60"]),
    ("School House I",      C("TV School House I (USA).bin"), ["a1@40:20"]),
    ("Math Fun",            C("TV School House II - Math Fun (USA, Europe).bin"), ["a1@40:20"]),
    ("TV Bingo",            C("TV Casino Series - TV Bingo (USA, Europe).bin"), ["a1@40:20"]),
    ("Concentration Match", C("Concentration Match (Europe).bin"), ["a1@40:20"]),
    ("Demonstration",       C("Demonstration Cartridge (USA).bin"), ["a1@40:20"]),
]

HOMEBREW = [
    ("Space Invaders", H("invaders.st2"),  ["b0@40:20"]),
    ("Combat",         H("combat.st2"),    ["b0@40:20"]),
    ("Hockey",         H("hockey.st2"),    ["a1@40:15","a8@120:15"]),
    ("Scramble",       H("scramble.st2"),  ["a6@40:20"]),
    ("Berzerk",        H("berzerk.st2"),   ["a1@40:20"]),
    ("Asteroids",      H("asteroids.st2"), ["a1@40:20"]),
    ("Pacman",         H("pacman.st2"),    ["a1@40:20"]),
    ("Race",           H("race.st2"),      ["b2@40:20"]),
]

VISICOM = [
    ("Doodle",   None, ["a1@40:20"]), ("Bowling",  None, ["a2@40:20"]),
    ("Patterns", None, ["a3@40:20"]), ("Freeway",  None, ["a4@40:20"]),
    ("Addition", None, ["a7@40:20"]),
]
for n, t in [("cas-110-arithmetic_drill","Arithmetic Drill"), ("cas-130-sports_fan","Sports Fan"),
             ("cas-140-gambler_i","Gambler I"), ("cas-141-gambler_ii","Gambler II"),
             ("cas-160-space_command","Space Command"), ("cas-190-bagua-blood-horoscope","Bagua Horoscope")]:
    VISICOM.append((t, os.path.join(ST2, "Visicom-Cartridges", n + ".st2"), ["a0@40:20"]))

CONIC = []
for sub in ["Conic_StudioIII-Cartridges", "Conic_StudioIII-Homebrew", "Conic_StudioIII-Sarnoff-Collection"]:
    d = os.path.join(ST2, sub)
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith(".st2"):
                CONIC.append((os.path.splitext(f)[0], os.path.join(d, f), ["a1@40:20"]))


def collect(title, machine, bios, cart, presses, frames, shot, mult, compare):
    if cart and not os.path.exists(cart):
        return None
    rtl = rtl_frame(machine, bios, cart, presses, frames, shot)
    if not rtl:
        return None
    ref = expand(ref_frame(machine, cart, presses, frames, shot), mult) if compare else None
    verdict = None
    if ref:
        verdict = "MATCH" if ref == rtl else "DIFFER"
    return dict(title=title, rtl=rtl, ref=ref, verdict=verdict,
                lit=sum(1 for r in rtl if r.strip()))


SECTIONS = [
    dict(key="studio2",  name="Studio II",         machine="studio2",
         bios=os.path.join(ROOT, "rom/studio2.rom"), pal=PAL_STD, mult=4,
         frames=300, shot=300, compare=True, items=STUDIO2,
         blurb="CDP1861, NTSC, monochrome. Started with the sequences from the RCA "
               "manuals, the same list tools/score-21.sh uses."),
    dict(key="homebrew", name="Studio II homebrew", machine="studio2",
         bios=os.path.join(ROOT, "rom/studio2.rom"), pal=PAL_STD, mult=4,
         frames=400, shot=400, compare=True, items=HOMEBREW,
         blurb="Paul Robson's 2000 builds. Start keys from CLAUDE.md §10 -- these "
               "are the titles whose timing marginality drove the DMA work."),
    dict(key="conic",    name="Studio III PAL",    machine="mpt02",
         bios=S3P, pal=PAL_STD, mult=6,
         frames=300, shot=300, compare=True, items=CONIC,
         blurb="CDP1864: video, colour and tone in one part, 312-line PAL frame over "
               "192 display lines. Uniform A1, which is what tools/score-conic.sh measures."),
    dict(key="visicom",  name="Visicom COM-100",   machine="visicom",
         bios=VIS, pal=PAL_VIS, mult=4,
         frames=250, shot=250, compare=False, items=VISICOM,
         blurb="No reference emulator models this machine, so it is shown RTL-only and "
               "covered by tools/visicom-test.sh instead."),
]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/contact-sheet"
    os.makedirs(out, exist_ok=True)
    results = []
    for sec in SECTIONS:
        print("== %s (%d titles)" % (sec["name"], len(sec["items"])), flush=True)
        rows = []
        for title, cart, presses in sec["items"]:
            r = collect(title, sec["machine"], sec["bios"], cart, presses,
                        sec["frames"], sec["shot"], sec["mult"], sec["compare"])
            if r is None:
                print("   skip %s" % title, flush=True)
                continue
            print("   %-34s %-7s %d lit" % (title, r["verdict"] or "-", r["lit"]), flush=True)
            rows.append(r)
        results.append((sec, rows))

    import json
    payload = []
    for sec, rows in results:
        for r in rows:
            r["rtl_png"] = base64.b64encode(png(r["rtl"], sec["pal"])).decode()
            r["ref_png"] = base64.b64encode(png(r["ref"], sec["pal"])).decode() if r["ref"] else None
            del r["rtl"], r["ref"]
        payload.append(dict(key=sec["key"], name=sec["name"], blurb=sec["blurb"],
                            compare=sec["compare"], rows=rows))
    with open(os.path.join(out, "sheet.json"), "w") as f:
        json.dump(payload, f)
    print("wrote %s/sheet.json" % out)


if __name__ == "__main__":
    main()
