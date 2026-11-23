#!/usr/bin/env bash
# C0f (bench/policy_sanity/c0f_latency_final_design_2026-11-23.md): the invalidation latency on the
# final binary. Step 5's 27 fixed-2 MB shared jobs (~/c0f/JOBS: canneal4, canneal8, ocean4; each a
# line of ~/sync_pol/JOBS), each replayed on the frozen F-C binary (~/sync_fc/BIN, champsim_fc_a2e88e46)
# twice: L = 0 with its step 5 config plus "sync_lock_word": "request" (= H7's config), and L = 100 with
# "coherence_latency": 100 as well; its window and traces are its step 5 reference's.
# Amendment 1 (relaunch_2026-11-24.md): L = 0 is RUN only for the policies in L0_SET (default lru: one
# control a configuration, which QF0 holds equal to H7's p3 log); the other L = 0 rows are H7's p3 runs
# (same binary, same config: every L = 0 config is still written at chain start, and the scorer checks it
# against H7's). L0_SET=all runs all 54, as first registered. The disk guard is 5 GB (logs only).
# Output: results/phaseA_b3_c0f<L>_<suffix>/regime_shared/<wl>_<n>core/<policy>/run.log (+ run.log.bin).
# Writes only under ~/c0f and those trees; reads the references, their configs and F-C's state.
#
#   bash ~/c0f/c0f_server.sh guards   # read-only apart from ~/c0f
#   bash ~/c0f/c0f_server.sh chain    # detached: 27 at L = 100 + the L0_SET controls (3), PAR at a time, 8-core jobs first
#   bash ~/c0f/c0f_server.sh status | list | stop
set -uo pipefail
SELF="$(readlink -f "$0")"
trap 'rc=$?; [ "$rc" = 0 ] || echo "c0f_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/c0f}"
FC_W="${FC_W:-$HOME/sync_fc}"
FC_MD5="${FC_MD5:-a2e88e46788e1f332427567a19bc2f90}"
POL_W="${POL_W:-$HOME/sync_pol}"
JOBS_MD5="${JOBS_MD5:-96258bb9d909c9ec72670189e9295d85}"
NJOBS=27
LATS="100 0"
PAR="${PAR:-8}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
L0_SET="${L0_SET:-lru}"                    # amendment 1: the policies run at L = 0 (all = every one)
POLL_S="${POLL_S:-300}"
DONE_MARKER="ChampSim completed all CPUs"
REF_TREE=phaseA_b3_p2_
LOG="$W/driver.log"
PIDF="$W/.driver.pid"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
free_gb() { df -BG --output=avail "$S" | tail -1 | tr -dc 0-9; }
cl() { echo "$(date '+%F %T') $*"; }
bin_fc() { cat "$FC_W/BIN" 2>/dev/null; }

# a JOBS line: suffix|wl|cores|scaled|warmup|sim|traces|policy|regime[|mshr]; an item: L|JOBS line
f() { echo "$1" | cut -d'|' -f"$2"; }
lab() { echo "L=$1 $(f "$2" 1) $(f "$2" 9) $(f "$2" 8)"; }
ref_log() { echo "$S/results/$REF_TREE$(f "$1" 1)/regime_$(f "$1" 9)/$(f "$1" 2)_$(f "$1" 3)core/$(f "$1" 8)/run.log"; }
new_log() { echo "$S/results/phaseA_b3_c0f$1_$(f "$2" 1)/regime_$(f "$2" 9)/$(f "$2" 2)_$(f "$2" 3)core/$(f "$2" 8)/run.log"; }
ref_cfg() { echo "$POL_W/cfg/$(f "$1" 1)_$(f "$1" 9)_$(f "$1" 8).json"; }
new_cfg() { echo "$W/cfg/L$1_$(f "$2" 1)_$(f "$2" 9)_$(f "$2" 8).json"; }
ref_done() { grep -q "$DONE_MARKER" "$(ref_log "$1")" 2>/dev/null; }
is_done() { local l; l=$(new_log "$1" "$2"); grep -q "$DONE_MARKER" "$l" 2>/dev/null && [ "$(cat "$l.bin" 2>/dev/null)" = "$(basename "$(bin_fc)")" ]; }
# the items, 8-core jobs first (then JOBS order), each job at L = 100 and then L = 0
items() { awk -F'|' '{ print ($3 == 8 ? 0 : 1) "\t" NR "\t" $0 }' "$W/JOBS" | sort -t$'\t' -k1,1n -k2,2n | cut -f3- \
          | while IFS= read -r x; do for L in $LATS; do l0_runs "$L" "$x" && echo "$L|$x"; done; done; }
