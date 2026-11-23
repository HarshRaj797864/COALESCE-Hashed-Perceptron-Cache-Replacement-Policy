#!/usr/bin/env bash
# Part B on the F-C binary (bench/policy_sanity/breadth_bc_design_2026-11-10.md,
# amendment 10; F-C adopted 2026-11-14, lock_fix_results_2026-11-14.md).
#
# Each RERUN is one reference run on champsim_g6_1e3060c1 (Part B's keys,
# canneal at 16 cores from step 5, three 4-core points), replayed again on
# the frozen F-C binary (~/sync_fc/BIN, champsim_fc_a2e88e46) with the
# reference's own config plus "sync_lock_word": "request" (nothing else), its
# window (Warmup / Simulation Instructions) and its traces (its "CPU n runs"
# lines). A rerun waits until its reference has completed. Output:
# results/phaseA_b3_fc_<tag>_<suffix>/regime_shared/<wl>_<n>core/lru/run.log.
# Writes only under ~/partBfc and those trees; reads the references and their
# configs; starts and stops nothing else.
# Relaunch after the 22 Nov reboot (bench/policy_sanity/relaunch_2026-11-24.md): the disk guard is 5 GB
# (logs only); amendment 13: a rerun in EARLY (radix16) may start once its reference has STARTED (window
# lines in its log), its traces listed from Part B's sizing record as the trace runner lists them -- a
# rule QE-early (guards) checks against every completed 8- and 16-thread reference first.
#
#   bash ~/partBfc_server.sh guards   # read-only apart from ~/partBfc
#   bash ~/partBfc_server.sh chain    # detached: the 35 reruns, PAR at a time
#   bash ~/partBfc_server.sh status | stop | list
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "partBfc_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/partBfc}"
FC_W="${FC_W:-$HOME/sync_fc}"                       # F-C's state: BIN, Q0_PASSED, Q0M_PASSED, Q0R_PASSED, K0_PASSED
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
PB_W="${PB_W:-$HOME/sync_pb}"
POL_W="${POL_W:-$HOME/sync_pol}"
G6_W="${G6_W:-$HOME/sync_g6}"
NB_W="${NB_W:-$HOME/sync_nb}"
H2_W="${H2_W:-$HOME/sync_h2}"
PAR="${PAR:-8}"
WAIT_DAYS="${WAIT_DAYS:-14}"
WAIT_S="${WAIT_S:-$((WAIT_DAYS * 86400))}"
POLL_S="${POLL_S:-600}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
EARLY="${EARLY:-radix16}"            # amendment 13: reruns that may start once their reference has started
PBS_W="${PBS_W:-$HOME/partB}"        # Part B's sizing records (<key>/PROGS: field 6 threads traced, field 8 thread 0's cut)
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
PROGS14="ocean oceannc radix barnes lunc fft volrend waternsq raytrace fmm streamcluster fluidanimate vips bodytrack"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }
cl() { echo "$(date '+%F %T') $*"; }
bin_fc() { cat "$FC_W/BIN" 2>/dev/null; }

