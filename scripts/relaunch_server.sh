#!/usr/bin/env bash
# The relaunch after the 22 Nov 2026 reboot (bench/policy_sanity/relaunch_2026-11-24.md), server side.
# Uploaded by scripts/relaunch_all.sh (to .new, then mv); each mode on the owner's word.
#
#   bash ~/relaunch_server.sh plan      # READ-ONLY: free space, each approved deletion (size, in use?),
#                                       # every chain alive or not, radix16's reference, Part A's runner
#   bash ~/relaunch_server.sh clean     # deletes the approved items below (only under ~, only if no
#                                       # process of ours uses them and their chain is not running)
#   bash ~/relaunch_server.sh radix16   # restarts radix16's g6 reference alone (Part B's trace runner,
#                                       # ~/sync_server_pb.sh __job, its JOBS line unchanged), detached;
#                                       # the dead run's log is kept as run.log.dead_<time>
#   bash ~/relaunch_server.sh partA MD5 # resumes Part A's chain (~/partA_server.sh chain) if that file
#                                       # is md5 MD5 (the committed runner); its 207 runs, done ones skipped
#
# Nothing else is started, stopped or changed. Never another user's files, never /tmp.
set -uo pipefail
R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
DONE_MARKER="ChampSim completed all CPUs"

# the owner's approval of 2026-11-23: path (under ~) | what it is | the chain that must not be running
APPROVED="$HOME/partC/strip|Part C's stripped trace copies left by the stopped pairs (each pair strips again)|$HOME/partC/.driver.pid
$HOME/gem5_ovt|the gem5 copy with the overtake log (H1b, scored 2026-11-17)|$HOME/gem5_ovt_w/.driver.pid
$HOME/gem5_fifo|the gem5 configs copy with the strict FIFO check (H1, scored 2026-11-17)|$HOME/gem5_fifo/.driver.pid
$S/traces/sync_nc_void_F2no|step 4's gem5-CPUID traces, void (F2 did not hold, 2026-11-04; never read)|
$S/traces/sync_mx.void_20261021_151433|the 2026-10-20 mutex-order traces, void (the tracer hooked no mutex on the server's glibc)|"

RADIX_JOB="radix16 radix 16 0 50000000 100000000 radix_16"
RADIX_LOG="$S/results/phaseA_b3_b16_radix16/regime_shared/radix_16core/lru/run.log"

die() { echo "ERROR: $*" >&2; exit 1; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
free_gb() { df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9; }
in_use() { pgrep -u "$(id -u)" -f -- "$1" > /dev/null; }   # a process of ours names the path on its command line
size_of() { timeout 120 du -sh "$1" 2>/dev/null | cut -f1; }

plan() {
  echo "== $(date '+%F %T'); /home: $(free_gb) GB free; load $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "== approved deletions"
  local p what pid
  while IFS='|' read -r p what pid; do
    if [ ! -e "$p" ]; then printf '   %-8s %s (gone)\n' '-' "$p"; continue; fi
    printf '   %-8s %s -- %s%s%s\n' "$(size_of "$p")" "$p" "$what" \
      "$(in_use "$p" && echo '; IN USE by a process')" "$([ -n "$pid" ] && alive "$pid" && echo '; its chain is RUNNING')"
  done <<< "$APPROVED"
  echo "== chains (none should be running before the relaunch)"
  local f
  for f in h7/.driver.pid partBfc/.driver.pid partC/.driver.pid partA/.driver.pid partA/.add16_wait.pid c0f/.driver.pid \
           sync_pb/.driver.pid ld/.driver.pid e2/.driver.pid; do
    printf '   %-26s %s\n' "$f" "$(alive "$HOME/$f" && echo RUNNING || echo 'not running')"
  done
  echo "   champsim processes of ours: $(pgrep -u "$(id -u)" -fc '[c]hampsim_' || true)"
  echo "== radix16's g6 reference"
  if [ -f "$RADIX_LOG" ]; then
    echo "   log $(stat -c '%y' "$RADIX_LOG" | cut -c1-19), $(grep -c "$DONE_MARKER" "$RADIX_LOG") complete; last heartbeat: $(grep '^Heartbeat' "$RADIX_LOG" | tail -1 | cut -c1-60)"
  else
    echo "   no log"
  fi
  echo "   running: $(pgrep -u "$(id -u)" -fc '[c]hampsim_.*sync_pb/cfg/radix16_' || true)"
  echo "== Part A: ~/partA_server.sh md5 $(md5sum < "$HOME/partA_server.sh" | cut -c1-8); E0_16 $([ -f "$HOME/partA/E0_16" ] && echo present || echo MISSING)"
}

clean() {
  local p what pid n=0 before
  before=$(free_gb)
  while IFS='|' read -r p what pid; do
    case "$p" in "$HOME"/?*) ;; *) die "$p is not under $HOME" ;; esac
    [ -e "$p" ] || { echo "   gone already: $p"; continue; }
    [ -z "$pid" ] || ! alive "$pid" || die "the chain of $p is running ($pid) -- nothing deleted from here on"
    in_use "$p" && die "a process of ours uses $p -- nothing deleted from here on"
    echo "   deleting $(size_of "$p") $p ($what)"
    rm -rf --one-file-system -- "$p" || die "rm of $p failed"
    n=$((n + 1))
  done <<< "$APPROVED"
  echo "deleted $n item(s); /home: $before GB free before, $(free_gb) GB now ($(date '+%F %T'))" | tee -a "$HOME/disk/relaunch_clean.log"
}