# amendment 1: an L = 0 item runs only for a policy in L0_SET
l0_runs() { [ "$1" != 0 ] || [ "$L0_SET" = all ] || [[ " $L0_SET " == *" $(f "$2" 8) "* ]]; }
# amendment 1: every L = 0 config written (none run here unless in L0_SET), for the scorer's check against H7's
write_l0_cfgs() {
  local x n=0; mkdir -p "$W/cfg"
  while IFS= read -r x; do
    make_cfg "$(ref_cfg "$x")" "$(new_cfg 0 "$x")" 0 2> "$W/cfg/l0.err" || { cl "FAILED -- L = 0 config of $(f "$x" 1) $(f "$x" 8): $(tail -1 "$W/cfg/l0.err")"; return 1; }
    n=$((n + 1))
  done < "$W/JOBS"
  rm -f "$W/cfg/l0.err"; cl "wrote $n L = 0 configs (amendment 1: run only for L0_SET = $L0_SET; the rest are H7's p3 runs)"
}

guards() {
  local B; B=$(bin_fc)
  [ -n "$B" ] && [ -x "$B" ] || die "no F-C binary named in $FC_W/BIN"
  [ "$(md5sum < "$B" | cut -c1-32)" = "$FC_MD5" ] || die "$B is not md5 $FC_MD5"
  local m; for m in Q0_PASSED Q0M_PASSED Q0R_PASSED K0_PASSED; do [ -f "$FC_W/$m" ] || die "F-C's $m is missing in $FC_W"; done
  grep -qa 'SYNC LOCK WORD' "$B" || die "$B prints no SYNC LOCK WORD line"
  grep -qa 'COHERENCE INVALIDATION LATENCY' "$B" || die "$B has no coherence latency line"
  [ -s "$W/JOBS" ] || die "no $W/JOBS (c0f_all.sh uploads it)"
  [ "$(md5sum < "$W/JOBS" | cut -c1-32)" = "$JOBS_MD5" ] || die "$W/JOBS is not md5 $JOBS_MD5"
  [ "$(wc -l < "$W/JOBS")" = "$NJOBS" ] || die "$W/JOBS has $(wc -l < "$W/JOBS") lines, not $NJOBS"
  local x n=0 nr=0 nc=0 ns=0
  while IFS= read -r x; do
    n=$((n + 1))
    grep -Fxq -- "$x" "$POL_W/JOBS" && ns=$((ns + 1))
    ref_done "$x" && nr=$((nr + 1))
    [ -s "$(ref_cfg "$x")" ] && nc=$((nc + 1))
  done < "$W/JOBS"
  [ "$ns" = "$n" ] || die "only $ns of $n lines are step 5's ($POL_W/JOBS)"
  [ "$nr" = "$n" ] || die "only $nr of $n step 5 references are complete"
  [ "$nc" = "$n" ] || die "only $nc of $n step 5 configs exist in $POL_W/cfg"
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || die "under $MIN_FREE_GB GB free ($(free_gb))"
  command -v python3 > /dev/null || die "no python3"
  echo "   guards: $(basename "$B") md5 ${FC_MD5:0:8}, F-C's Q0 / Q0m / Q0r / K0 passed, latency line present; JOBS md5 ${JOBS_MD5:0:8}, $n lines, all step 5's; $nr references complete, $nc configs; $(free_gb) GB free"
}

# the reference's config plus "sync_lock_word": "request" (H7's config), plus "coherence_latency": L at L > 0
make_cfg() {   # src dst L
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
L = int(sys.argv[3])
for k in ('sync_lock_word', 'coherence_latency'):
    if k in c:
        sys.exit(f'{sys.argv[1]} already sets {k}')
if c.get('private_coherence') != 2 and L > 0:
    sys.exit(f'{sys.argv[1]}: coherence_latency needs private_coherence 2')
n = dict(c, sync_lock_word='request')
if L > 0:
    n['coherence_latency'] = L
assert {k: v for k, v in n.items() if k not in ('sync_lock_word', 'coherence_latency')} == c
json.dump(n, open(sys.argv[2], 'w'), indent=2)
PY
}

