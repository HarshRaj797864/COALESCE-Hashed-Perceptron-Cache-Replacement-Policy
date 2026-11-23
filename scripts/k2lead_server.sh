#!/usr/bin/env bash
# K2 step 3 on the server (bench/policy_sanity/k2_sharing_gap_design_2026-11-17.md,
# amendments 2 and 3): the DIAGNOSTIC lead limit (sync_lead_limit), never the
# tool's setting. A copy of lockfix_server.sh: builds in its own tree
# (~/k2_build), state in ~/k2lead, binary bin/champsim_k2_<md5>. bin/champsim,
# every trace, every scored run and every live chain are left as they are: the
# runs write only new trees, results/phaseA_b3_k2d<1m|100k>_<p>4.
#
#   bash ~/k2lead_server.sh check    # build, guards, frozen copy, Q0, Q0m, Q0l, K0, KL2 (no run starts)
#   bash ~/k2lead_server.sh chain    # detached: the 8 diagnostic runs, then Q3 (owner's word)
#   bash ~/k2lead_server.sh status | q3 | stop
#
# KL0 = Q0 + Q0m + K0, the setting absent, against the F-C binary
# (champsim_fc_a2e88e46): Q0 on canneal_4t without sync records (16 runs, 8
# pairs), Q0m on the synchronised traces of barnes std force, ocean 4 and
# canneal 4 with their F-C configs: every line equal, no lead-limit line. K0:
# the exact suite with the new binary and with the F-C binary, every case at
# levels 0-2, both PASS, every log equal line for line.
# KL2 (amendment 3): the exact suite's sync_barrier, mx_handover and mx_cond at
# levels 0-2 with LEAD=1000: PASS (every hand count, no deadlock, the lead line).
# Q0l: the four programs at Delta 100,000, 1 M + 2 M: complete, one lead line,
# a LEAD HOLDS line per core, the request line, unexplained view-order
# violations 0 (decides only whether the chain may start; nothing is read).
# Each run: its F-C rerun's config plus "sync_lead_limit": Delta and nothing
# else (checked), the F-C rerun's traces and lengths (from its log).
# fluidanimate at 100,000 also writes COHERENCE_EVENT_LOG (records only), turned
# into ev.txt by H6(b)'s h6b_attr.py with H6(b)'s rmw.txt of the same traces.
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "k2lead_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/k2_build}"
W="${W:-$HOME/k2lead}"
FCW="${FCW:-$HOME/sync_fc}"                         # the F-C configs (cfg/<label>.json)
H6B="${H6B:-$HOME/h6b}"                             # h6b_attr.py and cs/fluidanimate/rmw.txt
REF="${REF:-$S/bin/champsim_fc_a2e88e46}"           # the F-C binary: KL0 compares against it
REF_MD5="${REF_MD5:-a2e88e46788e1f332427567a19bc2f90}"
NEWLINES='LEAD LIMIT|LEAD HOLDS'                    # what only a lead-limit run prints
PAR="${PAR:-8}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"
PY="${PY:-python3}"
QW="${QW:-1000000}"; QL="${QL:-2000000}"
SUITE="$CB/bench/policy_sanity/check_coherence_exact.sh"
K0TMP="${K0TMP:-/tmp/harshraj_k2_k0}"               # the suites' traces and logs, on / (not the nearly full /home); removed after
K0JOBS="${K0JOBS:-8}"
KL2_CASES="${KL2_CASES:-sync_barrier mx_handover mx_cond}"
KL2_LEAD="${KL2_LEAD:-1000}"