# label|reference tree|cores|reference config|F-C tree
reruns() {
  local p
  if [ -n "${ONLY:-}" ]; then reruns_all | awk -F'|' -v o=" $ONLY " 'index(o, " " $1 " ")'; else reruns_all; fi
}
reruns_all() {
  local p
  for p in fft volrend fmm; do echo "${p}4|phaseA_b3_b1_${p}4|4|$PB_W/cfg/${p}4_shared_lru.json|phaseA_b3_fc_b1_${p}4"; done
  for p in $PROGS14; do echo "${p}8|phaseA_b3_b2_${p}8|8|$PB_W/cfg/${p}8_shared_lru.json|phaseA_b3_fc_b2_${p}8"; done
  for p in $PROGS14; do echo "${p}16|phaseA_b3_b16_${p}16|16|$PB_W/cfg/${p}16_shared_lru.json|phaseA_b3_fc_b16_${p}16"; done
  echo "canneal16|phaseA_b3_p2_canneal16|16|$POL_W/cfg/canneal16_shared_lru.json|phaseA_b3_fc_p2_canneal16"
  echo "waternsq4|phaseA_b3_g3_waternsq4|4|$G6_W/cfg/waternsq4_shared_lru.json|phaseA_b3_fc_g3_waternsq4"
  echo "raytrace4|phaseA_b3_n2_raytrace4|4|$NB_W/cfg/raytrace4_shared_lru.json|phaseA_b3_fc_n2_raytrace4"
  echo "streamcluster4|phaseA_b3_h2_streamcluster4|4|$H2_W/cfg/streamcluster4_shared_lru.json|phaseA_b3_fc_h2_streamcluster4"
}
field() { echo "$1" | cut -d'|' -f"$2"; }
ref_log() { ls "$S/results/$(field "$1" 2)"/regime_shared/*_"$(field "$1" 3)"core/lru/run.log 2>/dev/null | head -1; }
ref_done() { local f; f=$(ref_log "$1"); [ -n "$f" ] && grep -q "$DONE_MARKER" "$f"; }
fc_log() { local f; f=$(ref_log "$1"); [ -n "$f" ] || return 1; echo "$S/results/$(field "$1" 5)/regime_shared/$(basename "$(dirname "$(dirname "$f")")")/lru/run.log"; }
is_done() { local f; f=$(fc_log "$1") || return 1; grep -q "$DONE_MARKER" "$f" 2>/dev/null && [ "$(cat "$f.bin" 2>/dev/null)" = "$(basename "$(bin_fc)")" ]; }
# amendment 13
is_early() { [[ " $EARLY " == *" $(field "$1" 1) "* ]]; }
key_of() { local l; l=$(field "$1" 1); echo "${l%%[0-9]*}_${l##*[!0-9]}"; }      # radix16 -> radix_16
ref_started() { local f; f=$(ref_log "$1"); [ -n "$f" ] && grep -q '^Warmup Instructions:' "$f" && grep -q '^Simulation Instructions:' "$f"; }
ref_ok() { ref_done "$1" || { is_early "$1" && ref_started "$1"; }; }
# a Part B key's traces in core order, as sync_server.sh's traces_for lists them (threads from PROGS field 6;
# thread 0 aligned unless the cut, field 8, is 0 or start0:*)
early_traces() {
  local k p tids cut0 t
  k=$(key_of "$1"); p="$PBS_W/$k/PROGS"
  [ -s "$p" ] || return 1
  tids=$(head -1 "$p" | cut -d'|' -f6); cut0=$(head -1 "$p" | cut -d'|' -f8)
  [ -n "$tids" ] || return 1
  for t in $tids; do
    case "${cut0:-0}" in 0|start0:*) echo "$S/traces/sync_pb/$k/raw$t.champsimtrace.xz" ;;
      *) if [ "$t" = 0 ]; then echo "$S/traces/sync_pb/$k/raw0_aligned.champsimtrace.xz"; else echo "$S/traces/sync_pb/$k/raw$t.champsimtrace.xz"; fi ;; esac
  done
}
ref_traces() { awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$(ref_log "$1")" | sort -n -k1,1 | awk '{ print $2 }'; }
# QE-early: the rule gives every completed 8- and 16-thread reference's own trace list, and each EARLY
# rerun's traces exist, one a core
qe_early() {
  local x n=0 bad=0 a b k
  [ -n "$EARLY" ] || { echo "   QE-early: no EARLY rerun"; return 0; }
  while read -r x; do
    case "$(field "$x" 2)" in phaseA_b3_b2_*|phaseA_b3_b16_*) ;; *) continue ;; esac
    ref_done "$x" || continue
    n=$((n + 1)); a=$(early_traces "$x" | tr '\n' ' '); b=$(ref_traces "$x" | tr '\n' ' ')
    [ -n "$a" ] && [ "$a" = "$b" ] || { bad=$((bad + 1)); echo "   QE-early: $(field "$x" 1): the rule lists [$a], its reference ran [$b]"; }
  done < <(reruns_all)
  [ "$bad" = 0 ] && [ "$n" -ge 10 ] || die "QE-early fails: $bad of $n completed references differ from the rule (at least 10 needed)"
  for k in $EARLY; do
    x=$(reruns_all | awk -F'|' -v k="$k" '$1 == k'); [ -n "$x" ] || die "EARLY names $k, which is no rerun"
    mapfile -t a < <(early_traces "$x"); [ "${#a[@]}" = "$(field "$x" 3)" ] || die "QE-early: $k lists ${#a[@]} traces, not $(field "$x" 3)"
    for b in "${a[@]}"; do [ -s "$b" ] || die "QE-early: $k: no trace $b"; done
  done
  echo "   QE-early holds: the rule equals the trace list of all $n completed 8- and 16-thread references; EARLY ($EARLY) traces exist"
}

guards() {
  local B; B=$(bin_fc)
  [ -n "$B" ] && [ -x "$B" ] || die "no F-C binary named in $FC_W/BIN"
  [ "$(md5sum < "$B" | cut -c1-32)" = "$FC_MD5" ] || die "$B is not md5 $FC_MD5"
  local m; for m in Q0_PASSED Q0M_PASSED Q0R_PASSED K0_PASSED; do [ -f "$FC_W/$m" ] || die "F-C's $m is missing in $FC_W"; done
  grep -qa 'SYNC LOCK WORD' "$B" || die "$B prints no SYNC LOCK WORD line"
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  command -v python3 > /dev/null || die "no python3"
  qe_early
  local n=0 d=0 x; while read -r x; do n=$((n + 1)); ref_done "$x" && d=$((d + 1)); done < <(reruns)
  echo "   guards: $(basename "$B") md5 ${FC_MD5:0:8}, F-C's Q0 / Q0m / Q0r / K0 passed; $n reruns, references complete now: $d; $(free_gb) GB free"
}

# the reference's config plus "sync_lock_word": "request", nothing else
make_cfg() {   # src dst
  python3 - "$1" "$2" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
if 'sync_lock_word' in c:
    sys.exit(f'{sys.argv[1]} already sets sync_lock_word')
n = dict(c, sync_lock_word='request')
assert {k: v for k, v in n.items() if k != 'sync_lock_word'} == c
json.dump(n, open(sys.argv[2], 'w'), indent=2)
PY
}

rerun() {   # one line of reruns
  local x=$1 lab ref cfg log wu si tr=() c B
  lab=$(field "$x" 1)
  if is_done "$x"; then cl "$lab: complete already"; return 0; fi
  ref=$(ref_log "$x"); cfg="$W/cfg/$lab.json"; log=$(fc_log "$x")
  [ -s "$(field "$x" 4)" ] || { cl "$lab: FAILED -- no reference config $(field "$x" 4)"; return 1; }
  mkdir -p "$W/cfg" "$(dirname "$log")"
  make_cfg "$(field "$x" 4)" "$cfg" 2> "$W/cfg/$lab.err" || { cl "$lab: FAILED -- config: $(tail -1 "$W/cfg/$lab.err")"; return 1; }
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  [ -n "$wu" ] && [ -n "$si" ] || { cl "$lab: FAILED -- no window in $ref"; return 1; }
  c=$(field "$x" 3)
  local how="reference $(field "$x" 2) complete"
  if ref_done "$x"; then
    mapfile -t tr < <(ref_traces "$x")
  elif is_early "$x" && ref_started "$x"; then   # amendment 13
    mapfile -t tr < <(early_traces "$x"); how="EARLY (amendment 13): reference $(field "$x" 2) started, not complete; traces from $(key_of "$x")'s sizing record"
  else
    cl "$lab: FAILED -- its reference is not complete"; return 1
  fi
  [ "${#tr[@]}" = "$c" ] || { cl "$lab: FAILED -- ${#tr[@]} traces, not $c"; return 1; }
  local t; for t in "${tr[@]}"; do [ -s "$t" ] || { cl "$lab: FAILED -- no trace $t"; return 1; }; done
  B=$(bin_fc); rm -f "$log.bin"
  cl "$lab: $how; START on $(basename "$B"), window $wu + $si, $c traces -> $(field "$x" 5)"
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  local lw un
  lw=$(grep -c '^SYNC LOCK WORD: request$' "$log"); un=$(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')
  if grep -q "$DONE_MARKER" "$log"; then
    cl "$lab: END rc=$rc complete; SYNC LOCK WORD request lines $lw; unexplained view-order violations $un"
  else
    cl "$lab: FAILED -- did not complete (rc=$rc; $(tail -1 "$log" | cut -c1-100))"; return 1
  fi
}

count_done() { local n=0 x; while read -r x; do is_done "$x" && n=$((n + 1)); done < <(reruns); echo "$n"; }

chain_drive() {
  echo $$ > "$PIDF"
  cl "CHAIN START: $(reruns | wc -l) reruns, $PAR at a time, each once its reference has completed (at most $((WAIT_S / 86400)) days); binary $(basename "$(bin_fc)")"
  local pending=() rest x t0
  mapfile -t pending < <(reruns)
  t0=$(date +%s)
  while [ "${#pending[@]}" -gt 0 ]; do
    rest=()
    for x in "${pending[@]}"; do
      if [ "$(jobs -rp | wc -l)" -lt "$PAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ] && { is_done "$x" || ref_ok "$x"; }; then
        rerun "$x" &
      else
        rest+=("$x")
      fi
    done
    pending=("${rest[@]}")
    [ "${#pending[@]}" -gt 0 ] || break
    if [ $(( $(date +%s) - t0 )) -ge "$WAIT_S" ]; then
      rest=()
      for x in "${pending[@]}"; do
        if ref_done "$x"; then rest+=("$x"); else cl "$(field "$x" 1): NOT RUN -- its reference ($(field "$x" 2)) did not complete in $((WAIT_S / 86400)) days"; fi
      done
      pending=("${rest[@]}")
      [ "${#pending[@]}" -gt 0 ] || break
    fi
    [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || cl "under $MIN_FREE_GB GB free: no rerun starts until there is room"
    sleep "$POLL_S"
  done
  wait
  cl "CHAIN END: $(count_done) of $(reruns | wc -l) reruns complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  guards) mkdir -p "$W"; guards ;;
  list) while read -r x; do printf '%-15s %-32s %s\n' "$(field "$x" 1)" "$(field "$x" 5)" "$(is_done "$x" && echo 'rerun complete' || { ref_done "$x" && echo 'reference complete' || echo 'reference not complete'; })"; done < <(reruns) ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the partBfc chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END' && { echo "nothing left to do: $(tail -1 "$LOG")"; exit 0; }
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(reruns | wc -l) reruns, $PAR at a time; log $LOG" ;;
  __chain) chain_drive ;;
  status)
    echo "== partBfc (Part B on the F-C binary, amendment 10): $(count_done) of $(reruns | wc -l) reruns complete; chain $(alive "$PIDF" && echo alive || echo 'not running'); $(free_gb) GB free"
    [ -f "$LOG" ] && grep -E 'FAILED|NOT RUN|END rc|CHAIN' "$LOG" | tail -n 10 | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'partBfc_server.sh __chain' || die "pid $sid is not a partBfc_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; pgrep -s "$sid" > /dev/null && pkill -KILL -s "$sid"
      rm -f "$PIDF"; echo "stopped the partBfc chain (session $sid); $(date '+%F %T')" | tee -a "$LOG"
    else
      echo "the partBfc chain is not running"
    fi ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
