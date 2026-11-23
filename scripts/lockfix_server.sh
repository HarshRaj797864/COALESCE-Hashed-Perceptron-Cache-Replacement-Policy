#!/usr/bin/env bash
# F-C on the server (bench/policy_sanity/lock_fix_design_2026-11-12.md): a
# contended mutex waiter issues one ownership request for the lock word
# (sync_lock_word request). A copy of lockwait_server.sh: builds in its own tree
# (~/sync_fc_build), state in ~/sync_fc, binary bin/champsim_fc_<md5>.
# bin/champsim, every trace, every scored run and every live chain are left as
# they are: the reruns write only new trees, results/phaseA_b3_fc_<old tree
# without phaseA_b3_>.
#
#   bash ~/lockfix_server.sh check    # ChampSim, guards, frozen copy, Q0, Q0m, Q0r, then K0 (no rerun starts)
#   bash ~/lockfix_server.sh build    # the same without K0
#   bash ~/lockfix_server.sh k0       # K0 alone, on the frozen binary
#   bash ~/lockfix_server.sh chain    # detached: the lock-wait set's 14 spans with request, then Q3 (owner's word)
#   bash ~/lockfix_server.sh status | q3 | stop
#
# Q0 and Q0m (the setting absent): every line equal to the lock-wait binary's
# (champsim_lc_c601b4e4) -- on canneal_4t without sync records, and on the
# synchronised traces of barnes std force, ocean 4 and canneal 4 with their
# configs (amendment 2: canneal 4 added, so Q0m covers K0's real traces).
# K0 (amendment 2: on the server, not the laptop): the exact suite
# (bench/policy_sanity/check_coherence_exact.sh, uploaded to ~/sync_fc_build)
# with the new binary on every case at levels 0, 1, 2 -- PASS -- and with the
# lock-wait binary on the cases it can run (all but the three _req ones) --
# PASS -- and those runs' logs equal line for line between the two binaries.
# Q0r: the same two synchronised spans with request, 1 M + 2 M: complete, the
# request line, one request line per core line, unexplained view-order
# violations 0 (decides only whether the chain starts; nothing is scored).
# Each rerun is its scored run again with one change: its config is the scored
# run's config plus "sync_lock_word": "request" (checked: no other key
# differs). The traces and lengths come from the scored run's own log ("CPU n
# runs", "Warmup Instructions", "Simulation Instructions"). Q3 after the chain:
# every rerun complete, with the request line and 0 unexplained violations.
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "lockfix_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/sync_fc_build}"
W="${W:-$HOME/sync_fc}"
REF="${REF:-$S/bin/champsim_lc_c601b4e4}"       # the lock-wait binary: Q0 and Q0m compare against it
REF_MD5="${REF_MD5:-c601b4e4b75e18c01f70242287a212c1}"
NEWLINES='LOCK.WORD'                            # what only a request run prints (SYNC LOCK WORD, LOCK-WORD REQUESTS)
PAR="${PAR:-14}"                                 # reruns at once
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"

