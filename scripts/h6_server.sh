#!/usr/bin/env bash
# H6(a) (bench/policy_sanity/h6_lockreq_design_2026-11-14.md): one records-only run of
# barnes std start on the F-C binary with COHERENCE_EVENT_LOG set, exactly as the F-C
# rerun ran (its config, window and traces); then QE0 against that rerun's log, the
# (ip, mutex line) pairs from the traces, the classification, and the event log
# compressed. Writes only under ~/h6.
#
#   bash ~/h6/h6_server.sh guards   # read-only apart from ~/h6
#   bash ~/h6/h6_server.sh go       # guards, then the run and the reading, DETACHED
#   bash ~/h6/h6_server.sh status
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "h6_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/h6}"
FC_W="${FC_W:-$HOME/sync_fc}"
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
CFG="${CFG:-$FC_W/cfg/barnesstd_start.json}"
CFG_MD5="${CFG_MD5:-3efd5110e5d7d96b11e9470439d60e29}"
REFD="${REFD:-$S/results/phaseA_b3_fc_g3_barnesstd4_start/regime_shared/barnes_4core/lru}"
ADDED="${ADDED:-24935}"                  # C_F-C - C_before: 51,773 - 26,838 (lock_fix_score_v1.txt)
PAIR_RECORDS="${PAIR_RECORDS:-45000000}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
DONE_MARKER="ChampSim completed all CPUs"
PIDF="$W/.pid"
LOG="$W/driver.log"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }
cl() { echo "$(date '+%F %T') $*"; }
bin_fc() { cat "$FC_W/BIN" 2>/dev/null; }
traces() { awk '$1 == "traces" { for (i = 2; i <= NF; i++) print $i }' "$REFD/cmd.txt"; }

guards() {
  local B; B=$(bin_fc)
  [ -n "$B" ] && [ -x "$B" ] || die "no F-C binary named in $FC_W/BIN"
  [ "$(md5sum < "$B" | cut -c1-32)" = "$FC_MD5" ] || die "$B is not md5 $FC_MD5"
  [ -s "$CFG" ] && [ "$(md5sum < "$CFG" | cut -c1-32)" = "$CFG_MD5" ] || die "$CFG is missing or not md5 $CFG_MD5"
  grep -q "$DONE_MARKER" "$REFD/run.log" 2>/dev/null || die "the F-C rerun's log $REFD/run.log is not complete"
  [ -s "$REFD/cmd.txt" ] || die "no $REFD/cmd.txt"
  grep -q "^binary .*champsim_fc_a2e88e46 $FC_MD5\$" "$REFD/cmd.txt" || die "$REFD/cmd.txt names another binary"
  grep -q "^config $CFG $CFG_MD5\$" "$REFD/cmd.txt" || die "$REFD/cmd.txt names another config"
  grep -q '^warmup 0 simulation 37900000$' "$REFD/cmd.txt" || die "$REFD/cmd.txt names another window"
  local t n=0; while read -r t; do [ -s "$t" ] || die "no trace $t"; n=$((n + 1)); done < <(traces)
  [ "$n" = 4 ] || die "$REFD/cmd.txt names $n traces, not 4"
  [ "$(awk '/^CPU [0-9]+ runs /' "$REFD/run.log" | wc -l)" = 4 ] || die "the reference log does not name 4 traces"
  local i=0; while read -r t; do grep -qx "CPU $i runs $t" "$REFD/run.log" || die "the reference log's CPU $i does not run $t"; i=$((i + 1)); done < <(traces)
  [ -f "$W/h6_lockreq.py" ] || die "no $W/h6_lockreq.py"
  python3 "$W/h6_lockreq.py" selftest > /dev/null 2>&1 || die "h6_lockreq.py's self-test fails here"
  command -v xz > /dev/null || die "no xz"
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  echo "   guards: $(basename "$B") md5 ${FC_MD5:0:8}; config md5 ${CFG_MD5:0:8}; the F-C rerun complete, its 4 traces present; self-test passes; $(free_gb) GB free"
}

drive() {
  echo $$ > "$PIDF"
  local B t=(); B=$(bin_fc); mapfile -t t < <(traces)
  cl "RUN START: $(basename "$B"), config $CFG, window 0 + 37900000, COHERENCE_EVENT_LOG=$W/events.log"
  rm -f "$W/events.log" "$W/events.log.xz" "$W/run.log" "$W/DONE"
  ( cd "$S" && COHERENCE_EVENT_LOG="$W/events.log" nice -n 19 "$B" --config "$CFG" --warmup-instructions 0 --simulation-instructions 37900000 "${t[@]}" > "$W/run.log" 2>&1 )
  local rc=$?
  grep -q "$DONE_MARKER" "$W/run.log" || { cl "RUN FAILED (rc=$rc): $(tail -1 "$W/run.log" | cut -c1-120)"; rm -f "$PIDF"; exit 1; }
  cl "RUN END rc=$rc complete; event log $(du -h "$W/events.log" | cut -f1), $(wc -l < "$W/events.log") lines"
  if python3 "$W/h6_lockreq.py" qe0 "$W/run.log" "$REFD/run.log" > "$W/qe0.txt" 2>&1; then
    cl "$(head -1 "$W/qe0.txt")"
    cl "PAIRS from the 4 traces (first $PAIR_RECORDS records each)"
    python3 "$W/h6_lockreq.py" pairs "${t[@]}" --max-records "$PAIR_RECORDS" > "$W/pairs.txt" 2> "$W/pairs.err" || { cl "PAIRS FAILED: $(tail -1 "$W/pairs.err")"; rm -f "$PIDF"; exit 1; }
    cl "$(tail -1 "$W/pairs.err")"
    python3 "$W/h6_lockreq.py" classify "$W/events.log" "$W/pairs.txt" "$W/run.log" "$ADDED" > "$W/summary.txt" 2>&1
    cl "CLASSIFY rc=$? -> $W/summary.txt"
  else
    cl "$(head -1 "$W/qe0.txt") -- the event log is not read (the note)"
  fi
  nice -n 19 xz -T2 -f "$W/events.log" && cl "event log compressed: $(du -h "$W/events.log.xz" | cut -f1)"
  date '+%F %T' > "$W/DONE"
  cl "END"
  rm -f "$PIDF"
}

case "${1:-}" in
  guards) mkdir -p "$W"; guards ;;
  go)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the H6 run is running already (pid $(cat "$PIDF"))"; exit 0; }
    [ -f "$W/DONE" ] && { echo "H6 is done already ($(cat "$W/DONE")); remove $W/DONE to run it again"; exit 0; }
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __drive >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$PIDF" || tail -n +$((n0 + 1)) "$LOG" | grep -q 'RUN START' || { tail -5 "$LOG"; die "the run did not start (above; $LOG)"; }
    echo "started: one run, then QE0, the pairs and the classes; log $LOG" ;;
  __drive) drive ;;
  status)
    echo "== H6(a): $( [ -f "$W/DONE" ] && echo "done $(cat "$W/DONE")" || { alive "$PIDF" && echo running || echo 'not running'; })"
    [ -f "$LOG" ] && tail -n 6 "$LOG" | sed 's/^/   /'
    [ -f "$W/run.log" ] && ! [ -f "$W/DONE" ] && echo "   last heartbeat: $(grep '^Heartbeat' "$W/run.log" | tail -1 | cut -c1-110)"
    exit 0 ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
