#!/usr/bin/env bash
# Matched B3 windows on the server (bench/policy_sanity/matched_b3_design_2026-11-17.md):
# the records-only instrument COHERENCE_POSITION_BINS (an environment variable,
# no config key). A copy of k2lead_server.sh: builds in its own tree
# (~/mw_build), state in ~/mw, binary bin/champsim_mw_<md5>. bin/champsim,
# every trace, every scored run and every live chain are left as they are: the
# runs write only new trees, results/phaseA_b3_mw_<tag>_<suffix>.
#
#   bash ~/mw_server.sh check    # build, guards, frozen copy, Q0, Q0m, K0 (instrument off: QM0), QM1 (no run starts)
#   bash ~/mw_server.sh chain    # detached: the runs listed in ~/mw/RUNS, then QM2 (owner's word)
#   bash ~/mw_server.sh qm1      # amendment 1: QM1 alone again, on the same binary (Q0, Q0m, K0 passed)
#   bash ~/mw_server.sh status | qm2 | stop
#
# QM0 = Q0 + Q0m + K0 with the instrument off, against the F-C binary
# (champsim_fc_a2e88e46): every line equal, no new line. QM1: the Q0m spans
# with COHERENCE_POSITION_BINS=100000: every other line equal to the same
# binary with it off, and the bins inside the measured spans sum to within
# 0.5% (or 10) of LLC COHERENCE DIR RFO GEM5-RULE EVENTS (ROI block). QM2,
# after each run: its log equals its reference (the scored F-C rerun) apart
# from the new lines and the time stamps.
# ~/mw/RUNS, one line a run (written on the laptop from step 1 and the checks):
#   label|reference tree|<workload>_<n>core|reference config|new tree
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "mw_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/mw_build}"
W="${W:-$HOME/mw}"
FCW="${FCW:-$HOME/sync_fc}"                         # the F-C configs (cfg/<label>.json)
REF="${REF:-$S/bin/champsim_fc_a2e88e46}"           # the F-C binary: QM0 compares against it
REF_MD5="${REF_MD5:-a2e88e46788e1f332427567a19bc2f90}"
NEWLINES='B3 POSITION BINS|MEASURED POSITIONS|GEM5-RULE RFO EVENTS BY POSITION'   # what only the instrument prints
BINS="${BINS:-100000}"
PAR="${PAR:-4}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"
PY="${PY:-python3}"
QW="${QW:-1000000}"; QL="${QL:-2000000}"
SUITE="$CB/bench/policy_sanity/check_coherence_exact.sh"
K0TMP="${K0TMP:-/tmp/harshraj_mw_k0}"               # the suites' traces and logs, on / (not the nearly full /home); removed after
K0JOBS="${K0JOBS:-8}"
RUNSF="$W/RUNS"

# Q0m: F-C spans with sync records (label|tree|<workload>_<n>core|F-C config)
Q0M="${Q0M:-barnesstd_force|phaseA_b3_fc_g3_barnesstd4_force|barnes_4core|$FCW/cfg/barnesstd_force.json
ocean4|phaseA_b3_fc_g3_ocean4|ocean_4core|$FCW/cfg/ocean4.json
canneal4|phaseA_b3_fc_g3_canneal4|canneal_4core|$FCW/cfg/canneal4.json}"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_mw() { cat "$W/BIN" 2>/dev/null; }
clean() { sed -E 's/\(Simulation time: [^)]*\)//' "$1"; }
oldlines() { clean "$1" | grep -v -E "$NEWLINES"; }   # a log without the instrument's lines
pfield() { echo "$1" | awk -F'|' -v n="$2" -v f="$3" '$1 == n { print $f }'; }   # table label field
runs() { [ -s "$RUNSF" ] && cut -d'|' -f1 "$RUNSF"; }
rfield() { awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }' "$RUNSF"; }
ref_log() { echo "$S/results/$(rfield "$1" 2)/regime_shared/$(rfield "$1" 3)/lru/run.log"; }
new_dir() { echo "$S/results/$(rfield "$1" 5)/regime_shared/$(rfield "$1" 3)/lru"; }
new_log() { echo "$(new_dir "$1")/run.log"; }
is_done() { grep -q "$DONE_MARKER" "$(new_log "$1")" 2>/dev/null; }
count_done() { local n=0 r; for r in $(runs); do is_done "$r" && n=$((n + 1)); done; echo "$n"; }
nruns() { runs | grep -c .; }

