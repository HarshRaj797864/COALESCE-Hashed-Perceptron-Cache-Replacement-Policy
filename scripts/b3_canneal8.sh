#!/usr/bin/env bash
# B3 at 8 cores: canneal_8t (threads 1-8, as every Phase A run) against gem5
# with 8 workers. Counts the window's instruction mix, runs ChampSim at levels
# 0, 1, 2 x shared, private, and starts gem5. Detached.
# Pre-registered in bench/policy_sanity/b3_canneal8_design_2026-10-14.md.
#
#   bash ~/b3_canneal8.sh go        # (scripts/checks_all.sh does this)
#   bash ~/b3_canneal8.sh status
#
# It runs the frozen binary and its own launcher: bin/champsim and
# run_phase_a.sh are not touched. A rerun skips what is done.
set -uo pipefail
SELF="$(readlink -f "$0")"   # the script re-invokes itself

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
BIN="${BIN:-$S/bin/champsim_b3v4_69ebdcce}"
W="${W:-$HOME/b3_canneal8}"
COUNT="${COUNT:-$HOME/count_rmw.py}"
GEM5_LAUNCH="${GEM5_LAUNCH:-$HOME/launch_b3_gem5.sh}"
WARMUP="${WARMUP:-50000000}"
SIM="${SIM:-100000000}"
N=8
LOG="$W/pipeline.log"
PIDF="$W/.pipeline.pid"
CS_PIDF="$W/.champsim.pid"
DONE_MARKER="ChampSim completed all CPUs"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
step() { echo; echo "=== $(date '+%F %T')  $* ==="; }
fail() { echo "STOPPED: $*"; rm -f "$PIDF"; exit 1; }

resolve_trace() {
  if [ -f "$1.champsimtrace" ]; then echo "$1.champsimtrace"; return 0; fi
  if [ -f "$1.champsimtrace.xz" ]; then echo "$1.champsimtrace.xz"; return 0; fi
  return 1
}
trace_records() {
  local f="$1" bytes
  case "$f" in
    *.xz) bytes=$(xz --robot -l "$f" 2>/dev/null | awk -F'\t' '$1=="totals"{print $5}') ;;
    *)    bytes=$(stat -c %s "$f" 2>/dev/null) ;;
  esac
  [ -n "$bytes" ] && echo $((bytes / 64)) || echo 0
}
traces() { local i out=""; for ((i = 1; i <= N; i++)); do out="$out $(resolve_trace "$S/traces/canneal_8t/canneal$i")" || return 1; done; echo "${out# }"; }
tree_of() { echo "phaseA_b3_e$1_canneal8"; }
run_log() { echo "$S/results/$(tree_of "$1")/regime_$2/canneal_8core/lru/run.log"; }
jobs_list() { local lv rg; for lv in 0 1 2; do for rg in shared private; do echo "$lv $rg"; done; done; }
cs_done() { local n=0 lv rg; while read -r lv rg; do grep -q "$DONE_MARKER" "$(run_log "$lv" "$rg")" 2>/dev/null && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

preflight() {
  step "1/4 preflight"
  local f n t need have
  for f in "$BIN" "$COUNT" "$GEM5_LAUNCH" "$HOME/run_gem5_splash.sh" "$S/scripts/make_config.py"; do [ -e "$f" ] || fail "missing $f"; done
  n=$(strings -a "$BIN" 2>/dev/null | grep -c 'PRIVATE-CACHE COHERENCE LEVEL')
  [ "${n:-0}" -gt 0 ] || fail "$BIN is not a B3 v4 build"
  [ "$(grep -c 'canneal8)' "$GEM5_LAUNCH")" -gt 0 ] || fail "$GEM5_LAUNCH has no canneal8 -- upload it first"
  [ "$(grep -c 'go-canneal-8c' "$HOME/run_gem5_splash.sh")" -gt 0 ] || fail "~/run_gem5_splash.sh has no go-canneal-8c -- upload it first"
  t=$(traces) || fail "a canneal_8t trace is missing"
  need=$(( (WARMUP + SIM) * 115 / 100 ))
  for f in $t; do
    have=$(trace_records "$f")
    [ "$have" -ge "$need" ] || fail "$(basename "$f") has $have records, the run needs $need with its margin"
  done
  echo "   $(basename "$BIN") md5 $(md5sum < "$BIN" | cut -c1-12); 8 traces of at least $need records"
}

mix() {
  step "2/4 the window's instruction mix (records $WARMUP to $((WARMUP + SIM)) of each thread)"
  local i f
  if [ -s "$W/trace_mix.txt" ] && [ "$(wc -l < "$W/trace_mix.txt")" = "$N" ]; then echo "   already counted -- skipped"; sed 's/^/   /' "$W/trace_mix.txt"; return 0; fi
  : > "$W/trace_mix.txt.tmp"
  for ((i = 1; i <= N; i++)); do
    f=$(resolve_trace "$S/traces/canneal_8t/canneal$i")
    ( case "$f" in *.xz) xz -dc "$f" ;; *) cat "$f" ;; esac | python3 "$COUNT" "$WARMUP" "$SIM" | sed "s/^/canneal_8t_t$i /" ) >> "$W/trace_mix.txt.tmp" &
  done
  wait
  LC_ALL=C sort "$W/trace_mix.txt.tmp" > "$W/trace_mix.txt" && rm -f "$W/trace_mix.txt.tmp"
  sed 's/^/   /' "$W/trace_mix.txt"
  [ "$(grep -c ' records ' "$W/trace_mix.txt")" = "$N" ] || fail "the mix file is short"
}