# program | F-C rerun tree | <workload>_<n>core | F-C config
PROGS="${PROGS:-fluidanimate|phaseA_b3_fc_h2_fluidanimate4|fluidanimate_4core|$FCW/cfg/fluidanimate.json
vips|phaseA_b3_fc_h2_vips4|vips_4core|$FCW/cfg/vips.json
canneal|phaseA_b3_fc_g3_canneal4|canneal_4core|$FCW/cfg/canneal4.json
ocean|phaseA_b3_fc_g3_ocean4|ocean_4core|$FCW/cfg/ocean4.json}"
# Q0m: F-C spans with sync records (same layout)
Q0M="${Q0M:-barnesstd_force|phaseA_b3_fc_g3_barnesstd4_force|barnes_4core|$FCW/cfg/barnesstd_force.json
ocean4|phaseA_b3_fc_g3_ocean4|ocean_4core|$FCW/cfg/ocean4.json
canneal4|phaseA_b3_fc_g3_canneal4|canneal_4core|$FCW/cfg/canneal4.json}"
DELTAS="${DELTAS:-1m:1000000 100k:100000}"
EVENT_RUN="${EVENT_RUN:-fluidanimate@100k}"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_k2() { cat "$W/BIN" 2>/dev/null; }
clean() { sed -E 's/\(Simulation time: [^)]*\)//' "$1"; }
pfield() { echo "$1" | awk -F'|' -v n="$2" -v f="$3" '$1 == n { print $f }'; }   # table label field
runs() { local p d; for p in $(echo "$PROGS" | cut -d'|' -f1); do for d in $DELTAS; do echo "$p@${d%%:*}"; done; done; }
NRUNS=$(runs | wc -l)
prog_of() { echo "${1%@*}"; }
dtag_of() { echo "${1#*@}"; }
delta_of() { local d; for d in $DELTAS; do [ "${d%%:*}" = "$(dtag_of "$1")" ] && echo "${d#*:}"; done; }
ref_log() { echo "$S/results/$(pfield "$PROGS" "$(prog_of "$1")" 2)/regime_shared/$(pfield "$PROGS" "$(prog_of "$1")" 3)/lru/run.log"; }
new_tree() { echo "phaseA_b3_k2d$(dtag_of "$1")_$(prog_of "$1")4"; }
new_dir() { echo "$S/results/$(new_tree "$1")/regime_shared/$(pfield "$PROGS" "$(prog_of "$1")" 3)/lru"; }
new_log() { echo "$(new_dir "$1")/run.log"; }
run_cfg() { echo "$W/cfg/$(prog_of "$1")_$(dtag_of "$1").json"; }
is_done() { grep -q "$DONE_MARKER" "$(new_log "$1")" 2>/dev/null; }
count_done() { local n=0 r; for r in $(runs); do is_done "$r" && n=$((n + 1)); done; echo "$n"; }

# the F-C config plus "sync_lead_limit": Delta, and nothing else changed
make_cfg() {   # source config, delta, destination
  mkdir -p "$(dirname "$3")"
  "$PY" - "$1" "$2" "$3.tmp" <<'PYEOF' || return 1
import json, sys
c = json.load(open(sys.argv[1]))
if c.get('sync_lock_word') != 'request':
    sys.exit(f'{sys.argv[1]} is not an F-C config (sync_lock_word {c.get("sync_lock_word")})')
if 'sync_lead_limit' in c:
    sys.exit(f'{sys.argv[1]} already sets sync_lead_limit')
n = dict(c, sync_lead_limit=int(sys.argv[2]))
assert {k: v for k, v in n.items() if k != 'sync_lead_limit'} == c
json.dump(n, open(sys.argv[3], 'w'), indent=2)
PYEOF
  mv -f "$3.tmp" "$3"
}