# the traces (core order), warm-up and length of a run, from its log
log_settings() {   # log -> "wu si trace..."
  local f="$1" wu si n tr k
  grep -q "$DONE_MARKER" "$f" 2>/dev/null || { echo "MISSING:$f is not a complete run"; return 1; }
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$f")
  si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$f")
  n=$(awk '/^Number of CPUs:/ { print $4; exit }' "$f")
  tr=$(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$f" | sort -n -k1,1 | awk '{ print $2 }')
  [ -n "$wu" ] && [ -n "$si" ] && [ -n "$n" ] || { echo "MISSING:$f has no lengths"; return 1; }
  [ "$(echo "$tr" | grep -c .)" = "$n" ] || { echo "MISSING:$f lists $(echo "$tr" | grep -c .) traces for $n CPUs"; return 1; }
  for k in $tr; do [ -s "$k" ] || { echo "MISSING:$k"; return 1; }; done
  echo "$wu $si $(echo "$tr" | tr '\n' ' ')"
}

# The bins against the ROI counter (amendment 1) -> one line; exit 1 if it fails.
#   bound: bins starting in the spans - 10 <= counter <= bins overlapping the spans + 10
#   sum:   the bound, and bins starting in the spans within 0.5% or 10 of the counter
bins_ok() {   # log bound|sum
  "$PY" - "$1" "$2" <<'PYEOF'
import re, sys
t = open(sys.argv[1], errors='replace').read()
mode = sys.argv[2]
m = re.search(r'^B3 POSITION BINS: (\d+) instructions$', t, re.M)
if not m:
    sys.exit('no B3 POSITION BINS line')
B = int(m.group(1))
span = {int(c): (int(a), int(b)) for c, a, b in re.findall(r'^CPU (\d+) MEASURED POSITIONS: from (\d+) to (\d+)$', t, re.M)}
tot = inside = over = 0
for c, rest in re.findall(r'^CPU (\d+) GEM5-RULE RFO EVENTS BY POSITION:(.*)$', t, re.M):
    lo, hi = span[int(c)]
    for k, n in (x.split(':') for x in rest.split()):
        k, n = int(k), int(n)
        tot += n
        inside += n if lo <= k * B < hi else 0
        over += n if k * B <= hi and (k + 1) * B > lo else 0
roi = t.find('Region of Interest Statistics')
g = re.search(r'^LLC COHERENCE DIR RFO GEM5-RULE EVENTS:\s+(\d+)$', t[roi:], re.M) if roi >= 0 else None
if not g:
    sys.exit('no ROI gem5-rule counter')
c = int(g.group(1))
bound = inside - 10 <= c <= over + 10
near = abs(inside - c) <= max(10, 0.005 * c)
ok = bound and (near or mode == 'bound')
why = [] if bound else ['NOT within the bound']
if mode == 'sum' and not near:
    why.append('NOT within 0.5% or 10')
print(f'B {B}: bins starting in the spans {inside}, overlapping them {over} (all phases {tot}); the counter {c}'
      + ('' if ok else ' -- ' + '; '.join(why)))
sys.exit(0 if ok else 1)
PYEOF
}

wait_runs() {   # dir total
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) $(grep -l "$DONE_MARKER" "$1"/*.log 2>/dev/null | wc -l) of $2 runs done"
  done
  wait
}

build() {
  mkdir -p "$W"
  alive "$PIDF" && die "the mw chain is running -- 'status'"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/mw_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -x "$REF" ] && [ "$(md5sum < "$REF" | cut -c1-32)" = "$REF_MD5" ] || die "no reference $REF with md5 $REF_MD5"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  [ "$(strings -a "$CB/simulator/bin/champsim" | grep -c 'GEM5-RULE RFO EVENTS BY POSITION')" -gt 0 ] || die "the new binary does not print the position bins"
  echo "== the three policy guards, in that tree"
  local g m
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_mw_$m.tmp" && mv -f "$S/bin/champsim_mw_$m.tmp" "$S/bin/champsim_mw_$m"
  rm -f "$W/Q0_PASSED" "$W/Q0M_PASSED" "$W/K0_PASSED" "$W/QM1_PASSED"
  echo "$S/bin/champsim_mw_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_mw_$m"
}

# Q0 (QM0): canneal_4t (no sync records), 1 M + 2 M, LRU and Hawkeye, both
# regimes, levels 0 and 2, instrument off: every line the F-C binary prints,
# and no SYNC, MUTEX or instrument line.
q0() {
  local B Q="$W/q0" t="" i f pol rg lv c bad=0 n=0
  B=$(bin_mw); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  for i in 1 2 3 4; do
    f="$S/traces/canneal_4t/canneal$i.champsimtrace.xz"; [ -f "$f" ] || f="$S/traces/canneal_4t/canneal$i.champsimtrace"
    [ -f "$f" ] || die "no canneal_4t trace $i for Q0"
    t="$t $f"
  done
  echo "== Q0 (QM0): every line, against $(basename "$REF"), canneal 4c (no sync records), $QW + $QL, instrument off"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$MC" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS nice -n 19 "$REF" --config "$c" --warmup-instructions "$QW" --simulation-instructions "$QL" $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS nice -n 19 "$B" --config "$c" --warmup-instructions "$QW" --simulation-instructions "$QL" $t > "$Q/${pol}_${rg}_${lv}_new.log" 2>&1 ) &
  done; done; done
  echo "   $(date +%T) 16 runs started (8 pairs); waiting"
  wait_runs "$Q" 16
  for f in "$Q"/*_ref.log; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$f" && grep -q "$DONE_MARKER" "${f%_ref.log}_new.log" || { echo "   $(basename "${f%_ref.log}"): did not complete"; bad=$((bad + 1)); continue; }
    if grep -q -E "SYNC|MUTEX|$NEWLINES" "${f%_ref.log}_new.log"; then echo "   $(basename "${f%_ref.log}"): a SYNC, MUTEX or instrument line"; bad=$((bad + 1)); continue; fi
    diff <(clean "$f") <(clean "${f%_ref.log}_new.log") > /dev/null || { echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0 FAILED: $bad of $n pairs differ"; return 1; }
  echo "   Q0 holds: $n of $n pairs print every line the same"
  basename "$B" > "$W/Q0_PASSED"
}

# Q0m (QM0): synchronised traces with their F-C configs, 1 M + 2 M, instrument
# off: every line equal to the F-C binary's, and no instrument line.
q0m() {
  local B Q="$W/q0m" l s wu si tr bad=0 n=0 cfg
  B=$(bin_mw); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0m (QM0): the synchronised traces of $(echo "$Q0M" | cut -d'|' -f1 | tr '\n' ' '), F-C configs, against $(basename "$REF"), $QW + $QL"
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    s=$(log_settings "$S/results/$(pfield "$Q0M" "$l" 2)/regime_shared/$(pfield "$Q0M" "$l" 3)/lru/run.log") || die "Q0m: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    cfg=$(pfield "$Q0M" "$l" 4); [ -s "$cfg" ] || die "Q0m: no config $cfg"
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS nice -n 19 "$REF" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS nice -n 19 "$B" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_new.log" 2>&1 ) &
  done
  wait_runs "$Q" $(( 2 * $(echo "$Q0M" | grep -c '|') ))
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$Q/${l}_ref.log" && grep -q "$DONE_MARKER" "$Q/${l}_new.log" || { echo "   $l: did not complete"; bad=$((bad + 1)); continue; }
    [ "$(grep -c '^SYNC LOCK WORD: request$' "$Q/${l}_new.log")" = 1 ] || { echo "   $l: not an F-C run (no request line)"; bad=$((bad + 1)); continue; }
    if grep -q -E "$NEWLINES" "$Q/${l}_new.log"; then echo "   $l: an instrument line with it off"; bad=$((bad + 1)); continue; fi
    diff <(clean "$Q/${l}_ref.log") <(clean "$Q/${l}_new.log") > /dev/null || { echo "   DIFFERS: $l"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0m FAILED: $bad of $n differ"; return 1; }
  echo "   Q0m holds: $n of $n print every line the same, and no instrument line"
  basename "$B" > "$W/Q0M_PASSED"
}

# K0 (QM0): the exact suite with both binaries, instrument off, then their logs compared
k0() {
  local B K="$W/k0" r f g n=0 bad=0 want
  B=$(bin_mw); [ -x "$B" ] || die "no binary yet"
  [ -f "$SUITE" ] && [ -f "$CB/bench/policy_sanity/coherence_exact_traces.py" ] || die "no exact suite in $CB/bench/policy_sanity"
  rm -rf "$K" "$K0TMP"; mkdir -p "$K" "$K0TMP" || die "cannot create $K0TMP"
  echo "== K0 (QM0): the exact suite, $(basename "$B") and $(basename "$REF") on every case, levels 0 1 2, $K0JOBS at a time each, instrument off"
  ( BIN="$B" LOGDIR="$K0TMP/mw" JOBS="$K0JOBS" env -u COHERENCE_POSITION_BINS nice -n 19 bash "$SUITE" > "$K/suite_mw.txt" 2>&1 ) &
  ( BIN="$REF" LOGDIR="$K0TMP/fc" JOBS="$K0JOBS" env -u COHERENCE_POSITION_BINS nice -n 19 bash "$SUITE" > "$K/suite_fc.txt" 2>&1 ) &
  echo "   $(date +%T) both suites started; waiting"
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) logs written: new $(ls "$K0TMP"/mw/*.log 2>/dev/null | wc -l), F-C $(ls "$K0TMP"/fc/*.log 2>/dev/null | wc -l)"
  done
  wait
  for r in mw fc; do
    mkdir -p "$K/$r"; cp -p "$K0TMP/$r"/*.log "$K/$r/" 2>/dev/null
    echo "   suite, $r: $(grep -c '^ok ' "$K/suite_$r.txt") ok, $(grep -c '^FAIL ' "$K/suite_$r.txt") FAIL; $(tail -1 "$K/suite_$r.txt" | cut -c1-90)"
    grep -q '^PASS:' "$K/suite_$r.txt" || bad=$((bad + 1))
  done
  rm -rf "$K0TMP"
  want=$(grep -c '^ok ' "$K/suite_fc.txt")
  for f in "$K"/fc/*.log; do
    g="$K/mw/$(basename "$f")"; n=$((n + 1))
    [ -f "$g" ] || { echo "   no new-binary log for $(basename "$f")"; bad=$((bad + 1)); continue; }
    diff <(clean "$f" | sed "s#$K0TMP/fc/#DIR/#g") <(clean "$g" | sed "s#$K0TMP/mw/#DIR/#g") > /dev/null || { echo "   DIFFERS: $(basename "$f")"; bad=$((bad + 1)); }
  done
  [ "$n" -gt 0 ] && [ "$n" = "$(ls "$K"/mw/*.log 2>/dev/null | wc -l)" ] || { echo "   log counts differ: F-C $n, new $(ls "$K"/mw/*.log 2>/dev/null | wc -l)"; bad=$((bad + 1)); }
  [ "$bad" = 0 ] || { echo "   K0 FAILED ($bad; $K)"; return 1; }
  echo "   K0 holds: both suites PASS ($want cases x levels each); $n of $n logs equal line for line"
  basename "$B" > "$W/K0_PASSED"
}

# QM1 (amendment 1): the Q0m spans with the instrument on, against the same binary off (Q0m's _new
# logs): at B = $BINS the bound, at B = $QM1_FINE the bound and the 0.5% sum
QM1_FINE="${QM1_FINE:-1000}"
qm1() {
  local B Q="$W/q0m" l s wu si tr bad=0 n=0 cfg why b f mode
  B=$(bin_mw); [ -x "$B" ] || die "no binary yet"
  echo "== QM1 (amendment 1): the Q0m spans with COHERENCE_POSITION_BINS=$BINS (bound) and =$QM1_FINE (bound + 0.5% sum), against $(basename "$B") with it off"
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    [ -f "$Q/${l}_new.log" ] || die "QM1: no Q0m log for $l -- run Q0m first"
    s=$(log_settings "$S/results/$(pfield "$Q0M" "$l" 2)/regime_shared/$(pfield "$Q0M" "$l" 3)/lru/run.log") || die "QM1: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    cfg=$(pfield "$Q0M" "$l" 4)
    for b in "$BINS" "$QM1_FINE"; do
      # shellcheck disable=SC2086
      ( cd "$S" && COHERENCE_POSITION_BINS="$b" nice -n 19 "$B" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_bins$b.log" 2>&1 ) &
    done
  done
  wait
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    for b in "$BINS" "$QM1_FINE"; do
      n=$((n + 1)); f="$Q/${l}_bins$b.log"
      mode=sum; [ "$b" = "$BINS" ] && mode=bound
      grep -q "$DONE_MARKER" "$f" || { echo "   $l, B $b: did not complete"; bad=$((bad + 1)); continue; }
      [ "$(grep -c "^B3 POSITION BINS: $b instructions\$" "$f")" = 1 ] || { echo "   $l, B $b: no single position-bins line"; bad=$((bad + 1)); continue; }
      diff <(oldlines "$Q/${l}_new.log") <(oldlines "$f") > /dev/null || { echo "   DIFFERS apart from the new lines: $l, B $b"; bad=$((bad + 1)); continue; }
      why=$(bins_ok "$f" "$mode" 2>&1) || { echo "   $l: $why"; bad=$((bad + 1)); continue; }
      echo "   $l: every other line equal; $why ($mode holds)"
    done
  done
  [ "$bad" = 0 ] || { echo "   QM1 FAILED: $bad of $n"; return 1; }
  echo "   QM1 holds: $n of $n"
  basename "$B" > "$W/QM1_PASSED"
}

one_run() {   # label
  local r="$1" B s wu si tr log cfg od ref rc
  B=$(bin_mw); log=$(new_log "$r"); cfg=$(rfield "$r" 4); od=$(new_dir "$r"); ref=$(ref_log "$r")
  if is_done "$r"; then echo "$(date '+%F %T') SKIP  $r (complete)"; return 0; fi
  s=$(log_settings "$ref") || { echo "$(date '+%F %T') FAIL  $r -- ${s#MISSING:}"; return 0; }
  [ -s "$cfg" ] || { echo "$(date '+%F %T') FAIL  $r -- no config $cfg"; return 0; }
  read -r wu si tr <<< "$s"
  mkdir -p "$od"
  { echo "binary $B $(md5sum < "$B" | cut -c1-32)"; echo "config $cfg $(md5sum < "$cfg" | cut -c1-32)"; echo "reference $ref"
    echo "COHERENCE_POSITION_BINS $BINS"; echo "warmup $wu simulation $si"; echo "traces $tr"; } > "$od/cmd.txt"
  echo "$(date '+%F %T') START $r ($wu + $si; $(echo $tr | wc -w) traces) -> $(rfield "$r" 5)"
  # shellcheck disable=SC2086
  ( cd "$S" && COHERENCE_POSITION_BINS="$BINS" nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" $tr > "$log" 2>&1 )
  rc=$?
  echo "$(date '+%F %T') END   $r rc=$rc $(grep -c "$DONE_MARKER" "$log") complete"
  qm2_one "$r" > "$od/qm2.txt"
  echo "$(date '+%F %T') QM2   $r: $(cat "$od/qm2.txt")"
}

qm2_one() {   # label -> one line
  local r="$1" log ref why
  log=$(new_log "$r"); ref=$(ref_log "$r")
  grep -q "$DONE_MARKER" "$log" 2>/dev/null || { echo "not complete"; return; }
  diff <(oldlines "$ref") <(oldlines "$log") > /dev/null || { echo "FAILS: differs from $ref apart from the new lines"; return; }
  why=$(bins_ok "$log" bound 2>&1) || { echo "FAILS: $why"; return; }
  echo "holds: every line of the reference; $why"
}

qm2() {
  local r ok=0 bad=0 waiting=0 v
  for r in $(runs); do
    if ! is_done "$r"; then waiting=$((waiting + 1)); continue; fi
    v=$(qm2_one "$r")
    case "$v" in holds*) ok=$((ok + 1)) ;; *) bad=$((bad + 1)); echo "   QM2 FAILS: $r ($v)" ;; esac
  done
  echo "   QM2: $ok hold, $bad fail, $waiting not complete (of $(nruns))"
}

chain_drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') CHAIN START: $(nruns) matched runs, $PAR at a time, $(basename "$(bin_mw)")"
  runs | xargs -P "$PAR" -I{} bash "$SELF" __run {}
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $(nruns) runs complete"
  qm2 | tee "$W/qm2.txt"
  rm -f "$PIDF"
}

passed() { [ -n "$(bin_mw)" ] && [ "$(cat "$W/$1" 2>/dev/null)" = "$(basename "$(bin_mw)")" ]; }

case "${1:-}" in
  check)
    mkdir -p "$W"
    { build && q0 && q0m && k0 && qm1 \
        && echo "CHECK PASSED: $(basename "$(bin_mw)"): Q0, Q0m, K0 (QM0) and QM1 hold. No run was started: 'chain' starts them (owner's word)."; } 2>&1 | tee -p "$W/check_run.log"
    exit "${PIPESTATUS[0]}" ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the mw chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    B=$(bin_mw); [ -x "$B" ] || die "no binary yet -- 'check'"
    for q in Q0_PASSED Q0M_PASSED K0_PASSED QM1_PASSED; do passed "$q" || die "$(basename "$B") has not passed ${q%_PASSED} -- 'check'"; done
    [ -s "$RUNSF" ] || die "no $RUNSF -- scripts/mw_all.sh go uploads it"
    for r in $(runs); do
      s=$(log_settings "$(ref_log "$r")") || die "$r: ${s#MISSING:}"
      grep -q '^SYNC LOCK WORD: request$' "$(ref_log "$r")" || die "$r: the reference is not an F-C run"
      [ -s "$(rfield "$r" 4)" ] || die "$r: no config $(rfield "$r" 4)"
      "$PY" -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get("sync_lock_word") == "request" else 1)' "$(rfield "$r" 4)" \
        || die "$r: $(rfield "$r" 4) is not an F-C config"
      case "$(rfield "$r" 5)" in phaseA_b3_mw_*) ;; *) die "$r: the new tree must be phaseA_b3_mw_*" ;; esac
    done
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      if tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END'; then
        tail -n +$((n0 + 1)) "$LOG" | tail -3; echo "started: the chain has already ended (every run was complete); log $LOG"; exit 0
      fi
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(nruns) runs, $PAR at a time, then QM2; log $LOG" ;;
  qm1)   # amendment 1: QM1 again on the same binary, after Q0, Q0m and K0 (detached by mw_all.sh qm1)
    mkdir -p "$W"
    alive "$PIDF" && die "the mw chain is running -- 'status'"
    for q in Q0_PASSED Q0M_PASSED K0_PASSED; do passed "$q" || die "$(basename "$(bin_mw)") has not passed ${q%_PASSED} -- 'check'"; done
    rm -f "$W/QM1_PASSED"
    { qm1 && echo "CHECK PASSED: $(basename "$(bin_mw)"): Q0, Q0m, K0 (QM0) and QM1 (amendment 1) hold. No run was started: 'chain' starts them (owner's word)."; } 2>&1 | tee -p -a "$W/check_run.log"
    exit "${PIPESTATUS[0]}" ;;
  __chain) chain_drive ;;
  __run) one_run "$2" ;;
  qm2) qm2 ;;
  status)
    pq() { passed "$1" && echo passed || echo 'not passed'; }
    echo "== mw (matched B3 windows): binary $(basename "$(bin_mw)" 2>/dev/null); Q0 $(pq Q0_PASSED); Q0m $(pq Q0M_PASSED); K0 $(pq K0_PASSED); QM1 $(pq QM1_PASSED); runs $(count_done) of $(nruns) complete; chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$W/check_run.log" ] && { echo "   -- check:"; tail -n 4 "$W/check_run.log" | sed 's/^/      /'; }
    [ -f "$W/qm2.txt" ] && sed 's/^/   /' "$W/qm2.txt"
    [ -f "$LOG" ] && tail -n 4 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'mw_server.sh __chain' || die "pid $sid is not a mw_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2
      rm -f "$PIDF"; echo "stopped the mw chain (session $sid)"
    else
      echo "the mw chain is not running"
    fi ;;
  *) echo "usage: $0 check | qm1 | chain | status | qm2 | stop"; exit 1 ;;
esac