# label | scored tree | <workload>_<n>core | the config its chain ran
SPANS="${SPANS:-fluidanimate|phaseA_b3_h2_fluidanimate4|fluidanimate_4core|$HOME/sync_h2/cfg/fluidanimate4_shared_lru.json
vips|phaseA_b3_h2_vips4|vips_4core|$HOME/sync_h2/cfg/vips4_shared_lru.json
oceannc|phaseA_b3_h2_oceannc4|oceannc_4core|$HOME/sync_h2/cfg/oceannc4_shared_lru.json
bodytrack|phaseA_b3_h2_bodytrack4|bodytrack_4core|$HOME/sync_h2/cfg/bodytrack4_shared_lru.json
barnesstd_window|phaseA_b3_g3_barnesstd4|barnes_4core|$HOME/sync_g6/cfg/barnesstd4_shared_lru.json
barnesstd_start|phaseA_b3_g3_barnesstd4_start|barnes_4core|$HOME/sync_g6/cfg/barnesstd4_start_shared_lru.json
barnesstd_force|phaseA_b3_g3_barnesstd4_force|barnes_4core|$HOME/sync_g6/cfg/barnesstd4_force_shared_lru.json
barnes256|phaseA_b3_g3_barnes4|barnes_4core|$HOME/sync_g6/cfg/barnes4_shared_lru.json
ocean4|phaseA_b3_g3_ocean4|ocean_4core|$HOME/sync_g6/cfg/ocean4_shared_lru.json
canneal4|phaseA_b3_g3_canneal4|canneal_4core|$HOME/sync_g6/cfg/canneal4_shared_lru.json
canneal8|phaseA_b3_g3_canneal8|canneal_8core|$HOME/sync_g6/cfg/canneal8_shared_lru.json
radix|phaseA_b3_g3_radix4|radix_4core|$HOME/sync_g6/cfg/radix4_shared_lru.json
fmm|phaseA_b3_g3_fmm4|fmm_4core|$HOME/sync_g6/cfg/fmm4_shared_lru.json
lunc|phaseA_b3_n2_lunc4|lunc_4core|$HOME/sync_nb/cfg/lunc4_shared_lru.json}"
NSPANS=$(echo "$SPANS" | grep -c '|')
Q0M_SPANS="${Q0M_SPANS:-barnesstd_force ocean4 canneal4}"   # Q0m and Q0r: lock-heavy and barrier-driven synchronised traces
PY="${PY:-python3}"
QW="${QW:-1000000}"; QL="${QL:-2000000}"            # Q0, Q0m, Q0r: warm-up and length (a rehearsal on short stand-in traces sets less)
SUITE="$CB/bench/policy_sanity/check_coherence_exact.sh"
K0TMP="${K0TMP:-/tmp/harshraj_fc_k0}"               # K0's traces (~20 GB a suite) on /, not on the nearly full /home; removed after
K0JOBS="${K0JOBS:-8}"                               # runs at once, per suite (two suites run side by side)
# the cases the lock-wait binary runs too: every case but the three replayed with sync_lock_word request
K0_OLD="order pingpong upgrade upgrade_l2 forward storm wb_control wb_evict silent_own sync_pingpong sync_barrier sync_storepp mx_handover mx_handover_rec mx_excl mx_cond mx_cond_rec mx_lockword"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_fc() { cat "$W/BIN" 2>/dev/null; }
fc_cfg() { echo "$W/cfg/$1.json"; }   # label -> its request config
field() { echo "$SPANS" | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }'; }   # label field
old_log() { echo "$S/results/$(field "$1" 2)/regime_shared/$(field "$1" 3)/lru/run.log"; }
new_tree() { local t; t=$(field "$1" 2); echo "phaseA_b3_fc_${t#phaseA_b3_}"; }
new_log() { echo "$S/results/$(new_tree "$1")/regime_shared/$(field "$1" 3)/lru/run.log"; }
is_done() { grep -q "$DONE_MARKER" "$(new_log "$1")" 2>/dev/null; }
count_done() { local n=0 l; for l in $(echo "$SPANS" | cut -d'|' -f1); do is_done "$l" && n=$((n + 1)); done; echo "$n"; }
clean() { sed -E 's/\(Simulation time: [^)]*\)//' "$1"; }

# the scored config plus "sync_lock_word": "request", and nothing else changed
make_fc_cfg() {   # label
  local src dst; src=$(field "$1" 4); dst=$(fc_cfg "$1")
  [ -s "$src" ] || { echo "no config $src"; return 1; }
  mkdir -p "$W/cfg"
  "$PY" - "$src" "$dst.tmp" <<'PYEOF' || return 1
import json, sys
c = json.load(open(sys.argv[1]))
if 'sync_lock_word' in c:
    sys.exit(f'{sys.argv[1]} already sets sync_lock_word')
n = dict(c, sync_lock_word='request')
assert {k: v for k, v in n.items() if k != 'sync_lock_word'} == c
json.dump(n, open(sys.argv[2], 'w'), indent=2)
PYEOF
  mv -f "$dst.tmp" "$dst"
}