# what a lead run must print: complete, one lead line, a LEAD HOLDS line per CPU,
# the F-C request line, unexplained view-order violations 0 (each line), no wrap
lead_ok() {   # log delta -> '' or why not
  local f="$1" n h u
  grep -q "$DONE_MARKER" "$f" 2>/dev/null || { echo "did not complete"; return; }
  [ "$(grep -c "^SYNC LEAD LIMIT: $2 instructions\$" "$f")" = 1 ] || { echo "no single 'SYNC LEAD LIMIT: $2 instructions' line"; return; }
  n=$(awk '/^Number of CPUs:/ { print $4; exit }' "$f"); h=$(grep -c '^CPU [0-9]* LEAD HOLDS:' "$f")
  [ "$h" = "$n" ] || { echo "$h LEAD HOLDS lines for $n CPUs"; return; }
  [ "$(grep -c '^SYNC LOCK WORD: request$' "$f")" = 1 ] || { echo "no single SYNC LOCK WORD: request line"; return; }
  u=$(awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:/ { n++; s += $NF } END { print n + 0, s + 0 }' "$f")
  [ "${u%% *}" -gt 0 ] && [ "${u#* }" = 0 ] || { echo "unexplained view-order violations (lines, sum) $u"; return; }
  grep -q 'Reached end of trace' "$f" && { echo "a trace wrapped"; return; }
  echo ""
}

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

wait_runs() {   # dir total
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) $(grep -l "$DONE_MARKER" "$1"/*.log 2>/dev/null | wc -l) of $2 runs done"
  done
  wait
}

build() {
  mkdir -p "$W"
  alive "$PIDF" && die "the k2 chain is running -- 'status'"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/k2lead_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -x "$REF" ] && [ "$(md5sum < "$REF" | cut -c1-32)" = "$REF_MD5" ] || die "no reference $REF with md5 $REF_MD5"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  [ "$(strings -a "$CB/simulator/bin/champsim" | grep -c 'LEAD HOLDS')" -gt 0 ] || die "the new binary does not print LEAD HOLDS"
  echo "== the three policy guards, in that tree"
  local g m
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_k2_$m.tmp" && mv -f "$S/bin/champsim_k2_$m.tmp" "$S/bin/champsim_k2_$m"
  rm -f "$W/Q0_PASSED" "$W/Q0M_PASSED" "$W/Q0L_PASSED" "$W/K0_PASSED" "$W/KL2_PASSED"
  echo "$S/bin/champsim_k2_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_k2_$m"
}

# Q0: canneal_4t (no sync records), 1 M + 2 M, LRU and Hawkeye, both regimes,
# levels 0 and 2, the setting absent: every line the F-C binary prints, and no
# SYNC, MUTEX or lead-limit line.
q0() {
  local B Q="$W/q0" t="" i f pol rg lv c bad=0 n=0
  B=$(bin_k2); [ -x "$B" ] || die "no binary yet"
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
    if grep -q -E "SYNC|MUTEX|$NEWLINES" "${f%_ref.log}_new.log"; then echo "   $(basename "${f%_ref.log}"): a SYNC, MUTEX or lead-limit line on a trace without sync records"; bad=$((bad + 1)); continue; fi
    diff <(clean "$f") <(clean "${f%_ref.log}_new.log") > /dev/null || { echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0 FAILED: $bad of $n pairs differ"; return 1; }
  echo "   Q0 holds: $n of $n pairs print every line the same"
  basename "$B" > "$W/Q0_PASSED"
}

# Q0m: synchronised traces with their F-C configs (request), 1 M + 2 M, the
# setting absent: every line equal to the F-C binary's, and no lead-limit line.
q0m() {
  local B Q="$W/q0m" l s wu si tr bad=0 n=0 cfg
  B=$(bin_k2); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0m: the synchronised traces of $(echo "$Q0M" | cut -d'|' -f1 | tr '\n' ' '), F-C configs, against $(basename "$REF"), $QW + $QL"
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    s=$(log_settings "$S/results/$(pfield "$Q0M" "$l" 2)/regime_shared/$(pfield "$Q0M" "$l" 3)/lru/run.log") || die "Q0m: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    cfg=$(pfield "$Q0M" "$l" 4); [ -s "$cfg" ] || die "Q0m: no config $cfg"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_new.log" 2>&1 ) &
  done
  wait_runs "$Q" $(( 2 * $(echo "$Q0M" | grep -c '|') ))
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$Q/${l}_ref.log" && grep -q "$DONE_MARKER" "$Q/${l}_new.log" || { echo "   $l: did not complete"; bad=$((bad + 1)); continue; }
    [ "$(grep -c '^SYNC LOCK WORD: request$' "$Q/${l}_new.log")" = 1 ] || { echo "   $l: not an F-C run (no request line)"; bad=$((bad + 1)); continue; }
    if grep -q -E "$NEWLINES" "$Q/${l}_new.log"; then echo "   $l: a lead-limit line with the setting absent"; bad=$((bad + 1)); continue; fi
    diff <(clean "$Q/${l}_ref.log") <(clean "$Q/${l}_new.log") > /dev/null || { echo "   DIFFERS: $l"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0m FAILED: $bad of $n differ"; return 1; }
  echo "   Q0m holds: $n of $n print every line the same, and no lead-limit line"
  basename "$B" > "$W/Q0M_PASSED"
}

# Q0l: the four programs at Delta 100,000, 1 M + 2 M: what a lead run must print
q0l() {
  local B Q="$W/q0l" p s wu si tr why bad=0 n=0 d=100000
  B=$(bin_k2); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0l: $(echo "$PROGS" | cut -d'|' -f1 | tr '\n' ' ')at Delta $d, $QW + $QL"
  for p in $(echo "$PROGS" | cut -d'|' -f1); do
    make_cfg "$(pfield "$PROGS" "$p" 4)" "$d" "$Q/$p.json" || die "Q0l: no lead config for $p"
    s=$(log_settings "$(ref_log "$p@100k")") || die "Q0l: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$Q/$p.json" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/$p.log" 2>&1 ) &
  done
  wait_runs "$Q" "$(echo "$PROGS" | grep -c '|')"
  for p in $(echo "$PROGS" | cut -d'|' -f1); do
    n=$((n + 1))
    why=$(lead_ok "$Q/$p.log" "$d")
    [ -z "$why" ] || { echo "   $p: $why"; bad=$((bad + 1)); continue; }
    echo "   $p: complete; lead-held cycles (measured + warm-up) $(awk '/^CPU [0-9]+ LEAD HOLDS:/ { s += $6 + $8 } END { print s + 0 }' "$Q/$p.log"); unexplained violations 0"
  done
  [ "$bad" = 0 ] || { echo "   Q0l FAILED: $bad of $n"; return 1; }
  echo "   Q0l holds: $n of $n"
  basename "$B" > "$W/Q0L_PASSED"
}

# K0: the exact suite with both binaries, side by side, then their logs compared
k0() {
  local B K="$W/k0" r f g n=0 bad=0 want
  B=$(bin_k2); [ -x "$B" ] || die "no binary yet"
  [ -f "$SUITE" ] && [ -f "$CB/bench/policy_sanity/coherence_exact_traces.py" ] || die "no exact suite in $CB/bench/policy_sanity"
  rm -rf "$K" "$K0TMP"; mkdir -p "$K" "$K0TMP" || die "cannot create $K0TMP"
  echo "== K0: the exact suite, $(basename "$B") and $(basename "$REF") on every case, levels 0 1 2, $K0JOBS at a time each"
  ( BIN="$B" LOGDIR="$K0TMP/k2" JOBS="$K0JOBS" nice -n 19 bash "$SUITE" > "$K/suite_k2.txt" 2>&1 ) &
  ( BIN="$REF" LOGDIR="$K0TMP/fc" JOBS="$K0JOBS" nice -n 19 bash "$SUITE" > "$K/suite_fc.txt" 2>&1 ) &
  echo "   $(date +%T) both suites started; waiting"
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) logs written: new $(ls "$K0TMP"/k2/*.log 2>/dev/null | wc -l), F-C $(ls "$K0TMP"/fc/*.log 2>/dev/null | wc -l)"
  done
  wait
  for r in k2 fc; do
    mkdir -p "$K/$r"; cp -p "$K0TMP/$r"/*.log "$K/$r/" 2>/dev/null
    echo "   suite, $r: $(grep -c '^ok ' "$K/suite_$r.txt") ok, $(grep -c '^FAIL ' "$K/suite_$r.txt") FAIL; $(tail -1 "$K/suite_$r.txt" | cut -c1-90)"
    grep -q '^PASS:' "$K/suite_$r.txt" || bad=$((bad + 1))
  done
  rm -rf "$K0TMP"
  want=$(grep -c '^ok ' "$K/suite_fc.txt")
  for f in "$K"/fc/*.log; do
    g="$K/k2/$(basename "$f")"; n=$((n + 1))
    [ -f "$g" ] || { echo "   no new-binary log for $(basename "$f")"; bad=$((bad + 1)); continue; }
    diff <(clean "$f" | sed "s#$K0TMP/fc/#DIR/#g") <(clean "$g" | sed "s#$K0TMP/k2/#DIR/#g") > /dev/null || { echo "   DIFFERS: $(basename "$f")"; bad=$((bad + 1)); }
  done
  [ "$n" -gt 0 ] && [ "$n" = "$(ls "$K"/k2/*.log 2>/dev/null | wc -l)" ] || { echo "   log counts differ: F-C $n, new $(ls "$K"/k2/*.log 2>/dev/null | wc -l)"; bad=$((bad + 1)); }
  [ "$bad" = 0 ] || { echo "   K0 FAILED ($bad; $K)"; return 1; }
  echo "   K0 holds: both suites PASS ($want cases x levels each); $n of $n logs equal line for line"
  basename "$B" > "$W/K0_PASSED"
}

# KL2: sync cases of the suite at LEAD=$KL2_LEAD, levels 0-2: PASS
kl2() {
  local B K="$W/kl2"
  B=$(bin_k2); [ -x "$B" ] || die "no binary yet"
  rm -rf "$K" "$K0TMP.kl2"; mkdir -p "$K"
  echo "== KL2: the exact suite's $KL2_CASES with sync_lead_limit $KL2_LEAD, levels 0 1 2"
  BIN="$B" LOGDIR="$K0TMP.kl2" JOBS="$K0JOBS" ONLY="$KL2_CASES" LEAD="$KL2_LEAD" nice -n 19 bash "$SUITE" > "$K/suite.txt" 2>&1
  cp -p "$K0TMP.kl2"/*.log "$K/" 2>/dev/null; rm -rf "$K0TMP.kl2"
  sed 's/^/   /' "$K/suite.txt" | grep -E '^   (ok|FAIL|PASS|FAILED|        )' | cut -c1-160
  grep -q '^PASS:' "$K/suite.txt" || { echo "   KL2 FAILED ($K)"; return 1; }
  echo "   KL2 holds: $(grep -c '^ok ' "$K/suite.txt") of $(grep -c -E '^(ok|FAIL) ' "$K/suite.txt") at sync_lead_limit $KL2_LEAD"
  basename "$B" > "$W/KL2_PASSED"
}

one_run() {   # program@dtag
  local r="$1" B s wu si tr log cfg d od
  B=$(bin_k2); log=$(new_log "$r"); cfg=$(run_cfg "$r"); d=$(delta_of "$r"); od=$(new_dir "$r")
  if is_done "$r"; then echo "$(date '+%F %T') SKIP  $r (complete)"; return 0; fi
  s=$(log_settings "$(ref_log "$r")") || { echo "$(date '+%F %T') FAIL  $r -- ${s#MISSING:}"; return 0; }
  [ -s "$cfg" ] || { echo "$(date '+%F %T') FAIL  $r -- no config $cfg"; return 0; }
  read -r wu si tr <<< "$s"
  mkdir -p "$od"
  { echo "binary $B $(md5sum < "$B" | cut -c1-32)"; echo "config $cfg $(md5sum < "$cfg" | cut -c1-32)"; echo "reference $(ref_log "$r")"
    echo "delta $d"; echo "warmup $wu simulation $si"; echo "traces $tr"; } > "$od/cmd.txt"
  echo "$(date '+%F %T') START $r (Delta $d; $wu + $si; $(echo $tr | wc -w) traces) -> $(new_tree "$r")"
  if [ "$r" = "$EVENT_RUN" ]; then
    rm -f "$od/events.log" "$od/events.log.xz"
    # shellcheck disable=SC2086
    ( cd "$S" && COHERENCE_EVENT_LOG="$od/events.log" nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" $tr > "$log" 2>&1 )
    echo "$(date '+%F %T') END   $r rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
    nice -n 19 "$PY" "$H6B/h6b_attr.py" champsim "$od/events.log" "$H6B/cs/$(prog_of "$r")/rmw.txt" "$log" > "$od/ev.txt" 2> "$od/attr.err"
    echo "$(date '+%F %T') EVENTS $r: h6b_attr rc $?; $(head -1 "$od/ev.txt" | cut -c1-120)"
    nice -n 19 xz -T1 -f "$od/events.log"
  else
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" $tr > "$log" 2>&1 )
    echo "$(date '+%F %T') END   $r rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
  fi
}

q3() {
  local r ok=0 bad=0 waiting=0 why
  for r in $(runs); do
    if ! is_done "$r"; then waiting=$((waiting + 1)); continue; fi
    why=$(lead_ok "$(new_log "$r")" "$(delta_of "$r")")
    if [ -z "$why" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "   Q3 FAILS: $r ($why)"; fi
  done
  echo "   Q3: $ok hold, $bad fail, $waiting not complete (of $NRUNS)"
}

chain_drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') CHAIN START: $NRUNS diagnostic runs, $PAR at a time, $(basename "$(bin_k2)")"
  runs | xargs -P "$PAR" -I{} bash "$SELF" __run {}
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $NRUNS runs complete"
  q3 | tee "$W/q3.txt"
  rm -f "$PIDF"
}

passed() { [ -n "$(bin_k2)" ] && [ "$(cat "$W/$1" 2>/dev/null)" = "$(basename "$(bin_k2)")" ]; }

case "${1:-}" in
  check)
    mkdir -p "$W"
    { build && q0 && q0m && q0l && k0 && kl2 \
        && echo "CHECK PASSED: $(basename "$(bin_k2)"): Q0, Q0m, Q0l, K0 and KL2 hold. No run was started: 'chain' starts them (owner's word)."; } 2>&1 | tee -p "$W/check_run.log"
    exit "${PIPESTATUS[0]}" ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the k2 chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    B=$(bin_k2); [ -x "$B" ] || die "no binary yet -- 'check'"
    for q in Q0_PASSED Q0M_PASSED Q0L_PASSED K0_PASSED KL2_PASSED; do passed "$q" || die "$(basename "$B") has not passed ${q%_PASSED} -- 'check'"; done
    [ -s "$H6B/h6b_attr.py" ] && [ -s "$H6B/cs/$(prog_of "$EVENT_RUN")/rmw.txt" ] || die "no $H6B/h6b_attr.py or rmw.txt for the event run"
    for r in $(runs); do
      s=$(log_settings "$(ref_log "$r")") || die "$r: ${s#MISSING:}"
      make_cfg "$(pfield "$PROGS" "$(prog_of "$r")" 4)" "$(delta_of "$r")" "$(run_cfg "$r")" || die "$r: no lead config"
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
    echo "started: $NRUNS runs, $PAR at a time, then Q3; log $LOG" ;;
  __chain) chain_drive ;;
  __run) one_run "$2" ;;
  q3) q3 ;;
  status)
    pq() { passed "$1" && echo passed || echo 'not passed'; }
    echo "== k2lead (K2 step 3, the diagnostic lead limit): binary $(basename "$(bin_k2)" 2>/dev/null); Q0 $(pq Q0_PASSED); Q0m $(pq Q0M_PASSED); Q0l $(pq Q0L_PASSED); K0 $(pq K0_PASSED); KL2 $(pq KL2_PASSED); runs $(count_done) of $NRUNS complete; chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$W/check_run.log" ] && { echo "   -- check:"; tail -n 4 "$W/check_run.log" | sed 's/^/      /'; }
    [ -f "$W/q3.txt" ] && sed 's/^/   /' "$W/q3.txt"
    [ -f "$LOG" ] && tail -n 4 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'k2lead_server.sh __chain' || die "pid $sid is not a k2lead_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2
      rm -f "$PIDF"; echo "stopped the k2 chain (session $sid)"
    else
      echo "the k2 chain is not running"
    fi ;;
  *) echo "usage: $0 check | chain | status | q3 | stop"; exit 1 ;;
esac
