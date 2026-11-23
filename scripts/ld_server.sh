#!/usr/bin/env bash
# C, load-side communication against gem5, on the server
# (bench/policy_sanity/load_side_design_2026-11-18.md): the records-only
# counters LOAD / OTHER-READ GEM5-RULE OWNER EVENTS. A copy of mw_server.sh:
# builds in its own tree (~/ld_build), state in ~/ld, binary
# bin/champsim_ld_<md5>. bin/champsim, every trace, every scored run and every
# live chain are left as they are: the runs write only new trees,
# results/phaseA_b3_ld_<suffix>; the micro checks write only under ~/ld.
#
#   bash ~/ld_server.sh check    # build, guards, frozen copy, QC0 (Q0, Q0m, K0), then QC1a and QC1b (no B3 run starts)
#   bash ~/ld_server.sh chain    # detached: the runs listed in ~/ld/RUNS, then QC2 (owner's word; needs QC0 only)
#   bash ~/ld_server.sh status | qc2 | stop
#
# QC0 = Q0 + Q0m + K0 against the F-C binary (champsim_fc_a2e88e46): every
# line equal once the new lines are removed, and the new lines present.
# QC1a: the micro harness (4 threads, level 2, 4 rounds, timed form, event
# logs kept) on the new binary: on the test lines, LOAD events with the flag
# = 4 x the hand count, exactly (bench/ld_micro_judge.py cs). QC1b: gem5 on
# the micro (4 CPUs), the 10 cases at ROUNDS 4 and 8 from one static binary:
# MT.L1_GETS (r8 - r4) within 1 of 4 x the hand count (ld_micro_judge.py g5).
# QC2, after each run: its log equals its reference (the scored F-C rerun)
# apart from the new lines and the time stamps, and the LLC's new line is there.
# ~/ld/RUNS, one line a run:  label|reference tree|<workload>_<n>core|reference config|new tree
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "ld_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/ld_build}"
W="${W:-$HOME/ld}"
FCW="${FCW:-$HOME/sync_fc}"                         # the F-C configs (cfg/<label>.json)
REF="${REF:-$S/bin/champsim_fc_a2e88e46}"           # the F-C binary: QC0 compares against it
REF_MD5="${REF_MD5:-a2e88e46788e1f332427567a19bc2f90}"
NEWLINES='GEM5-RULE OWNER EVENTS'                    # what only the new binary prints
PAR="${PAR:-7}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"
PY="${PY:-python3}"
QW="${QW:-1000000}"; QL="${QL:-2000000}"
SUITE="$CB/bench/policy_sanity/check_coherence_exact.sh"
K0TMP="${K0TMP:-/tmp/harshraj_ld_k0}"               # the suites' traces and logs, on / (not the nearly full /home); removed after
K0JOBS="${K0JOBS:-8}"
RUNSF="$W/RUNS"
# QC1: the micro program
MCASES="${MCASES:-pp_lock pp_store pp_rmw readers upgrade ctl priv_E priv_S llc_out offchip}"
TRACER="${TRACER:-$HOME/sync_h2_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so}"
TRACER_MD5="${TRACER_MD5:-02ff8f48654b81f6f277cdac8a13d60b}"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
MTMP="${MTMP:-/tmp/harshraj_ld_micro}"
NUMPY="${NUMPY:-2.4.6}"
VENVS="${VENVS:-$HOME/q16cs/venv $W/venv}"          # the first with numpy $NUMPY is used; else $W/venv is made
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
G5PAR="${G5PAR:-10}"
G5W="$W/g5micro"

