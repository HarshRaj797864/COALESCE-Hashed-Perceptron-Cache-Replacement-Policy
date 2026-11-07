#!/usr/bin/env bash
# A6: the LLC-size sweep in both regimes, canneal at 4 and 8 cores, the 8
# baselines, level 2, on the frozen B3 v4 binary. Its own queue: bin/champsim
# and run_phase_a.sh are not touched, so it runs beside any other sweep.
# Pre-registered in bench/policy_sanity/a6_size_sweep_design_2026-10-14.md.
#
#   bash ~/a6_sweep.sh plan             # what would run, preflight, estimate
#   bash ~/a6_sweep.sh go               # start (detached); a rerun skips what is done
#   bash ~/a6_sweep.sh status
#   bash ~/a6_sweep.sh install-resume   # @reboot: resume after a reboot
#
# Jobs, in order: Q0 (hawkeye and srrip_bias, 4c private, 2 and 8 MB: do the
# older private rows stand in for this binary?), then the 8-core sizes, then
# the 4-core sizes. Results: results/phaseA_l2_a6_<total>mb/regime_<rg>/
# canneal_<n>core/<pol>/run.log, which run_phase_a.sh rows and b3_rows.sh read
# as they are.
set -uo pipefail
SELF="$(readlink -f "$0")"   # the script re-invokes itself after changing directory

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
BIN="${BIN:-$S/bin/champsim_b3v4_69ebdcce}"
W="${W:-$HOME/a6}"
JOBS="${JOBS:-10}"
WARMUP="${WARMUP:-50000000}"
SIM="${SIM:-100000000}"
LEVEL="${LEVEL:-2}"
POLICIES="${POLICIES:-lru random srrip drrip ship hawkeye mockingjay srrip_bias}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
# cores | total LLC sizes in MB that are new (the design's table)
SIZES="${SIZES:-8|1 4 8 32
4|1 4 16}"
Q0="${Q0:-hawkeye|4|private|2
hawkeye|4|private|8
srrip_bias|4|private|2
srrip_bias|4|private|8}"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }

tree_of() { echo "phaseA_l2_a6_$1mb"; }                                   # total MB
run_log() { echo "$S/results/$(tree_of "$4")/regime_$3/canneal_$2core/$1/run.log"; }   # pol cores regime mb
is_done() { grep -q "$DONE_MARKER" "$(run_log "$@")" 2>/dev/null; }

jobs_list() {   # pol|cores|regime|mb
  echo "$Q0"
  local n sizes mb p rg
  while IFS='|' read -r n sizes; do
    for mb in $sizes; do for rg in shared private; do for p in $POLICIES; do echo "$p|$n|$rg|$mb"; done; done; done
  done <<< "$SIZES"
}

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
# canneal threads 1..n (thread 0 loads the netlist), as every Phase A run
traces_for() {
  local n="$1" i f out=""
  for ((i = 1; i <= n; i++)); do
    f=$(resolve_trace "$S/traces/canneal_${n}t/canneal$i") || { echo "MISSING:canneal_${n}t/canneal$i"; return 1; }
    out="$out $f"
  done
  echo "${out# }"
}

per_core_mb() { awk -v t="$1" -v n="$2" 'BEGIN { printf "%g", t / n }'; }
cfg_of() { echo "$W/cfg/$1_$2c_$3_$4mb.json"; }

make_cfg() {   # pol cores regime mb
  local c; c=$(cfg_of "$@"); mkdir -p "$(dirname "$c")"
  "$S/scripts/make_config.py" --policy "$1" --cores "$2" --regime "$3" --llc-per-core-mb "$(per_core_mb "$4" "$2")" \
    --private-coherence "$LEVEL" -o "$c" > /dev/null 2>&1 || return 1
  # the config must carry the size and the level asked for
  python3 - "$c" "$4" "$LEVEL" <<'EOF' || return 1
import json, sys
c = json.load(open(sys.argv[1])); mb = float(sys.argv[2]); lv = int(sys.argv[3])
llc = c["LLC"]
size = llc["sets"] * llc["ways"] * 64 / 1048576
sys.exit(0 if abs(size - mb) < 1e-9 and c.get("private_coherence") == lv else 1)
EOF
}

preflight() {
  local n sizes f t need have bad=0
  [ -x "$BIN" ] || die "no $BIN"
  n=$(strings -a "$BIN" 2>/dev/null | grep -c 'PRIVATE-CACHE COHERENCE LEVEL')
  [ "${n:-0}" -gt 0 ] || die "$BIN is not a B3 v4 build"
  need=$(( (WARMUP + SIM) * 115 / 100 ))
  for n in $(jobs_list | cut -d'|' -f2 | sort -u); do
    t=$(traces_for "$n") || die "${t#MISSING:}"
    for f in $t; do
      have=$(trace_records "$f")
      [ "$have" -ge "$need" ] || { echo "   SHORT: $(basename "$f") has $have records, needs $need"; bad=$((bad + 1)); }
    done
  done
  [ "$bad" = 0 ] || die "$bad trace(s) too short"
  # every configuration must be makeable before anything starts
  while IFS='|' read -r p n rg mb; do
    make_cfg "$p" "$n" "$rg" "$mb" || die "make_config.py could not make $p ${n}c $rg ${mb} MB at level $LEVEL"
  done < <(jobs_list)
}