champsim_job() {   # level regime
  local lv="$1" rg="$2" log t
  log=$(run_log "$lv" "$rg"); t=$(traces)
  if grep -q "$DONE_MARKER" "$log" 2>/dev/null; then echo "$(date '+%F %T') SKIP  level $lv $rg (complete)"; return 0; fi
  mkdir -p "$(dirname "$log")"
  echo "$(date '+%F %T') START level $lv $rg"
  # shellcheck disable=SC2086 -- $t is the list of traces
  ( cd "$S" && nice -n 19 "$BIN" --config "$W/cfg_${rg}_l$lv.json" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" $t > "$log" 2>&1 )
  echo "$(date '+%F %T') END   level $lv $rg rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

champsim_driver() {
  echo $$ > "$CS_PIDF"
  echo "$(date '+%F %T') QUEUE START ($(jobs_list | wc -l) jobs, $(basename "$BIN"))"
  jobs_list | xargs -P 6 -L 1 bash "$SELF" __job
  echo "$(date '+%F %T') QUEUE END: $(cs_done) of $(jobs_list | wc -l) complete"
  rm -f "$CS_PIDF"
}

launch_champsim() {
  step "3/4 ChampSim: LRU, 8 cores, 2 MB, levels 0, 1, 2 x shared, private"
  local lv rg
  for lv in 0 1 2; do for rg in shared private; do
    "$S/scripts/make_config.py" --policy lru --cores 8 --regime "$rg" --private-coherence "$lv" -o "$W/cfg_${rg}_l$lv.json" > /dev/null 2>&1 \
      || fail "make_config.py failed for $rg, level $lv"
    [ "$(grep -c "\"private_coherence\": $lv" "$W/cfg_${rg}_l$lv.json")" = 1 ] || fail "the $rg level-$lv config does not carry the level"
  done; done
  if alive "$CS_PIDF"; then echo "   already running (pid $(cat "$CS_PIDF")) -- left alone"; return 0; fi
  setsid bash "$SELF" __champsim >> "$W/champsim.log" 2>&1 < /dev/null &
  disown 2>/dev/null
  sleep 3
  alive "$CS_PIDF" || [ "$(cs_done)" = 6 ] || fail "the ChampSim driver did not start ($W/champsim.log)"
  echo "   started ($(cs_done) of 6 already complete); log $W/champsim.log"
}

launch_gem5() {
  step "4/4 gem5: canneal with 8 workers, stops when a worker reaches 50 M and 150 M"
  WL=canneal8 bash "$GEM5_LAUNCH" go 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || fail "the gem5 launch failed"
}

case "${1:-}" in
  go)
    mkdir -p "$W"
    if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    setsid bash "$SELF" __pipeline > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    echo "started in the background; log: $LOG"; echo "check: bash $SELF status" ;;
  __pipeline)
    echo $$ > "$PIDF"
    preflight; mix; launch_champsim; launch_gem5
    rm -f "$PIDF"; echo; echo "=== $(date '+%F %T')  pipeline done -- ChampSim and gem5 continue in the background ===" ;;
  __champsim) champsim_driver ;;
  __job)      shift; champsim_job "$@" ;;
  status)
    if alive "$PIDF"; then echo "(pipeline still working)"; fi
    [ -f "$LOG" ] && sed 's/^/ /' "$LOG" || { echo "not started"; exit 0; }
    echo; echo " ChampSim runs complete: $(cs_done) of 6; driver $(alive "$CS_PIDF" && echo alive || echo 'not running')"
    [ -f "$W/champsim.log" ] && tail -3 "$W/champsim.log" | sed 's/^/    /'
    WL=canneal8 bash "$GEM5_LAUNCH" status 2>&1 | sed 's/^/ /' ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
