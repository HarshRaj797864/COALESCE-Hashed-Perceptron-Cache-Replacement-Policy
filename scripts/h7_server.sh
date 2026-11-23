#!/usr/bin/env bash
# H7: step 5 on the F-C binary (bench/policy_sanity/policy_rerun_design_2026-10-19.md,
# amendment 3; PLAN § 10 item 9). The 171 step 5 jobs (~/h7/JOBS, which must equal
# ~/sync_pol/JOBS byte for byte), each one g6 run of phaseA_b3_p2_* replayed again on
# the frozen F-C binary (~/sync_fc/BIN, champsim_fc_a2e88e46) with its own config
# (~/sync_pol/cfg/<suffix>_<regime>_<policy>.json) plus "sync_lock_word": "request"
# (nothing else), its window and its traces (its "CPU n runs" lines, by CPU).
# Output: results/phaseA_b3_p3_<suffix>/regime_<r>/<wl>_<n>core/<policy>/run.log
# (+ run.log.bin). Writes only under ~/h7 and those trees; reads the references,
# their configs and F-C's state; starts and stops nothing else.
#
#   bash ~/h7/h7_server.sh guards   # read-only apart from ~/h7
#   bash ~/h7/h7_server.sh chain    # detached: the 171 reruns, PAR at a time, in JOBS order
#   bash ~/h7/h7_server.sh status | list | stop
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "h7_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/h7}"
FC_W="${FC_W:-$HOME/sync_fc}"                       # F-C's state: BIN, Q0_PASSED, Q0M_PASSED, Q0R_PASSED, K0_PASSED
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
POL_W="${POL_W:-$HOME/sync_pol}"
JOBS_MD5="${JOBS_MD5:-ec5c7410ef205d94aac3c6e0cc649611}"
PAR="${PAR:-12}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"     # relaunch_2026-11-24.md: 5 GB (it writes logs only; was 20)
POLL_S="${POLL_S:-300}"
DONE_MARKER="ChampSim completed all CPUs"
REF_TREE=phaseA_b3_p2_
NEW_TREE=phaseA_b3_p3_
LOG="$W/driver.log"
PIDF="$W/.driver.pid"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }
cl() { echo "$(date '+%F %T') $*"; }
bin_fc() { cat "$FC_W/BIN" 2>/dev/null; }

# a JOBS line: suffix|wl|cores|scaled|warmup|sim|traces|policy|regime[|mshr]
f() { echo "$1" | cut -d'|' -f"$2"; }
lab() { echo "$(f "$1" 1) $(f "$1" 9) $(f "$1" 8)"; }
ref_log() { echo "$S/results/$REF_TREE$(f "$1" 1)/regime_$(f "$1" 9)/$(f "$1" 2)_$(f "$1" 3)core/$(f "$1" 8)/run.log"; }
new_log() { echo "$S/results/$NEW_TREE$(f "$1" 1)/regime_$(f "$1" 9)/$(f "$1" 2)_$(f "$1" 3)core/$(f "$1" 8)/run.log"; }
ref_cfg() { echo "$POL_W/cfg/$(f "$1" 1)_$(f "$1" 9)_$(f "$1" 8).json"; }
new_cfg() { echo "$W/cfg/$(f "$1" 1)_$(f "$1" 9)_$(f "$1" 8).json"; }
ref_done() { grep -q "$DONE_MARKER" "$(ref_log "$1")" 2>/dev/null; }
is_done() { local l; l=$(new_log "$1"); grep -q "$DONE_MARKER" "$l" 2>/dev/null && [ "$(cat "$l.bin" 2>/dev/null)" = "$(basename "$(bin_fc)")" ]; }
jobs_list() { if [ -n "${ONLY:-}" ]; then awk -F'|' -v o=" $ONLY " 'index(o, " " $1 " ")' "$W/JOBS"; else cat "$W/JOBS"; fi; }