job() {   # pol cores regime mb
  local p="$1" n="$2" rg="$3" mb="$4" log t
  log=$(run_log "$p" "$n" "$rg" "$mb")
  if is_done "$p" "$n" "$rg" "$mb"; then echo "$(date '+%F %T') SKIP  $p ${n}c $rg ${mb}MB (complete)"; return 0; fi
  t=$(traces_for "$n") || { echo "$(date '+%F %T') FAIL  $p ${n}c $rg ${mb}MB -- ${t#MISSING:}"; return 0; }
  make_cfg "$p" "$n" "$rg" "$mb" || { echo "$(date '+%F %T') FAIL  $p ${n}c $rg ${mb}MB -- config"; return 0; }
  mkdir -p "$(dirname "$log")"
  echo "$(date '+%F %T') START $p ${n}c $rg ${mb}MB"
  local started; started=$(date +%s)
  # shellcheck disable=SC2086 -- $t is a list of trace files
  ( cd "$S" && nice -n 19 "$BIN" --config "$(cfg_of "$p" "$n" "$rg" "$mb")" \
      --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" $t > "$log" 2>&1 )
  local rc=$?
  echo "$(date '+%F %T') END   $p ${n}c $rg ${mb}MB rc=$rc $(grep -c "$DONE_MARKER" "$log") complete, $(( ($(date +%s) - started) / 60 ))m"
}

count_done() { local n=0 p c rg mb; while IFS='|' read -r p c rg mb; do is_done "$p" "$c" "$rg" "$mb" && n=$((n + 1)); done < <(jobs_list); echo "$n"; }

driver() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') QUEUE START ($(jobs_list | wc -l) jobs, $(count_done) already complete, $JOBS at a time, $(basename "$BIN"), level $LEVEL)"
  jobs_list | tr '|' ' ' | xargs -P "$JOBS" -L 1 bash "$SELF" __job
  echo "$(date '+%F %T') QUEUE END: $(count_done) of $(jobs_list | wc -l) complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  plan)
    mkdir -p "$W"
    echo "== A6, the LLC-size sweep =="
    echo "   binary $(basename "$BIN") (md5 $(md5sum < "$BIN" | cut -c1-12)), level $LEVEL, $WARMUP + $SIM per core, $JOBS at a time"
    preflight
    echo "   preflight: binary, traces (with a 15% margin) and every config OK"
    total=$(jobs_list | wc -l); done_n=$(count_done)
    hours=$(jobs_list | while IFS='|' read -r p n rg mb; do is_done "$p" "$n" "$rg" "$mb" || echo "$n"; done | awk '{ h += ($1 == 8 ? 6 : 3) } END { print h + 0 }')
    echo "   jobs: $total ($done_n complete); to run: about $hours CPU-hours, ~$(( (hours + JOBS - 1) / JOBS )) h at $JOBS at a time"
    jobs_list | awk -F'|' '{ k = $2 "c " $3; n[k]++; s[k] = s[k] " " $4 } END { for (k in n) printf "   %-12s %d jobs\n", k, n[k] }' | sort
    echo "   disk free under results: $(df --output=avail -BG "$S/results" | tail -1 | tr -dc '0-9') GB" ;;
  go)
    mkdir -p "$W"
    if alive "$PIDF"; then echo "the sweep is already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    preflight
    setsid bash "$SELF" __driver >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    sleep 3
    alive "$PIDF" || [ "$(count_done)" = "$(jobs_list | wc -l)" ] || die "the driver did not start ($LOG)"
    echo "started: $(jobs_list | wc -l) jobs, $(count_done) already complete, $JOBS at a time; log $LOG"
    echo "check: bash $0 status" ;;
  __driver) driver ;;
  __job)    shift; job "$@" ;;
  status)
    echo "== A6: $(count_done) of $(jobs_list | wc -l) complete; driver $(alive "$PIDF" && echo "alive (pid $(cat "$PIDF"))" || echo 'not running')"
    jobs_list | while IFS='|' read -r p n rg mb; do
      if is_done "$p" "$n" "$rg" "$mb"; then s=done
      elif [ -f "$(run_log "$p" "$n" "$rg" "$mb")" ]; then s=running
      else s=queued; fi
      echo "${n}c ${mb}MB $rg $s"
    done | sort | uniq -c | awk '{ printf "   %3d  %s\n", $1, substr($0, index($0, $2)) }'
    echo "   running now: $(pgrep -u "$(id -u)" -fc "[c]hampsim_b3v4_69ebdcce --config $W/cfg/" 2>/dev/null || echo 0)"
    [ -f "$LOG" ] && tail -5 "$LOG" | sed 's/^/   /' ;;
  install-resume)
    line="@reboot sleep 120; JOBS=$JOBS bash $HOME/a6_sweep.sh go >> $W/resume.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v 'a6_sweep.sh'; echo "$line" ) | crontab - || die "crontab failed"
    echo "installed: $line"
    crontab -l | grep -c 'a6_sweep.sh' | sed 's/^/   entries now: /' ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
