#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The §9 score: every Studio II case, driven with its *documented* start
# sequence (from the RCA manuals, same sequences as tools/play-test.sh), and
# diffed RTL against the reference emulator.
#
#   tools/score-21.sh
#
# There was no script for this before -- the figure in CLAUDE.md §9 was measured
# by hand, which made it awkward to tell whether a change had moved it. Using a
# uniform "press A1" instead is not the same metric: several cartridges never
# start, so their frames agree only because both sides show the same near-empty
# screen.
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CG="$ROOT/tools/compare-game.sh"
C="$ROOT/software/carts"

pass=0; fail=0
score() {   # $1=label  $2=cart-or-"-"  $3=frames  $4=shots  rest=presses
    local label="$1" cart="$2" frames="$3" shots="$4"; shift 4
    local out n tot
    out=$("$CG" "$cart" "$frames" "$shots" "$@" 2>/dev/null | grep -E "frame +[0-9]+ +(MATCH|DIFFER)")
    n=$(printf '%s' "$out" | grep -c MATCH)
    tot=$(printf '%s' "$out" | grep -c .)
    pass=$((pass+n)); fail=$((fail+tot-n))
    printf "  %-44s %s/%s\n" "$label" "$n" "$tot"
}

echo "Built-in games (no cartridge):"
score "Doodle   (A1)"   - 300 150,300 --press a1@40:20
score "Patterns (A2)"   - 300 150,300 --press a2@40:20
score "Bowling  (A3)"   - 300 150,300 --press a3@40:20
score "Freeway  (A4)"   - 300 150,300 --press a4@40:20
score "Addition (A5)"   - 300 150,300 --press a5@40:20

echo "Cartridges, documented start sequences:"
score "Space War (A1, fire A2)"      "$C/TV Arcade I - Space War (USA).bin"                          300 150,300 --press a1@40:20 --press a2@150:20
score "Tennis (A2, size, speed)"     "$C/TV Arcade III - Tennis + Squash (USA).bin"                  300 150,300 --press a2@40:15 --press a5@90:15 --press b5@140:15
score "Squash (A1, size, speed)"     "$C/TV Arcade III - Tennis + Squash (USA).bin"                  300 150,300 --press a1@40:15 --press b5@90:15
score "Speedway (A1)"                "$C/TV Arcade Series - Speedway + Tag (USA).bin"                300 150,300 --press a1@40:20 --press a2@150:60
score "Tag (A2)"                     "$C/TV Arcade Series - Speedway + Tag (USA).bin"                300 150,300 --press a2@40:20 --press a6@150:60
score "Gunfighter (A1, fire 5)"      "$C/TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe).bin" 300 150,300 --press a1@40:20 --press a5@150:20
score "Moonship (A3, fire 5)"        "$C/TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe).bin" 300 150,300 --press a3@40:20 --press a5@150:20
score "Baseball (A0, pitch B5)"      "$C/TV Arcade IV - Baseball (USA).bin"                          300 150,300 --press a0@40:20 --press b5@150:20
score "Blackjack (A1, bet B5)"       "$C/TV Casino Series - Blackjack (USA).bin"                     300 150,300 --press a1@40:20 --press b5@150:20
score "Star Wars (A1, speed A2)"     "$C/Star Wars (Europe).bin"                                     300 150,300 --press a1@40:20 --press a2@120:20
score "Fun with Numbers (A1)"        "$C/TV Arcade II - Fun with Numbers (USA).bin"                  300 150,300 --press a1@40:20 --press b1@150:15 --press b2@180:15
score "Biorhythm (A0, dates on B)"   "$C/TV Mystic Series - Biorhythm (USA, Europe).bin"             300 150,300 --press a0@40:20 --press b1@120:15 --press b2@150:15
score "Pinball (A1)"                 "$C/Pinball (Europe).bin"                                      300 150,300 --press a1@40:20
score "Speedway+Tag Europe (A1)"     "$C/Speedway + Tag (Europe).bin"                               300 150,300 --press a1@40:20 --press a2@150:60
score "School House I (A1)"          "$C/TV School House I (USA).bin"                               300 150,300 --press a1@40:20
score "Math Fun (A1)"                "$C/TV School House II - Math Fun (USA, Europe).bin"            300 150,300 --press a1@40:20
score "TV Bingo (A1)"                "$C/TV Casino Series - TV Bingo (USA, Europe).bin"              300 150,300 --press a1@40:20
score "Concentration Match (A1)"     "$C/Concentration Match (Europe).bin"                           300 150,300 --press a1@40:20
score "Demonstration (A1)"           "$C/Demonstration Cartridge (USA).bin"                          300 150,300 --press a1@40:20

# 86677b and 87201 are deliberately excluded: the reference emulator renders
# full-screen noise for both from the first frame, before any input, so neither
# side is a reference for the other (CLAUDE.md §9).

echo
echo "  frames matching: $pass / $((pass+fail))"
