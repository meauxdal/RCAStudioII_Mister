#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive the RTL sim and the reference C emulator with an identical input
# sequence and diff every captured frame.
#
#   tools/compare-game.sh <cart|-> <frames> <shots> [--press K@F[:H] ...]
#
#   <cart>    path to a .bin, or "-" for the BIOS built-in games
#   <frames>  how long to run
#   <shots>   comma separated frame numbers to compare
#
# Example
#   tools/compare-game.sh "software/carts/Pinball (Europe).bin" 400 120,200,300,400 \
#       --press a1@40:20 --press a2@150:10 --press a5@250:10
#
# The reference renders 32 logical rows; the RTL renders 128 scanlines, so each
# reference row is expanded 4x before diffing.
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The reference emulator is vendored at tools/refemu (MIT, see its README). The
# old location under the git-ignored refs/ is still accepted so an existing
# checkout keeps working, but tools/refemu is the copy that ships with the repo.
REF="$ROOT/tools/refemu/studio2_headless"
[[ -x "$REF" ]] || REF="$ROOT/refs/rca-studio2/studio2-games/studio2/studio2_headless"
RTL="$ROOT/verilator/obj_dir_headless/Vtop"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

[[ -x "$REF" ]] || { echo "error: build the reference: (cd tools/refemu && make headless)" >&2; exit 1; }
[[ -x "$RTL" ]] || { echo "error: build the RTL sim: (cd verilator && make headless)" >&2; exit 1; }

# Optional leading --machine/--bios, consumed before the positionals. They are
# not just forwarded to both sims: the two take them differently, and the row
# expansion below depends on which machine it is.
MACHINE=studio2
BIOS="$ROOT/rom/studio2.rom"
ROWS=4                                  # scanlines per logical row: 4 NTSC, 6 PAL
while [[ ${1:-} == --machine || ${1:-} == --bios ]]; do
    case "$1" in
      --machine) MACHINE="$2"; shift 2 ;;
      --bios)    BIOS="$2";    shift 2 ;;
    esac
done
if [[ "$MACHINE" == visicom ]]; then
    # tools/refemu has no Visicom, so there is nothing to compare against. Say so
    # rather than silently diffing against a Studio II run.
    echo "error: --machine visicom is not supported here -- tools/refemu models the" >&2
    echo "       Studio II and the two Studio IIIs only, so there is no reference" >&2
    echo "       frame to diff against. Run the RTL sim directly instead." >&2
    exit 2
fi
if [[ "$MACHINE" != studio2 ]]; then
    ROWS=6                              # the CDP1864 machines show 32 rows over 192 lines
    if [[ "$BIOS" == "$ROOT/rom/studio2.rom" ]]; then
        echo "error: --machine $MACHINE needs its own --bios (e.g. refs/emma_02/data/StudioIII/studio3_pal.bin)" >&2
        exit 1
    fi
fi
[[ -f "$ROOT/$BIOS" ]] && BIOS="$ROOT/$BIOS"

CART="$1"; FRAMES="$2"; SHOTS="$3"; shift 3
PRESS=( "$@" )

cart_ref=(); cart_rtl=()
if [[ "$CART" != "-" ]]; then
    [[ -f "$ROOT/$CART" ]] && CART="$ROOT/$CART"
    [[ -f "$CART" ]] || { echo "error: cart not found: $CART" >&2; exit 1; }
    cart_ref=( "$CART" ); cart_rtl=( --cart "$CART" )
fi

shot_args=(); IFS=',' read -ra SL <<< "$SHOTS"
for f in "${SL[@]}"; do shot_args+=( --shot "$f" ); done

echo "machine: $MACHINE   (rows shown ${ROWS}x)"
echo "cart   : $([[ "$CART" == "-" ]] && echo '<built-in games>' || basename "$CART")"
echo "input  : ${PRESS[*]:-<none>}"
echo "frames : $FRAMES   compared at: $SHOTS"
echo

# Each emulator prints its captured frames in shot order; split them into per-shot files.
# ${arr[@]+"${arr[@]}"} rather than "${arr[@]}": macOS ships bash 3.2, where an
# empty array expansion under `set -u` is an unbound-variable error, which is
# exactly the "-" (no cartridge, built-in games) case.
ref_opts=( --machine "$MACHINE" )
[[ "$MACHINE" != studio2 ]] && ref_opts+=( --bios "$BIOS" )
"$REF" "${ref_opts[@]}" --frames "$FRAMES" ${PRESS[@]+"${PRESS[@]}"} "${shot_args[@]}" --ascii --quiet --outdir "$TMP" ${cart_ref[@]+"${cart_ref[@]}"} 2>/dev/null \
  | grep -E "^  [.#BGCRMY]+$" | sed 's/^  //' | tr '.' ' ' | awk -v n="$ROWS" '{for(i=0;i<n;i++) print}' > "$TMP/ref.txt"
# the RTL sim defaults to ../rom/studio2.rom, which is relative to verilator/
"$RTL" --machine "$MACHINE" --bios "$BIOS" --frames "$FRAMES" ${PRESS[@]+"${PRESS[@]}"} "${shot_args[@]}" --ascii --outdir "$TMP" --prefix r ${cart_rtl[@]+"${cart_rtl[@]}"} 2>/dev/null \
  | grep -E "^ *[0-9]+ \|" | sed 's/^ *[0-9]* |//; s/|$//' > "$TMP/rtl.txt"

nref=$(wc -l < "$TMP/ref.txt"); nrtl=$(wc -l < "$TMP/rtl.txt")
nshots=${#SL[@]}
lines=$((32*ROWS))
if [[ $nref -ne $((lines*nshots)) || $nrtl -ne $((lines*nshots)) ]]; then
    echo "warning: expected $((lines*nshots)) lines each, got ref=$nref rtl=$nrtl" >&2
fi

fail=0
for i in "${!SL[@]}"; do
    s=$(( i*lines + 1 )); e=$(( (i+1)*lines ))
    sed -n "${s},${e}p" "$TMP/ref.txt" > "$TMP/a"
    sed -n "${s},${e}p" "$TMP/rtl.txt" > "$TMP/b"
    # Any non-blank glyph, not just '#': a CDP1864 frame draws in colour letters.
    lit_a=$(grep -c '[^ ]' "$TMP/a"); lit_b=$(grep -c '[^ ]' "$TMP/b")
    if diff -q "$TMP/a" "$TMP/b" >/dev/null 2>&1; then
        printf "  frame %-6s MATCH      (%s content lines)\n" "${SL[$i]}" "$lit_a"
    else
        d=$(diff "$TMP/a" "$TMP/b" | grep -c '^[<>]')
        printf "  frame %-6s DIFFER     ref=%s rtl=%s content lines, %s diff lines\n" \
               "${SL[$i]}" "$lit_a" "$lit_b" "$d"
        fail=1
    fi
done
exit $fail
