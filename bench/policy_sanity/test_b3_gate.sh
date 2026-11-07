#!/usr/bin/env bash
# Tests of the rule that starts the A5 rerun (scripts/b3_score.py gate), on
# rows made from the committed step-1 rows. The gate runs unattended on the
# server, so each way it must refuse is injected here and must be refused.
#
#   bench/policy_sanity/test_b3_gate.sh        # seconds
#
# The base case copies every b3_v3 row to b3_v4, b3_v5 and b3_v4l0 with the
# level each should carry and the B3 v4 counters at 0. That is what a correct
# run looks like if levels 1 and 2 changed nothing, and the gate must pass it
# (ocean and canneal are in the band at step 1; barnes is not, and does not
# gate). Every injection then changes one thing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PS="$ROOT/bench/policy_sanity"
PA="$PS/phasea_rows_v15.txt"; B3="$PS/b3_rows_v6.txt"; G5="$PS/gem5_b3_rows_v1.txt"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0

# base rows: v3 kept, plus v4 / v5 / v4l0 copies
awk '$1 ~ /^phaseA_b3_v3_/ { print; for (g = 1; g <= 3; g++) { split("v4 v5 v4l0", n, " "); if (n[g] == "v4l0" && $1 !~ /_(canneal4|barnes4)$/) continue
       r = $0; sub(/_b3_v3_/, "_b3_" n[g] "_", r); print r } }' "$PA" > "$W/pa"
awk '$1 ~ /^phaseA_b3_v3_/ { print; for (g = 1; g <= 3; g++) { split("v4 v5 v4l0", n, " "); split("1 2 0", l, " "); if (n[g] == "v4l0" && $1 !~ /_(canneal4|barnes4)$/) continue
       r = $0; sub(/_b3_v3_/, "_b3_" n[g] "_", r); print r, l[g], 0, 0, 0, 0, 0, 0 } }' "$B3" > "$W/b3"

# $1 name  $2 expected exit  $3 awk program for the phasea rows  $4 awk program for the b3 rows  [$5 text the output must contain]
t() {
  local name="$1" want="$2" out rc
  awk "${3:-1}" "$W/pa" > "$W/pa.t"; awk "${4:-1}" "$W/b3" > "$W/b3.t"
  out=$(python3 "$ROOT/scripts/b3_score.py" gate "$W/pa.t" "$W/b3.t" "$G5" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && { [ -z "${5:-}" ] || echo "$out" | grep -q -- "$5"; }; then printf 'ok    %s\n' "$name"
  else printf 'FAIL  %s: exit %s, wanted %s%s\n' "$name" "$rc" "$want" "${5:+ and \"$5\"}"; echo "$out" | sed 's/^/        /'; fail=1; fi
}
V5S='$1 == "phaseA_b3_v5_canneal4" && $5 == "shared"'
t "a correct run passes"                     0 1 1 'GATE: PASS'
t "barnes out of the band does not gate"     0 1 1 'barnes 2 MB .*OUT OF THE BAND.*does not gate'
t "level-2 upgrades and invalidations pass"  0 1 "$V5S { \$20 = 500; \$21 = 600; \$22 = 400; \$23 = 900; \$24 = 7 } 1" 'GATE: PASS'
t "a level-2 row that ran at level 1"        1 1 "$V5S { \$19 = 1 } 1" 'level 1, expected 2'
t "a row from a binary without the level"    1 1 "$V5S { \$19 = \"-\" } 1" 'expected 2'
t "a missing level-2 row"                    1 "!($V5S)" "!($V5S)" 'no row for phaseA_b3_v5_canneal4 shared'
t "an incomplete run"                        1 "$V5S { \$6 = \"INCOMPLETE\" } 1" 1 'incomplete'
t "a wrapped trace"                          1 "$V5S { \$8 = \"LOOPED\" } 1" 1 'a trace wrapped'
t "a self-check mismatch"                    1 1 "$V5S { \$17 = 3 } 1" 'self-check 3'
t "a stale-holder violation"                 1 1 "$V5S { \$25 = 1 } 1" 'stale-holders 1'
t "11 private caches registered"             1 1 "$V5S { \$16 = 11 } 1" 'registered 11'
t "canneal out of the band at level 2"       1 1 "$V5S { \$14 = \$14 * 3 } 1" 'R_b: canneal 2 MB'
t "ocean out of the band at level 2"         1 1 '$1 == "phaseA_b3_v5_ocean4_scaled" && $5 == "shared" { $14 = int($14 / 4) } 1' 'R_b: ocean 8 MB'
t "Q1: a private row's cycles moved"         1 '$1 == "phaseA_b3_v5_ocean4" && $5 == "private" { $9 = $9 + 1; $10 = $10 + 1 } 1' 1 'Q1: v5 against v3'
t "Q1: an invalidation in the private regime" 1 1 '$1 == "phaseA_b3_v4_barnes4" && $5 == "private" { $23 = 1 } 1' 'Q1: v4 against v3'
t "Q0: the control's LLC RFO count moved"    1 '$1 == "phaseA_b3_v4l0_canneal4" && $5 == "shared" { $18 = $18 + 1; $12 = $12 - 1 } 1' 1 'Q0: v4l0 against v3'
t "Q0: an upgrade at level 0"                1 1 '$1 == "phaseA_b3_v4l0_barnes4" && $5 == "shared" { $20 = 1 } 1' 'Q0: v4l0 against v3'
t "the shared regime with no aliased fills"  1 "$V5S { \$22 = 0 } 1" 1 'aliased fills 0'
[ "$fail" = 0 ] && echo "PASS: the gate passes a correct run and refuses each injected fault." || { echo "FAILED."; exit 1; }
