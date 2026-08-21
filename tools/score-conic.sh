#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The Studio III / Conic PAL score: every Conic cartridge, started with A1, and
# diffed RTL against tools/refemu.
#
#   tools/score-conic.sh [--machine mpt02|studio3ntsc] [--bios FILE]
#
# This exists because the figure in docs/succession-plan.md ("14/28") was
# measured by hand and could not be reproduced from the note alone -- re-running
# the obvious uniform-A1 sweep gives 16/28 both before and after unrelated
# changes, so the two numbers are different metrics rather than a regression.
# Whatever this script prints is now the number; quote it with the date.
# ---------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CG="$ROOT/tools/compare-game.sh"

MACHINE=mpt02
BIOS="$ROOT/refs/emma_02/data/StudioIII/studio3_pal.bin"
while [[ ${1:-} == --* ]]; do
    case "$1" in
        --machine) MACHINE="$2"; shift 2 ;;
        --bios)    BIOS="$2";    shift 2 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done
[[ -f "$BIOS" ]] || { echo "error: no BIOS at $BIOS" >&2; exit 1; }

pass=0; tot=0
for d in Conic_StudioIII-Cartridges Conic_StudioIII-Homebrew Conic_StudioIII-Sarnoff-Collection; do
    dir="$ROOT/refs/emma_02/data/St2/$d"
    [[ -d "$dir" ]] || continue
    echo "$d:"
    for f in "$dir"/*.st2; do
        [[ -e "$f" ]] || continue
        out=$("$CG" --machine "$MACHINE" --bios "$BIOS" "$f" 300 150,300 --press a1@40:20 2>/dev/null \
              | grep -E "frame +[0-9]+ +(MATCH|DIFFER)")
        n=$(printf '%s' "$out" | grep -c MATCH)
        t=$(printf '%s' "$out" | grep -c .)
        pass=$((pass+n)); tot=$((tot+t))
        printf "  %-52s %s/%s\n" "$(basename "$f" .st2)" "$n" "$t"
    done
done
echo
echo "  frames matching: $pass / $tot   (machine $MACHINE)"