rerun() {   # one item: L|JOBS line
  local it=$1 L x lb ref log cfg wu si c B tr=() t
  L=${it%%|*}; x=${it#*|}
  lb=$(lab "$L" "$x")
  if is_done "$L" "$x"; then cl "$lb: complete already"; return 0; fi
  ref=$(ref_log "$x"); log=$(new_log "$L" "$x"); cfg=$(new_cfg "$L" "$x")
  ref_done "$x" || { cl "$lb: FAILED -- reference not complete ($ref)"; return 1; }
  mkdir -p "$W/cfg" "$(dirname "$log")"
  make_cfg "$(ref_cfg "$x")" "$cfg" "$L" 2> "$cfg.err" || { cl "$lb: FAILED -- config: $(tail -1 "$cfg.err")"; return 1; }
  rm -f "$cfg.err"
  wu=$(awk '/^Warmup Instructions:/ { print $3; exit }' "$ref"); si=$(awk '/^Simulation Instructions:/ { print $3; exit }' "$ref")
  [ "$wu" = "$(f "$x" 5)" ] && [ "$si" = "$(f "$x" 6)" ] || { cl "$lb: FAILED -- the reference's window ($wu + $si) is not the job's ($(f "$x" 5) + $(f "$x" 6))"; return 1; }
  c=$(f "$x" 3)
  mapfile -t tr < <(awk '/^CPU [0-9]+ runs / { print $2, $4 }' "$ref" | sort -n -k1,1 | awk '{ print $2 }')
  [ "${#tr[@]}" = "$c" ] || { cl "$lb: FAILED -- $ref names ${#tr[@]} traces, not $c"; return 1; }
  for t in "${tr[@]}"; do [ -s "$t" ] || { cl "$lb: FAILED -- no trace $t"; return 1; }; done
  B=$(bin_fc); rm -f "$log.bin"
  cl "$lb: START on $(basename "$B"), window $wu + $si, $c traces"
  ( cd "$S" && nice -n 19 "$B" --config "$cfg" --warmup-instructions "$wu" --simulation-instructions "$si" "${tr[@]}" > "$log" 2>&1 )
  local rc=$?
  basename "$B" > "$log.bin"
  local lat waits un
  lat=$(awk -F': ' '/^COHERENCE INVALIDATION LATENCY \(CYCLES\):/ { print $2; exit }' "$log")
  waits=$(awk '/ COHERENCE LATENCY WAITS:/ { s += $NF } END { print s + 0 }' "$log")
  un=$(grep -E '^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:' "$log" | awk '{ s += $NF } END { print s + 0 }')
  if grep -q "$DONE_MARKER" "$log"; then
    cl "$lb: END rc=$rc complete; latency line ${lat:-none}; latency waits $waits; unexplained view-order violations $un"
  else
    cl "$lb: FAILED -- did not complete (rc=$rc; $(tail -1 "$log" | cut -c1-100))"; return 1
  fi
}

count_done() { local n=0 it; while IFS= read -r it; do is_done "${it%%|*}" "${it#*|}" && n=$((n + 1)); done < <(items); echo "$n"; }

chain_drive() {
  echo $$ > "$PIDF"
  cl "CHAIN START: $(items | wc -l) runs (L = 100 for all, L = 0 for $L0_SET), $PAR at a time, 8-core jobs first; binary $(basename "$(bin_fc)")"
  write_l0_cfgs || { rm -f "$PIDF"; return 1; }
  local it running=0
  while IFS= read -r it; do
    while [ "$running" -ge "$PAR" ]; do wait -n; running=$((running - 1)); done
    while [ "$(free_gb)" -lt "$MIN_FREE_GB" ]; do cl "under $MIN_FREE_GB GB free: no run starts until there is room"; sleep "$POLL_S"; done
    rerun "$it" &
    running=$((running + 1))
  done < <(items)
  wait
  cl "CHAIN END: $(count_done) of $(items | wc -l) runs complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  guards) mkdir -p "$W"; guards ;;
  list) while IFS= read -r it; do L=${it%%|*}; x=${it#*|}
          printf 'L=%-4s %-12s %-8s %-11s %s\n' "$L" "$(f "$x" 1)" "$(f "$x" 9)" "$(f "$x" 8)" "$(is_done "$L" "$x" && echo 'complete' || { [ -f "$(new_log "$L" "$x")" ] && echo 'started' || echo 'not started'; })"
        done < <(items) ;;
  chain)
    mkdir -p "$W"
    alive "$PIDF" && { echo "the C0f chain is running already (pid $(cat "$PIDF"))"; exit 0; }
    guards
    n0=0; [ -f "$LOG" ] && n0=$(wc -l < "$LOG")
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then
      tail -n +$((n0 + 1)) "$LOG" | grep -q 'CHAIN END' && { echo "nothing left to do: $(tail -1 "$LOG")"; exit 0; }
      tail -5 "$LOG"; die "the chain stopped (above; $LOG)"
    fi
    echo "started: $(items | wc -l) runs, $PAR at a time; log $LOG" ;;
  __chain) chain_drive ;;
  status)
    nrun=$(pgrep -fc "[c]hampsim_fc_a2e88e46 --config $W/cfg/" || true)
    echo "== C0f (latency on the final binary): $(count_done) of $(items 2>/dev/null | wc -l) runs complete; $nrun running; chain $(alive "$PIDF" && echo alive || echo 'not running'); $(free_gb) GB free"
    [ -f "$LOG" ] && grep -E 'FAILED|END rc|CHAIN' "$LOG" | tail -n 8 | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'c0f_server.sh __chain' || die "pid $sid is not a c0f_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; pgrep -s "$sid" > /dev/null && pkill -KILL -s "$sid"
      rm -f "$PIDF"; echo "stopped the C0f chain (session $sid); $(date '+%F %T')" | tee -a "$LOG"
    else
      echo "the C0f chain is not running"
    fi ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