radix16() {
  [ -f "$HOME/sync_server_pb.sh" ] || die "no ~/sync_server_pb.sh"
  alive "$HOME/sync_pb/.driver.pid" && die "the pb chain is running -- it would run radix16 itself"
  grep -q "$DONE_MARKER" "$RADIX_LOG" 2>/dev/null && die "radix16's reference is complete already"
  pgrep -u "$(id -u)" -f '[c]hampsim_.*sync_pb/cfg/radix16_' > /dev/null && die "a radix16 reference run is running already"
  local line; line=$(head -1 "$HOME/partB/radix_16/JOBS" 2>/dev/null | tr '|' ' ')
  [ "$line" = "$RADIX_JOB" ] || die "~/partB/radix_16/JOBS reads '$line', not '$RADIX_JOB'"
  [ -f "$S/traces/sync_pb/radix_16/DONE" ] || die "radix_16's traces have no DONE"
  [ "$(free_gb)" -ge 5 ] || die "under 5 GB free"
  if [ -f "$RADIX_LOG" ]; then
    local keep; keep="$RADIX_LOG.dead_$(date +%Y%m%d_%H%M%S)"
    cp -p "$RADIX_LOG" "$keep" && echo "   the dead run's log kept as $keep (not read)"
  fi
  echo "$(date '+%F %T') RELAUNCH radix16 alone after the 22 Nov reboot (relaunch_2026-11-24.md)" >> "$HOME/sync_pb/driver.log"
  # the trace runner's own job(): same binary (~/sync_pb/BIN), config, window and traces as the first start
  setsid nohup env VARIANT=pb bash "$HOME/sync_server_pb.sh" __job $RADIX_JOB >> "$HOME/sync_pb/driver.log" 2>&1 < /dev/null &
  disown 2>/dev/null
  local i
  for i in $(seq 1 60); do
    sleep 2
    grep -q '^Simulation Instructions:' "$RADIX_LOG" 2>/dev/null && break
  done
  tail -n 2 "$HOME/sync_pb/driver.log" | sed 's/^/   /'
  grep -q '^Simulation Instructions:' "$RADIX_LOG" 2>/dev/null || die "the log shows no window after 2 min ($RADIX_LOG)"
  sleep 5
  local n; n=$(pgrep -u "$(id -u)" -fc '[c]hampsim_.*sync_pb/cfg/radix16_' || true)
  [ "${n:-0}" -ge 1 ] || die "no radix16 reference process is running after the start (~/sync_pb/driver.log, $RADIX_LOG)"
  echo "   running: $n; its log has the window lines, so partBfc's early start (amendment 13) can read it"
}

partA() {
  local want="${1:-}"
  [ -n "$want" ] || die "usage: partA MD5"
  [ "$(md5sum < "$HOME/partA_server.sh" | cut -c1-32)" = "$want" ] || die "~/partA_server.sh is not md5 $want"
  alive "$HOME/partA/.driver.pid" && die "the partA chain is running already"
  [ -f "$HOME/partA/E0_16" ] || die "no ~/partA/E0_16 (the 16-core mixes were never added)"
  bash "$HOME/partA_server.sh" chain
}

case "${1:-}" in
  plan) plan ;;
  clean) clean ;;
  radix16) radix16 ;;
  partA) partA "${2:-}" ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