# what a request run must print: complete, the request line once, one request
# line per waited-acquire line, unexplained view-order violations 0 (each line)
req_ok() {   # log -> '' or why not
  local f="$1" a b u
  grep -q "$DONE_MARKER" "$f" 2>/dev/null || { echo "did not complete"; return; }
  [ "$(grep -c '^SYNC LOCK WORD: request$' "$f")" = 1 ] || { echo "no single SYNC LOCK WORD: request line"; return; }
  a=$(grep -c '^CPU [0-9]* MUTEX WAITED ACQUIRES:' "$f"); b=$(grep -c '^CPU [0-9]* LOCK-WORD REQUESTS:' "$f")
  [ "$a" -gt 0 ] && [ "$a" = "$b" ] || { echo "$b request lines for $a waited-acquire lines"; return; }
  u=$(awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:/ { n++; s += $NF } END { print n + 0, s + 0 }' "$f")
  [ "${u%% *}" -gt 0 ] && [ "${u#* }" = 0 ] || { echo "unexplained view-order violations (lines, sum) $u"; return; }
  grep -q 'Reached end of trace' "$f" && { echo "a trace wrapped"; return; }
  echo ""
}

# the traces (core order), warm-up and length of a scored run, from its log; "MISSING:..." on a problem
log_settings() {   # log -> "wu si trace..."
  local f="$1" wu si n tr k
  grep -q "$DONE_MARKER" "$f" 2>/dev/null || { echo "MISSING:$f is not a complete run"; return 1; }
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$f")
  si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$f")
  n=$(awk '/^Number of CPUs:/ { print $4; exit }' "$f")
  tr=$(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$f" | sort -n -k1,1 | awk '{ print $2 }')
  [ -n "$wu" ] && [ -n "$si" ] && [ -n "$n" ] || { echo "MISSING:$f has no lengths"; return 1; }
  [ "$(echo "$tr" | grep -c .)" = "$n" ] || { echo "MISSING:$f lists $(echo "$tr" | grep -c .) traces for $n CPUs"; return 1; }
  [ "$(awk '/^CPU [0-9]+ runs / { print $2 }' "$f" | sort -n | tr '\n' ' ')" = "$(seq -s ' ' 0 $((n - 1))) " ] || { echo "MISSING:$f: the CPUs listed are not 0..$((n - 1))"; return 1; }
  for k in $tr; do [ -s "$k" ] || { echo "MISSING:$k"; return 1; }; done
  echo "$wu $si $(echo "$tr" | tr '\n' ' ')"
}

build() {
  mkdir -p "$W"
  alive "$PIDF" && die "the fc chain is running -- 'status'"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/lockfix_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -x "$REF" ] && [ "$(md5sum < "$REF" | cut -c1-32)" = "$REF_MD5" ] || die "no reference $REF with md5 $REF_MD5"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  [ "$(strings -a "$CB/simulator/bin/champsim" | grep -c 'LOCK-WORD REQUESTS')" -gt 0 ] || die "the new binary does not print LOCK-WORD REQUESTS"
  echo "== the three policy guards, in that tree"
  local g m
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_fc_$m.tmp" && mv -f "$S/bin/champsim_fc_$m.tmp" "$S/bin/champsim_fc_$m"
  rm -f "$W/Q0_PASSED" "$W/Q0M_PASSED" "$W/Q0R_PASSED" "$W/K0_PASSED"
  echo "$S/bin/champsim_fc_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_fc_$m"
  q0 || die "Q0 failed ($W/q0) -- nothing is launched"
  q0m || die "Q0m failed ($W/q0m) -- nothing is launched"
  q0r || die "Q0r failed ($W/q0r) -- nothing is launched"
}

# a line a minute while background runs go (a long silence lost a connection before)
wait_runs() {   # dir total
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) $(grep -l "$DONE_MARKER" "$1"/*.log 2>/dev/null | wc -l) of $2 runs done"
  done
  wait
}

# Q0: on canneal_4t (no sync records), 1 M + 2 M, LRU and Hawkeye, both
# regimes, levels 0 and 2, the setting absent: the new binary prints every line
# the lock-wait binary prints, and no SYNC, MUTEX or lock-word line.
q0() {
  local B Q="$W/q0" t="" i f pol rg lv c bad=0 n=0
  B=$(bin_fc); [ -x "$B" ] || die "no binary yet -- 'build'"
  rm -rf "$Q"; mkdir -p "$Q"
  for i in 1 2 3 4; do
    f="$S/traces/canneal_4t/canneal$i.champsimtrace.xz"; [ -f "$f" ] || f="$S/traces/canneal_4t/canneal$i.champsimtrace"
    [ -f "$f" ] || die "no canneal_4t trace $i for Q0"
    t="$t $f"
  done
  echo "== Q0: every line, against $(basename "$REF"), canneal 4c (no sync records), $QW + $QL"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$MC" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$c" --warmup-instructions "$QW" --simulation-instructions "$QL" $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions "$QW" --simulation-instructions "$QL" $t > "$Q/${pol}_${rg}_${lv}_new.log" 2>&1 ) &
  done; done; done
  echo "   $(date +%T) 16 runs started (8 pairs); waiting"
  wait_runs "$Q" 16
  for f in "$Q"/*_ref.log; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$f" && grep -q "$DONE_MARKER" "${f%_ref.log}_new.log" || { echo "   $(basename "${f%_ref.log}"): did not complete"; bad=$((bad + 1)); continue; }
    if grep -q -E "SYNC|MUTEX|$NEWLINES" "${f%_ref.log}_new.log"; then echo "   $(basename "${f%_ref.log}"): a SYNC, MUTEX or lock-word line on a trace without sync records"; bad=$((bad + 1)); continue; fi
    diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$f") <(sed -E 's/\(Simulation time: [^)]*\)//' "${f%_ref.log}_new.log") > /dev/null \
      || { echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0 FAILED: $bad of $n pairs differ"; return 1; }
  echo "   Q0 holds: $n of $n pairs print every line the same"
  echo "$(basename "$B")" > "$W/Q0_PASSED"
}

# Q0m: on synchronised traces with mutex records (the scored spans' own, 1 M +
# 2 M, their configs, the setting absent), every line equal to the lock-wait
# binary's, the waited-acquire lines included, and no lock-word line.
q0m() {
  local B Q="$W/q0m" l s wu si tr bad=0 n=0 a b
  B=$(bin_fc); [ -x "$B" ] || die "no binary yet -- 'build'"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0m: the synchronised traces of $Q0M_SPANS, against $(basename "$REF"), $QW + $QL"
  for l in $Q0M_SPANS; do
    s=$(log_settings "$(old_log "$l")") || die "Q0m: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    [ -s "$(field "$l" 4)" ] || die "Q0m: no config $(field "$l" 4)"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$(field "$l" 4)" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$(field "$l" 4)" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_new.log" 2>&1 ) &
  done
  wait_runs "$Q" $(( 2 * $(echo $Q0M_SPANS | wc -w) ))
  for l in $Q0M_SPANS; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$Q/${l}_ref.log" && grep -q "$DONE_MARKER" "$Q/${l}_new.log" || { echo "   $l: did not complete"; bad=$((bad + 1)); continue; }
    a=$(grep -c '^CPU [0-9]* MUTEX ACQUIRES:' "$Q/${l}_new.log")
    [ "$a" -gt 0 ] || { echo "   $l: no MUTEX ACQUIRES line on a synchronised trace"; bad=$((bad + 1)); continue; }
    if grep -q -E "$NEWLINES" "$Q/${l}_new.log"; then echo "   $l: a lock-word line with the setting absent"; bad=$((bad + 1)); continue; fi
    diff <(clean "$Q/${l}_ref.log") <(clean "$Q/${l}_new.log") > /dev/null || { echo "   DIFFERS: $l"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0m FAILED: $bad of $n differ"; return 1; }
  echo "   Q0m holds: $n of $n print every line the same, and no lock-word line"
  echo "$(basename "$B")" > "$W/Q0M_PASSED"
}

# Q0r: Q0m's spans with request, 1 M + 2 M: each completes and prints what a
# request run must (req_ok). Nothing is scored from it.
q0r() {
  local B Q="$W/q0r" l s wu si tr why bad=0 n=0
  B=$(bin_fc); [ -x "$B" ] || die "no binary yet -- 'build'"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0r: $Q0M_SPANS with sync_lock_word request, $QW + $QL"
  for l in $Q0M_SPANS; do
    make_fc_cfg "$l" || die "Q0r: no request config for $l"
    s=$(log_settings "$(old_log "$l")") || die "Q0r: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$(fc_cfg "$l")" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_req.log" 2>&1 ) &
  done
  wait_runs "$Q" "$(echo $Q0M_SPANS | wc -w)"
  for l in $Q0M_SPANS; do
    n=$((n + 1))
    why=$(req_ok "$Q/${l}_req.log")
    [ -z "$why" ] || { echo "   $l: $why"; bad=$((bad + 1)); continue; }
    echo "   $l: complete; lock-word requests $(awk '/^CPU [0-9]+ LOCK-WORD REQUESTS:/ { m += $6; w += $8 } END { print "measured", m + 0, "warm-up", w + 0 }' "$Q/${l}_req.log"); unexplained violations 0"
  done
  [ "$bad" = 0 ] || { echo "   Q0r FAILED: $bad of $n"; return 1; }
  echo "   Q0r holds: $n of $n"
  echo "$(basename "$B")" > "$W/Q0R_PASSED"
}

# K0: the exact suite with both binaries, side by side, then their logs compared
k0() {
  local B K="$W/k0" r f g n=0 bad=0 nf want
  B=$(bin_fc); [ -x "$B" ] || die "no binary yet -- 'build'"
  [ -f "$SUITE" ] && [ -f "$CB/bench/policy_sanity/coherence_exact_traces.py" ] || die "no exact suite in $CB/bench/policy_sanity -- scripts/lockfix_all.sh check uploads it"
  rm -rf "$K" "$K0TMP"; mkdir -p "$K" "$K0TMP" || die "cannot create $K0TMP"
  echo "== K0: the exact suite, $(basename "$B") on every case and $(basename "$REF") on the cases it can run, levels 0 1 2, $K0JOBS at a time each"
  ( BIN="$B" LOGDIR="$K0TMP/fc" JOBS="$K0JOBS" nice -n 19 bash "$SUITE" > "$K/suite_fc.txt" 2>&1 ) &
  ( BIN="$REF" LOGDIR="$K0TMP/lc" JOBS="$K0JOBS" ONLY="$K0_OLD" nice -n 19 bash "$SUITE" > "$K/suite_lc.txt" 2>&1 ) &
  echo "   $(date +%T) both suites started; waiting"
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) logs written: new $(ls "$K0TMP"/fc/*.log 2>/dev/null | wc -l), lock-wait $(ls "$K0TMP"/lc/*.log 2>/dev/null | wc -l)"
  done
  wait
  for r in fc lc; do
    mkdir -p "$K/$r"; cp -p "$K0TMP/$r"/*.log "$K0TMP/$r"/*.events "$K/$r/" 2>/dev/null
    echo "   suite, $r: $(grep -c '^ok ' "$K/suite_$r.txt") ok, $(grep -c '^FAIL ' "$K/suite_$r.txt") FAIL; $(tail -1 "$K/suite_$r.txt" | cut -c1-90)"
    grep -q '^PASS:' "$K/suite_$r.txt" || bad=$((bad + 1))
  done
  rm -rf "$K0TMP"
  # every case x level (order also private) of each suite has its log
  nf=$(ls "$K"/fc/*.log 2>/dev/null | wc -l); want=$(( 3 * ($(echo "$K0_OLD" | wc -w) + 3 + 1) ))
  [ "$nf" = "$want" ] || { echo "   the new binary's suite left $nf logs, want $want"; bad=$((bad + 1)); }
  [ "$(ls "$K"/lc/*.log 2>/dev/null | wc -l)" = $(( 3 * ($(echo "$K0_OLD" | wc -w) + 1) )) ] || { echo "   the lock-wait binary's suite left $(ls "$K"/lc/*.log 2>/dev/null | wc -l) logs"; bad=$((bad + 1)); }
  for f in "$K"/lc/*.log; do
    g="$K/fc/$(basename "$f")"; n=$((n + 1))
    [ -f "$g" ] || { echo "   no new-binary log for $(basename "$f")"; bad=$((bad + 1)); continue; }
    diff <(clean "$f" | sed "s#$K0TMP/lc/#DIR/#g") <(clean "$g" | sed "s#$K0TMP/fc/#DIR/#g") > /dev/null \
      || { echo "   DIFFERS: $(basename "$f")"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   K0 FAILED ($bad; $K)"; return 1; }
  echo "   K0 holds: both suites PASS; $n of $n logs of the cases both run are equal line for line"
  echo "$(basename "$B")" > "$W/K0_PASSED"
}

span() {   # label: the scored run again, on the new binary
  local l="$1" B s wu si tr log cfg
  B=$(bin_fc); log=$(new_log "$l"); cfg=$(fc_cfg "$l")
  if is_done "$l"; then echo "$(date '+%F %T') SKIP  $l (complete)"; return 0; fi
  s=$(log_settings "$(old_log "$l")") || { echo "$(date '+%F %T') FAIL  $l -- ${s#MISSING:}"; return 0; }
  [ -s "$cfg" ] || { echo "$(date '+%F %T') FAIL  $l -- no config $cfg"; return 0; }
  read -r wu si tr <<< "$s"
  mkdir -p "$(dirname "$log")"
  { echo "binary $B $(md5sum < "$B" | cut -c1-32)"; echo "config $cfg $(md5sum < "$cfg" | cut -c1-32)"; echo "scored $(old_log "$l")"; echo "warmup $wu simulation $si"; echo "traces $tr"; } > "$(dirname "$log")/cmd.txt"
  echo "$(date '+%F %T') START $l ($wu + $si; $(echo $tr | wc -w) traces)"
  # shellcheck disable=SC2086
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" $tr > "$log" 2>&1 )
  echo "$(date '+%F %T') END   $l rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

# Q3 (and what a request run must print), on every rerun; the scorer checks it
# again on the pulled logs, with the runs' settings against the scored logs.
q3() {
  local l ok=0 bad=0 waiting=0 why
  for l in $(echo "$SPANS" | cut -d'|' -f1); do
    if ! is_done "$l"; then waiting=$((waiting + 1)); continue; fi
    why=$(req_ok "$(new_log "$l")")
    if [ -z "$why" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "   Q3 FAILS: $l ($why)"; fi
  done
  echo "   Q3: $ok hold, $bad fail, $waiting not complete (of $NSPANS)"
}

chain_drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') CHAIN START: $NSPANS reruns, $PAR at a time, $(basename "$(bin_fc)")"
  echo "$SPANS" | cut -d'|' -f1 | xargs -P "$PAR" -I{} bash "$SELF" __span {}
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $NSPANS reruns complete"
  q3 | tee "$W/q3.txt"
  rm -f "$PIDF"
}

case "${1:-}" in
  build) mkdir -p "$W"; build 2>&1 | tee -p "$W/build_run.log"; exit "${PIPESTATUS[0]}" ;;
  check)
    mkdir -p "$W"
    { build && k0 && echo "CHECK PASSED: $(basename "$(bin_fc)"): Q0, Q0m, Q0r and K0 hold. No rerun was started: 'chain' starts them (owner's word)."; } 2>&1 | tee -p "$W/check_run.log"
    exit "${PIPESTATUS[0]}" ;;
  k0) mkdir -p "$W"; k0 2>&1 | tee -p "$W/k0_run.log"; exit "${PIPESTATUS[0]}" ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the fc chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    B=$(bin_fc); [ -x "$B" ] || die "no binary yet -- 'build'"
    [ "$(cat "$W/Q0_PASSED" 2>/dev/null)" = "$(basename "$B")" ] && [ "$(cat "$W/Q0M_PASSED" 2>/dev/null)" = "$(basename "$B")" ] \
      && [ "$(cat "$W/Q0R_PASSED" 2>/dev/null)" = "$(basename "$B")" ] && [ "$(cat "$W/K0_PASSED" 2>/dev/null)" = "$(basename "$B")" ] \
      || die "$(basename "$B") has not passed Q0, Q0m, Q0r and K0 -- 'check'"
    for l in $(echo "$SPANS" | cut -d'|' -f1); do
      s=$(log_settings "$(old_log "$l")") || die "$l: ${s#MISSING:}"
      make_fc_cfg "$l" || die "$l: no request config from $(field "$l" 4)"
    done
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      # a chain whose reruns were all complete ends within the 3 s: that is not a
      # failure (found by the 2026-11-10 rehearsal, which called it one)
      if tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END'; then
        tail -n +$((n0 + 1)) "$LOG" | tail -3
        echo "started: the chain has already ended (every rerun was complete); log $LOG"
        exit 0
      fi
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $NSPANS reruns, $PAR at a time, then Q3; log $LOG" ;;
  __chain) chain_drive ;;
  __span) span "$2" ;;
  q3) q3 ;;
  status)
    pq() { [ -n "$(bin_fc)" ] && [ "$(cat "$W/$1" 2>/dev/null)" = "$(basename "$(bin_fc)")" ] && echo passed || echo 'not passed'; }
    echo "== fc (F-C, the lock-word request): binary $(basename "$(bin_fc)" 2>/dev/null); Q0 $(pq Q0_PASSED); Q0m $(pq Q0M_PASSED); Q0r $(pq Q0R_PASSED); K0 $(pq K0_PASSED); reruns $(count_done) of $NSPANS complete; chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$W/check_run.log" ] && { echo "   -- check:"; tail -n 4 "$W/check_run.log" | sed 's/^/      /'; }
    [ -f "$W/q3.txt" ] && sed 's/^/   /' "$W/q3.txt"
    [ -f "$LOG" ] && tail -n 4 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'lockfix_server.sh __chain' || die "pid $sid is not a lockfix_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2
      rm -f "$PIDF"; echo "stopped the fc chain (session $sid)"
    else
      echo "the fc chain is not running"
    fi ;;
  *) echo "usage: $0 check | build | k0 | chain | status | q3 | stop"; exit 1 ;;
esac