guards() {
  local B; B=$(bin_fc)
  [ -n "$B" ] && [ -x "$B" ] || die "no F-C binary named in $FC_W/BIN"
  [ "$(md5sum < "$B" | cut -c1-32)" = "$FC_MD5" ] || die "$B is not md5 $FC_MD5"
  local m; for m in Q0_PASSED Q0M_PASSED Q0R_PASSED K0_PASSED; do [ -f "$FC_W/$m" ] || die "F-C's $m is missing in $FC_W"; done
  grep -qa 'SYNC LOCK WORD' "$B" || die "$B prints no SYNC LOCK WORD line"
  [ -s "$W/JOBS" ] || die "no $W/JOBS (h7_all.sh uploads it)"
  [ "$(md5sum < "$W/JOBS" | cut -c1-32)" = "$JOBS_MD5" ] || die "$W/JOBS is not md5 $JOBS_MD5 (policy_jobs.py's output)"
  cmp -s "$W/JOBS" "$POL_W/JOBS" || die "$W/JOBS differs from step 5's $POL_W/JOBS"
  [ "$(wc -l < "$W/JOBS")" = 171 ] || die "$W/JOBS has $(wc -l < "$W/JOBS") lines, not 171"
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  command -v python3 > /dev/null || die "no python3"
  local x n=0 nr=0 nc=0
  while read -r x; do
    n=$((n + 1))
    ref_done "$x" && nr=$((nr + 1))
    [ -s "$(ref_cfg "$x")" ] && nc=$((nc + 1))
  done < "$W/JOBS"
  [ "$nr" = "$n" ] || die "only $nr of $n step 5 references are complete"
  [ "$nc" = "$n" ] || die "only $nc of $n step 5 configs exist in $POL_W/cfg"
  echo "   guards: $(basename "$B") md5 ${FC_MD5:0:8}, F-C's Q0 / Q0m / Q0r / K0 passed; JOBS = step 5's (md5 ${JOBS_MD5:0:8}); $n references complete, $nc configs; $(free_gb) GB free"
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

rerun() {   # one JOBS line
  local x=$1 L ref log cfg wu si c B tr=() t
  L=$(lab "$x")
  if is_done "$x"; then cl "$L: complete already"; return 0; fi
  ref=$(ref_log "$x"); log=$(new_log "$x"); cfg=$(new_cfg "$x")
  ref_done "$x" || { cl "$L: FAILED -- reference not complete ($ref)"; return 1; }
  mkdir -p "$W/cfg" "$(dirname "$log")"
  make_cfg "$(ref_cfg "$x")" "$cfg" 2> "$cfg.err" || { cl "$L: FAILED -- config: $(tail -1 "$cfg.err")"; return 1; }
  rm -f "$cfg.err"
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  [ "$wu" = "$(f "$x" 5)" ] && [ "$si" = "$(f "$x" 6)" ] || { cl "$L: FAILED -- the reference's window ($wu + $si) is not the job's ($(f "$x" 5) + $(f "$x" 6))"; return 1; }
  c=$(f "$x" 3)
  mapfile -t tr < <(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$ref" | sort -n -k1,1 | awk '{ print $2 }')
  [ "${#tr[@]}" = "$c" ] || { cl "$L: FAILED -- $ref names ${#tr[@]} traces, not $c"; return 1; }
  for t in "${tr[@]}"; do [ -s "$t" ] || { cl "$L: FAILED -- no trace $t"; return 1; }; done
  B=$(bin_fc); rm -f "$log.bin"
  cl "$L: START on $(basename "$B"), window $wu + $si, $c traces"
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  local lw rq un
  lw=$(grep -c '^SYNC LOCK WORD: request$' "$log")
  rq=$(awk '/^CPU [0-9]+ LOCK-WORD REQUESTS:/ { m += $6; w += $8 } END { printf "%d measured, %d warm-up", m, w }' "$log")
  un=$(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')
  if grep -q "$DONE_MARKER" "$log"; then
    cl "$L: END rc=$rc complete; SYNC LOCK WORD lines $lw; lock-word requests $rq; unexplained view-order violations $un"
  else
    cl "$L: FAILED -- did not complete (rc=$rc; $(tail -1 "$log" | cut -c1-100))"; return 1
  fi
}

count_done() { local n=0 x; while read -r x; do is_done "$x" && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

chain_drive() {
  echo $$ > "$PIDF"
  cl "CHAIN START: $(jobs_list | wc -l) reruns, $PAR at a time, in JOBS order (16 cores first); binary $(basename "$(bin_fc)")"
  local x running=0
  while read -r x; do
    while [ "$running" -ge "$PAR" ]; do wait -n; running=$((running - 1)); done
    while [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; do cl "under $MIN_FREE_GB GB free: no rerun starts until there is room"; sleep "$POLL_S"; done
    rerun "$x" &
    running=$((running + 1))
  done < <(jobs_list)
  wait
  cl "CHAIN END: $(count_done) of $(jobs_list | wc -l) reruns complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  guards) mkdir -p "$W"; guards ;;
  list) while read -r x; do printf '%-26s %-8s %-11s %s\n' "$(f "$x" 1)" "$(f "$x" 9)" "$(f "$x" 8)" "$(is_done "$x" && echo 'rerun complete' || { [ -f "$(new_log "$x")" ] && echo 'started' || echo 'not started'; })"; done < <(jobs_list) ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the H7 chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END' && { echo "nothing left to do: $(tail -1 "$LOG")"; exit 0; }
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(jobs_list | wc -l) reruns, $PAR at a time; log $LOG" ;;
  __chain) chain_drive ;;
  status)
    nrun=$(pgrep -fc "[c]hampsim_fc_a2e88e46 --config $W/cfg/" || true)
    echo "== H7 (step 5 on F-C, amendment 3): $(count_done) of $(jobs_list 2>/dev/null | wc -l) reruns complete; $nrun running; chain $(alive "$PIDF" && echo alive || echo 'not running'); $(free_gb) GB free"
    [ -f "$LOG" ] && grep -E 'FAILED|END rc|CHAIN' "$LOG" | tail -n 8 | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'h7_server.sh __chain' || die "pid $sid is not an h7_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; pgrep -s "$sid" > /dev/null && pkill -KILL -s "$sid"
      rm -f "$PIDF"; echo "stopped the H7 chain (session $sid); $(date '+%F %T')" | tee -a "$LOG"
    else
      echo "the H7 chain is not running"
    fi ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
