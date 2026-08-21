#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive every documented start sequence through the RTL sim and report whether
# the game reaches a live screen. Sequences come from the RCA manuals in docs/.
#
#   tools/play-test.sh
#
# BLANK  = nothing drawn.  STATIC = drawn but not moving between two sampled
# frames -- correct for turn-based games waiting on input.  LIVE = animating.
#
# Caveat: LIVE vs STATIC samples two specific frames, so it depends on animation
# phase; the RTL and the reference emulator run at different instruction rates
# (1321 vs ~952 per frame), so a game can be LIVE in one and STATIC in the other
# without either being wrong. Content-row counts are the reliable comparison.
# ---------------------------------------------------------------------------
# Drive each documented start sequence in the RTL sim and report whether the game
# reaches a live screen (content present, and changing between two later frames).
R=/Users/alans/Documents/development/RCAStudioII_Mister
V="$R/verilator/obj_dir_headless/Vtop"
cd "$R/verilator" || exit 1

run() {  # $1=label $2=cart-or-"-"  rest=press args
  local label="$1" cart="$2"; shift 2
  local ca=(); [ "$cart" != "-" ] && ca=( --cart "$R/software/carts/$cart" )
  local a b lit
  a=$(timeout -s KILL 300 "$V" --bios ../rom/studio2.rom "${ca[@]}" --frames 320 "$@" --shot 320 --ascii 2>/dev/null \
        | grep -E "^ *[0-9]+ \|" | sed 's/^ *[0-9]* |//; s/|$//')
  b=$(timeout -s KILL 300 "$V" --bios ../rom/studio2.rom "${ca[@]}" --frames 340 "$@" --shot 340 --ascii 2>/dev/null \
        | grep -E "^ *[0-9]+ \|" | sed 's/^ *[0-9]* |//; s/|$//')
  lit=$(printf '%s' "$a" | grep -c '#')
  if   [ "$lit" -eq 0 ];            then printf "  %-42s BLANK\n" "$label"
  elif [ "$a" != "$b" ];            then printf "  %-42s LIVE      (%s rows, animating)\n" "$label" "$lit"
  else                                   printf "  %-42s STATIC    (%s rows, no motion)\n" "$label" "$lit"
  fi
}

echo "Built-in games (BIOS):"
run "Doodle   (A1)"        -  --press a1@40:20
run "Patterns (A2)"        -  --press a2@40:20
run "Freeway  (A3, B0 go)" -  --press a3@40:20 --press b0@120:20
run "Bowling  (A4, A5 roll)" - --press a4@40:20 --press a5@160:20
run "Addition (A5)"        -  --press a5@40:20

echo "Cartridges:"
run "Space War Horiz (A1, fire A2)"   "TV Arcade I - Space War (USA).bin"                 --press a1@40:20 --press a2@150:20
run "Space War Vert  (A3, fire A3)"   "TV Arcade I - Space War (USA).bin"                 --press a3@40:20 --press a3@150:20
run "Tennis (A2,size,speed)"          "TV Arcade III - Tennis + Squash (USA).bin"         --press a2@40:15 --press a5@90:15 --press b5@140:15 --press a8@190:15
run "Squash (A1,size,speed)"          "TV Arcade III - Tennis + Squash (USA).bin"         --press a1@40:15 --press b5@90:15 --press a8@140:15
run "Speedway (A1)"                   "TV Arcade Series - Speedway + Tag (USA).bin"       --press a1@40:20 --press a2@150:60
run "Tag (A2)"                        "TV Arcade Series - Speedway + Tag (USA).bin"       --press a2@40:20 --press a6@150:60
run "Gunfighter 1P (A1, fire 5)"      "TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe).bin" --press a1@40:20 --press a5@150:20
run "Moonship (A3, fire 5)"           "TV Arcade Series - Gunfighter + Moonship Battle (USA, Europe).bin" --press a3@40:20 --press a5@150:20
run "Baseball (A0, pitch B5)"         "TV Arcade IV - Baseball (USA).bin"                 --press a0@40:20 --press b5@150:20 --press a5@200:10
run "Blackjack 1P (A1, bet B5)"       "TV Casino Series - Blackjack (USA).bin"            --press a1@40:20 --press b5@150:20
run "Star Wars 1P (A1, speed A2)"     "Star Wars (Europe).bin"                            --press a1@40:20 --press a2@120:20 --press a6@200:60
run "Fun w/ Numbers (A1, guess B)"    "TV Arcade II - Fun with Numbers (USA).bin"         --press a1@40:20 --press b1@150:15 --press b2@180:15 --press b3@210:15
run "Biorhythm (A0, dates on B)"      "TV Mystic Series - Biorhythm (USA, Europe).bin"    --press a0@40:20 --press b1@120:15 --press b2@150:15
run "Pinball (A1)"                    "Pinball (Europe).bin"                              --press a1@40:20