# Q0m: F-C spans with sync records (label|tree|<workload>_<n>core|F-C config)
Q0M="${Q0M:-barnesstd_force|phaseA_b3_fc_g3_barnesstd4_force|barnes_4core|$FCW/cfg/barnesstd_force.json
ocean4|phaseA_b3_fc_g3_ocean4|ocean_4core|$FCW/cfg/ocean4.json
canneal4|phaseA_b3_fc_g3_canneal4|canneal_4core|$FCW/cfg/canneal4.json}"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_ld() { cat "$W/BIN" 2>/dev/null; }
clean() { sed -E 's/\(Simulation time: [^)]*\)//' "$1"; }
oldlines() { clean "$1" | grep -v -E "$NEWLINES"; }   # a log without the new lines
has_new() { [ "$(grep -c -E "^LLC COHERENCE DIR LOAD $NEWLINES:" "$1")" -ge 1 ] && [ "$(grep -c -E "^LLC COHERENCE DIR OTHER-READ $NEWLINES:" "$1")" -ge 1 ]; }
pfield() { echo "$1" | awk -F'|' -v n="$2" -v f="$3" '$1 == n { print $f }'; }
runs() { [ -s "$RUNSF" ] && cut -d'|' -f1 "$RUNSF"; }
rfield() { awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }' "$RUNSF"; }
ref_log() { echo "$S/results/$(rfield "$1" 2)/regime_shared/$(rfield "$1" 3)/lru/run.log"; }
new_dir() { echo "$S/results/$(rfield "$1" 5)/regime_shared/$(rfield "$1" 3)/lru"; }
new_log() { echo "$(new_dir "$1")/run.log"; }
is_done() { grep -q "$DONE_MARKER" "$(new_log "$1")" 2>/dev/null; }
count_done() { local n=0 r; for r in $(runs); do is_done "$r" && n=$((n + 1)); done; echo "$n"; }
nruns() { runs | grep -c .; }
passed() { [ -n "$(bin_ld)" ] && [ "$(cat "$W/$1" 2>/dev/null)" = "$(basename "$(bin_ld)")" ]; }

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
  alive "$PIDF" && die "the ld chain is running -- 'status'"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/ld_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -x "$REF" ] && [ "$(md5sum < "$REF" | cut -c1-32)" = "$REF_MD5" ] || die "no reference $REF with md5 $REF_MD5"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  [ "$(strings -a "$CB/simulator/bin/champsim" | grep -c 'LOAD GEM5-RULE OWNER EVENTS')" -gt 0 ] || die "the new binary does not print the load-side counter"
  echo "== the three policy guards, in that tree"
  local g m
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_ld_$m.tmp" && mv -f "$S/bin/champsim_ld_$m.tmp" "$S/bin/champsim_ld_$m"
  rm -f "$W/Q0_PASSED" "$W/Q0M_PASSED" "$W/K0_PASSED" "$W/QC1A_PASSED" "$W/QC1B_PASSED"
  echo "$S/bin/champsim_ld_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_ld_$m"
}

# Q0: canneal_4t (no sync records), 1 M + 2 M, LRU and Hawkeye, both regimes,
# levels 0 and 2: every line the F-C binary prints, once the new lines are
# removed; the new lines present; no SYNC or MUTEX line.
q0() {
  local B Q="$W/q0" t="" i f pol rg lv c bad=0 n=0 g
  B=$(bin_ld); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  for i in 1 2 3 4; do
    f="$S/traces/canneal_4t/canneal$i.champsimtrace.xz"; [ -f "$f" ] || f="$S/traces/canneal_4t/canneal$i.champsimtrace"
    [ -f "$f" ] || die "no canneal_4t trace $i for Q0"
    t="$t $f"
  done
  echo "== Q0 (QC0): every line, against $(basename "$REF"), canneal 4c (no sync records), $QW + $QL, new lines removed"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$MC" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS -u COHERENCE_EVENT_LOG nice -n 19 "$REF" --config "$c" --warmup-instructions "$QW" --simulation-instructions "$QL" $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS -u COHERENCE_EVENT_LOG nice -n 19 "$B" --config "$c" --warmup-instructions "$QW" --simulation-instructions "$QL" $t > "$Q/${pol}_${rg}_${lv}_new.log" 2>&1 ) &
  done; done; done
  echo "   $(date +%T) 16 runs started (8 pairs); waiting"
  wait_runs "$Q" 16
  for f in "$Q"/*_ref.log; do
    n=$((n + 1)); g="${f%_ref.log}_new.log"
    grep -q "$DONE_MARKER" "$f" && grep -q "$DONE_MARKER" "$g" || { echo "   $(basename "${f%_ref.log}"): did not complete"; bad=$((bad + 1)); continue; }
    if grep -q -E "SYNC|MUTEX" "$g"; then echo "   $(basename "${f%_ref.log}"): a SYNC or MUTEX line"; bad=$((bad + 1)); continue; fi
    has_new "$g" || { echo "   $(basename "${f%_ref.log}"): the new lines are missing"; bad=$((bad + 1)); continue; }
    diff <(oldlines "$f") <(oldlines "$g") > /dev/null || { echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0 FAILED: $bad of $n pairs differ"; return 1; }
  echo "   Q0 holds: $n of $n pairs print every other line the same, with the new lines present"
  basename "$B" > "$W/Q0_PASSED"
}

# Q0m: synchronised traces with their F-C configs, 1 M + 2 M
q0m() {
  local B Q="$W/q0m" l s wu si tr bad=0 n=0 cfg
  B=$(bin_ld); [ -x "$B" ] || die "no binary yet"
  rm -rf "$Q"; mkdir -p "$Q"
  echo "== Q0m (QC0): the synchronised traces of $(echo "$Q0M" | cut -d'|' -f1 | tr '\n' ' '), F-C configs, against $(basename "$REF"), $QW + $QL"
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    s=$(log_settings "$S/results/$(pfield "$Q0M" "$l" 2)/regime_shared/$(pfield "$Q0M" "$l" 3)/lru/run.log") || die "Q0m: ${s#MISSING:}"
    read -r wu si tr <<< "$s"
    cfg=$(pfield "$Q0M" "$l" 4); [ -s "$cfg" ] || die "Q0m: no config $cfg"
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS -u COHERENCE_EVENT_LOG nice -n 19 "$REF" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && env -u COHERENCE_POSITION_BINS -u COHERENCE_EVENT_LOG nice -n 19 "$B" --config "$cfg" --warmup-instructions "$QW" --simulation-instructions "$QL" $tr > "$Q/${l}_new.log" 2>&1 ) &
  done
  wait_runs "$Q" $(( 2 * $(echo "$Q0M" | grep -c '|') ))
  for l in $(echo "$Q0M" | cut -d'|' -f1); do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$Q/${l}_ref.log" && grep -q "$DONE_MARKER" "$Q/${l}_new.log" || { echo "   $l: did not complete"; bad=$((bad + 1)); continue; }
    [ "$(grep -c '^SYNC LOCK WORD: request$' "$Q/${l}_new.log")" = 1 ] || { echo "   $l: not an F-C run (no request line)"; bad=$((bad + 1)); continue; }
    has_new "$Q/${l}_new.log" || { echo "   $l: the new lines are missing"; bad=$((bad + 1)); continue; }
    diff <(oldlines "$Q/${l}_ref.log") <(oldlines "$Q/${l}_new.log") > /dev/null || { echo "   DIFFERS: $l"; bad=$((bad + 1)); }
  done
  [ "$bad" = 0 ] || { echo "   Q0m FAILED: $bad of $n differ"; return 1; }
  echo "   Q0m holds: $n of $n print every other line the same, with the new lines present"
  basename "$B" > "$W/Q0M_PASSED"
}

# K0: the exact suite with both binaries, then their logs compared with the new lines removed
k0() {
  local B K="$W/k0" r f g n=0 bad=0 want
  B=$(bin_ld); [ -x "$B" ] || die "no binary yet"
  [ -f "$SUITE" ] && [ -f "$CB/bench/policy_sanity/coherence_exact_traces.py" ] || die "no exact suite in $CB/bench/policy_sanity"
  rm -rf "$K" "$K0TMP"; mkdir -p "$K" "$K0TMP" || die "cannot create $K0TMP"
  echo "== K0 (QC0): the exact suite, $(basename "$B") and $(basename "$REF") on every case, levels 0 1 2, $K0JOBS at a time each"
  ( BIN="$B" LOGDIR="$K0TMP/ld" JOBS="$K0JOBS" env -u COHERENCE_POSITION_BINS nice -n 19 bash "$SUITE" > "$K/suite_ld.txt" 2>&1 ) &
  ( BIN="$REF" LOGDIR="$K0TMP/fc" JOBS="$K0JOBS" env -u COHERENCE_POSITION_BINS nice -n 19 bash "$SUITE" > "$K/suite_fc.txt" 2>&1 ) &
  echo "   $(date +%T) both suites started; waiting"
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) logs written: new $(ls "$K0TMP"/ld/*.log 2>/dev/null | wc -l), F-C $(ls "$K0TMP"/fc/*.log 2>/dev/null | wc -l)"
  done
  wait
  for r in ld fc; do
    mkdir -p "$K/$r"; cp -p "$K0TMP/$r"/*.log "$K/$r/" 2>/dev/null
    echo "   suite, $r: $(grep -c '^ok ' "$K/suite_$r.txt") ok, $(grep -c '^FAIL ' "$K/suite_$r.txt") FAIL; $(tail -1 "$K/suite_$r.txt" | cut -c1-90)"
    grep -q '^PASS:' "$K/suite_$r.txt" || bad=$((bad + 1))
  done
  rm -rf "$K0TMP"
  want=$(grep -c '^ok ' "$K/suite_fc.txt")
  for f in "$K"/fc/*.log; do
    g="$K/ld/$(basename "$f")"; n=$((n + 1))
    [ -f "$g" ] || { echo "   no new-binary log for $(basename "$f")"; bad=$((bad + 1)); continue; }
    diff <(oldlines "$f" | sed "s#$K0TMP/fc/#DIR/#g") <(oldlines "$g" | sed "s#$K0TMP/ld/#DIR/#g") > /dev/null || { echo "   DIFFERS: $(basename "$f")"; bad=$((bad + 1)); }
  done
  [ "$n" -gt 0 ] && [ "$n" = "$(ls "$K"/ld/*.log 2>/dev/null | wc -l)" ] || { echo "   log counts differ: F-C $n, new $(ls "$K"/ld/*.log 2>/dev/null | wc -l)"; bad=$((bad + 1)); }
  [ "$bad" = 0 ] || { echo "   K0 FAILED ($bad; $K)"; return 1; }
  echo "   K0 holds: both suites PASS ($want cases x levels each); $n of $n logs equal line for line, the new lines removed"
  basename "$B" > "$W/K0_PASSED"
}

venv() {   # -> path of a python3 with numpy $NUMPY
  local v
  for v in $VENVS; do
    if "$v/bin/python3" -c "import numpy, sys; sys.exit(numpy.__version__ != '$NUMPY')" 2>/dev/null; then echo "$v"; return 0; fi
  done
  rm -rf "$W/venv"
  python3 -m venv "$W/venv" > /dev/null 2>&1 || return 1
  "$W/venv/bin/pip" install -q "numpy==$NUMPY" > "$W/pip.log" 2>&1 || return 1
  echo "$W/venv"
}

# QC1a: the micro harness on the new binary, level 2, 4 rounds, event logs kept; judged on the test lines
qc1a() {
  local B out="$W/micro_cs" v rc free
  B=$(bin_ld); [ -x "$B" ] || die "no binary yet"
  [ -f "$TRACER" ] && [ "$(md5sum < "$TRACER" | cut -c1-32)" = "$TRACER_MD5" ] || { echo "   QC1a: no tracer $TRACER with md5 $TRACER_MD5"; return 1; }
  [ -x "$PIN_ROOT/pin" ] || { echo "   QC1a: no Pin at $PIN_ROOT"; return 1; }
  for f in bench/micro_champsim.sh bench/micro_trim.py bench/coherence_micro.c bench/ld_micro_judge.py simulator/scripts/make_config.py; do
    [ -s "$CB/$f" ] || { echo "   QC1a: no $CB/$f -- scripts/ld_all.sh uploads it"; return 1; }
  done
  mkdir -p "$MTMP" || { echo "   QC1a: cannot create $MTMP"; return 1; }
  free=$(df -Pk "$MTMP" | awk 'NR == 2 { print int($4 / 1048576) }')
  [ "$free" -ge 30 ] || { echo "   QC1a: only $free GB free under $MTMP (want 30)"; return 1; }
  v=$(venv) || { echo "   QC1a: no python3 with numpy $NUMPY"; return 1; }
  rm -rf "$out"; mkdir -p "$out"
  echo "== QC1a: the micro harness, $(basename "$B"), 4 threads, level 2, 4 rounds, timed form; cases control $MCASES ($(date +%T))"
  PATH="$v/bin:$PATH" TMPDIR="$MTMP" NT=4 ACT0=0 LEVELS=2 ROUNDS=4 JOBS=6 KEEP_EVENTS=1 \
    BIN="$B" TRACER="$TRACER" PIN_ROOT="$PIN_ROOT" OUT="$out" \
    nice -n 19 bash "$CB/bench/micro_champsim.sh" "$MCASES" > "$W/qc1a_harness.log" 2>&1
  rc=$?
  rmdir "$MTMP" 2>/dev/null
  [ "$rc" = 0 ] || { tail -5 "$W/qc1a_harness.log"; echo "   QC1a FAILED: the harness exited $rc ($W/qc1a_harness.log)"; return 1; }
  "$PY" "$CB/bench/ld_micro_judge.py" cs "$out" | tee "$W/qc1a.txt" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "   QC1a FAILED"; return 1; }
  basename "$B" > "$W/QC1A_PASSED"
}

# QC1b: gem5 on the micro, 4 CPUs, ROUNDS 4 and 8 from one static binary (micro_server.sh's command line)
qc1b() {
  local GEM5 SE BUILD c r odir n=0 B
  B=$(bin_ld)
  BUILD="X86"; [ -f "$GEM5_DIR/.gem5_build_dir" ] && BUILD="$(cat "$GEM5_DIR/.gem5_build_dir")"
  GEM5="$GEM5_DIR/build/$BUILD/gem5.opt"; SE="$GEM5_DIR/configs/deprecated/example/se.py"
  [ -x "$GEM5" ] || { echo "   QC1b: no gem5 at $GEM5"; return 1; }
  [ "$(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null)" = MESI_Three_Level ] || { echo "   QC1b: gem5 is not the MESI_Three_Level build"; return 1; }
  mkdir -p "$G5W/gem5"
  if [ ! -x "$G5W/micro_m5" ]; then
    gcc -O2 -static -pthread -DM5OPS -o "$G5W/micro_m5" "$CB/bench/coherence_micro.c" || { echo "   QC1b: the static build failed"; return 1; }
    gcc -O2 -pthread -o "$G5W/micro_native" "$CB/bench/coherence_micro.c" || { echo "   QC1b: the native build failed"; return 1; }
  fi
  for c in $MCASES; do timeout 60 "$G5W/micro_native" "$c" 8 > /dev/null || { echo "   QC1b: $c fails natively"; return 1; }; done
  echo "== QC1b: gem5 on the micro, 4 CPUs, ROUNDS 4 and 8, one binary (md5 $(md5sum < "$G5W/micro_m5" | cut -c1-12)); $G5PAR at a time ($(date +%T))"
  for r in 4 8; do for c in $MCASES; do
    odir="$G5W/gem5/${c}_r$r"
    if [ -f "$odir/stats.txt" ] && grep -q "Exiting @ tick" "$odir/run.log" 2>/dev/null; then continue; fi
    while [ "$(jobs -rp | wc -l)" -ge "$G5PAR" ]; do sleep 20; done
    rm -rf "$odir"; mkdir -p "$odir"
    ( cd "$odir" && nice -n 19 "$GEM5" --outdir="$odir" "$SE" --ruby --num-cpus=4 --cpu-type=TimingSimpleCPU --mem-size=4GB \
        --l0i_size=32kB --l0i_assoc=8 --l0d_size=2kB --l0d_assoc=8 --l1d_size=8kB --l1d_assoc=8 \
        --l2_size=256kB --l2_assoc=16 --num-l2caches=1 --num-clusters=1 \
        -c "$G5W/micro_m5" --options="$c $r" < /dev/null > "$odir/run.log" 2>&1 ) &
    n=$((n + 1))
  done; done
  echo "   $(date +%T) $n gem5 runs started; waiting"
  wait
  "$PY" "$CB/bench/ld_micro_judge.py" g5 "$G5W/gem5" | tee "$W/qc1b.txt" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "   QC1b FAILED"; return 1; }
  basename "$B" > "$W/QC1B_PASSED"
}

one_run() {   # label
  local r="$1" B s wu si tr log cfg od ref rc
  B=$(bin_ld); log=$(new_log "$r"); cfg=$(rfield "$r" 4); od=$(new_dir "$r"); ref=$(ref_log "$r")
  if is_done "$r"; then echo "$(date '+%F %T') SKIP  $r (complete)"; return 0; fi
  s=$(log_settings "$ref") || { echo "$(date '+%F %T') FAIL  $r -- ${s#MISSING:}"; return 0; }
  [ -s "$cfg" ] || { echo "$(date '+%F %T') FAIL  $r -- no config $cfg"; return 0; }
  read -r wu si tr <<< "$s"
  mkdir -p "$od"
  { echo "binary $B $(md5sum < "$B" | cut -c1-32)"; echo "config $cfg $(md5sum < "$cfg" | cut -c1-32)"; echo "reference $ref"
    echo "warmup $wu simulation $si"; echo "traces $tr"; } > "$od/cmd.txt"
  echo "$(date '+%F %T') START $r ($wu + $si; $(echo $tr | wc -w) traces) -> $(rfield "$r" 5)"
  # shellcheck disable=SC2086
  ( cd "$S" && env -u COHERENCE_POSITION_BINS -u COHERENCE_EVENT_LOG nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" $tr > "$log" 2>&1 )
  rc=$?
  echo "$(date '+%F %T') END   $r rc=$rc $(grep -c "$DONE_MARKER" "$log") complete"
  qc2_one "$r" > "$od/qc2.txt"
  echo "$(date '+%F %T') QC2   $r: $(cat "$od/qc2.txt")"
}

qc2_one() {   # label -> one line
  local r="$1" log ref
  log=$(new_log "$r"); ref=$(ref_log "$r")
  grep -q "$DONE_MARKER" "$log" 2>/dev/null || { echo "not complete"; return; }
  has_new "$log" || { echo "FAILS: the new lines are missing"; return; }
  diff <(oldlines "$ref") <(oldlines "$log") > /dev/null || { echo "FAILS: differs from $ref apart from the new lines"; return; }
  echo "holds: every line of the reference; LLC LOAD owner events $(grep -m1 -E "^LLC COHERENCE DIR LOAD $NEWLINES:" "$log" | awk '{ print $NF }') (first block)"
}

qc2() {
  local r ok=0 bad=0 waiting=0 v
  for r in $(runs); do
    if ! is_done "$r"; then waiting=$((waiting + 1)); continue; fi
    v=$(qc2_one "$r")
    case "$v" in holds*) ok=$((ok + 1)) ;; *) bad=$((bad + 1)); echo "   QC2 FAILS: $r ($v)" ;; esac
  done
  echo "   QC2: $ok hold, $bad fail, $waiting not complete (of $(nruns))"
}

chain_drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') CHAIN START: $(nruns) load-side runs, $PAR at a time, $(basename "$(bin_ld)")"
  runs | xargs -P "$PAR" -I{} bash "$SELF" __run {}
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $(nruns) runs complete"
  qc2 | tee "$W/qc2.txt"
  rm -f "$PIDF"
}

case "${1:-}" in
  check)
    mkdir -p "$W"
    { if build && q0 && q0m && k0; then
        echo "QC0 PASSED: $(basename "$(bin_ld)"): Q0, Q0m and K0 hold. The runs may start ('chain', owner's word); QC1a and QC1b follow here."
        qc1a > "$W/qc1a_run.log" 2>&1 & a=$!
        qc1b > "$W/qc1b_run.log" 2>&1 & b=$!
        wait "$a"; ra=$?; wait "$b"; rb=$?
        cat "$W/qc1a_run.log" "$W/qc1b_run.log"
        if [ "$ra" = 0 ] && [ "$rb" = 0 ]; then
          echo "CHECK PASSED: $(basename "$(bin_ld)"): QC0, QC1a and QC1b hold."
        else
          echo "QC1 FAILED (QC1a rc $ra, QC1b rc $rb): nothing of C is scored until it is diagnosed"; false
        fi
      else false; fi; } 2>&1 | tee -p "$W/check_run.log"
    exit "${PIPESTATUS[0]}" ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the ld chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    B=$(bin_ld); [ -x "$B" ] || die "no binary yet -- 'check'"
    for q in Q0_PASSED Q0M_PASSED K0_PASSED; do passed "$q" || die "$(basename "$B") has not passed ${q%_PASSED} -- 'check'"; done
    [ -s "$RUNSF" ] || die "no $RUNSF -- scripts/ld_all.sh go uploads it"
    for r in $(runs); do
      s=$(log_settings "$(ref_log "$r")") || die "$r: ${s#MISSING:}"
      grep -q '^SYNC LOCK WORD: request$' "$(ref_log "$r")" || die "$r: the reference is not an F-C run"
      [ -s "$(rfield "$r" 4)" ] || die "$r: no config $(rfield "$r" 4)"
      "$PY" -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(0 if c.get("sync_lock_word") == "request" else 1)' "$(rfield "$r" 4)" \
        || die "$r: $(rfield "$r" 4) is not an F-C config"
      case "$(rfield "$r" 5)" in phaseA_b3_ld_*) ;; *) die "$r: the new tree must be phaseA_b3_ld_*" ;; esac
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
    echo "started: $(nruns) runs, $PAR at a time, then QC2; log $LOG" ;;
  __chain) chain_drive ;;
  __run) one_run "$2" ;;
  qc2) qc2 ;;
  status)
    pq() { passed "$1" && echo passed || echo 'not passed'; }
    echo "== ld (load side): binary $(basename "$(bin_ld)" 2>/dev/null); Q0 $(pq Q0_PASSED); Q0m $(pq Q0M_PASSED); K0 $(pq K0_PASSED); QC1a $(pq QC1A_PASSED); QC1b $(pq QC1B_PASSED); runs $(count_done) of $(nruns) complete; chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$W/check_run.log" ] && { echo "   -- check:"; tail -n 4 "$W/check_run.log" | sed 's/^/      /'; }
    [ -d "$G5W/gem5" ] && echo "   QC1b gem5 runs ended: $(grep -l 'Exiting @ tick' "$G5W"/gem5/*/run.log 2>/dev/null | wc -l) of $(ls -d "$G5W"/gem5/*/ 2>/dev/null | wc -l)"
    [ -f "$W/qc2.txt" ] && sed 's/^/   /' "$W/qc2.txt"
    [ -f "$LOG" ] && tail -n 4 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'ld_server.sh __chain' || die "pid $sid is not an ld_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2
      rm -f "$PIDF"; echo "stopped the ld chain (session $sid)"
    else
      echo "the ld chain is not running"
    fi ;;
  *) echo "usage: $0 check | chain | status | qc2 | stop"; exit 1 ;;
esac
