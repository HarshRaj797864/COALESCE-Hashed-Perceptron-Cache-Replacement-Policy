#!/usr/bin/env bash
# Launch B3 v2's ChampSim side: LRU on the binary with the sharer directory
# (acb76b2), for the comparison pre-registered in b3v2_design_2026-10-05.md.
#
#   ssh -n -p 2222 user@your-server 'bash ~/launch_b3_v2.sh plan'   # launches nothing
#   ssh -n -p 2222 user@your-server 'bash ~/launch_b3_v2.sh go'
#   ssh -n -p 2222 user@your-server 'SET=canneal bash ~/launch_b3_v2.sh go'
#   ssh -n -p 2222 user@your-server 'SET=v3 bash ~/launch_b3_v2.sh go'
#
# Both regimes, LRU only, 4 cores, on bin/champsim. SET=ocean_barnes (default,
# 2026-10-05):
#   b3_v2_ocean4         ocean 4c, fixed 2 MB   (gem5: ~/gem5_b3/l2_2MB_*)
#   b3_v2_ocean4_scaled  ocean 4c, 2 MB/core    (gem5: ~/gem5_b3/l2_8MB_*)
#   b3_v2_barnes4        barnes 4c, fixed 2 MB  (gem5: ~/gem5_b3/barnes/l2_2MB_*)
# SET=canneal (2026-10-06):
#   b3_v2_canneal4         canneal 4c, fixed 2 MB  (gem5: ~/gem5_b3/canneal/l2_2MB_*)
#   b3_v2_canneal4_scaled  canneal 4c, 2 MB/core   (gem5: ~/gem5_b3/canneal/l2_8MB_*)
# SET=v3 (2026-10-07): B3 v3 step 1, a read-modify-write's load issued as an
# RFO (f23e03f; b3v3_rmw_design_2026-10-07.md). The five configurations
# above, b3_v3_*, against the same gem5 runs.
# Tags begin b3_ so b3_rows.sh picks them up. Every pre-existing column of
# their rows must match the b3/probe LRU rows exactly (`analyze_rows.py same`):
# the directory only records.
#
# Derived from launch_ocean4.sh (tested 3cc8899), with a workload column.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
RUN="$HOME/run_phase_a.sh"

die() { echo "ERROR: $*" >&2; exit 1; }

# tag | scaled | workload | policies | binary | maxjobs
case "${SET:-ocean_barnes}" in
  ocean_barnes) QUEUES="b3_v2_ocean4|0|ocean|lru|$S/bin/champsim|2
b3_v2_ocean4_scaled|1|ocean|lru|$S/bin/champsim|2
b3_v2_barnes4|0|barnes|lru|$S/bin/champsim|2" ;;
  canneal) QUEUES="b3_v2_canneal4|0|canneal|lru|$S/bin/champsim|2
b3_v2_canneal4_scaled|1|canneal|lru|$S/bin/champsim|2" ;;
  v3) QUEUES="b3_v3_ocean4|0|ocean|lru|$S/bin/champsim|2
b3_v3_ocean4_scaled|1|ocean|lru|$S/bin/champsim|2
b3_v3_canneal4|0|canneal|lru|$S/bin/champsim|2
b3_v3_canneal4_scaled|1|canneal|lru|$S/bin/champsim|2
b3_v3_barnes4|0|barnes|lru|$S/bin/champsim|2" ;;
  *) die "SET must be ocean_barnes, canneal or v3" ;;
esac

preflight() {
  [ -f "$RUN" ] || die "no $RUN"
  grep -q 'OCEAN_CORES' "$RUN" || die "$RUN predates OCEAN_CORES (46416c4) -- upload it first"
  grep -q 'ONLY_CORES' "$RUN" || die "$RUN predates ONLY_CORES -- upload it first"
  local tag sc wl pols bin mj n
  while IFS='|' read -r tag sc wl pols bin mj; do
    [ -x "$bin" ] || die "$tag: no binary at $bin"
  done <<< "$QUEUES"
  # grep -c, not -q: under pipefail an early -q exit SIGPIPEs strings and the
  # pipeline reads as "not found" (1a2b8ca).
  n=$(strings -a "$S/bin/champsim" 2>/dev/null | grep -c 'COHERENCE DIR RFO PROTOCOL-OTHER')
  [ "${n:-0}" -gt 0 ] || die "bin/champsim has no sharer directory -- deploy acb76b2 and run server_build.sh first"
  if [ "${SET:-}" = v3 ]; then
    n=$(strings -a "$S/bin/champsim" 2>/dev/null | grep -c 'RMW LOADS ISSUED AS RFO')
    [ "${n:-0}" -gt 0 ] || die "bin/champsim predates B3 v3 step 1 (f23e03f) -- deploy it and run server_build.sh first"
  fi
  echo "   preflight ok: run_phase_a.sh has OCEAN_CORES, bin/champsim carries the sharer directory"
}

# env for one queue, then the run_phase_a.sh subcommand
each() {
  local sub="$1" tag sc wl pols bin mj
  while IFS='|' read -r tag sc wl pols bin mj; do
    echo "== $tag  ($wl; $( [ "$sc" = 1 ] && echo scaled || echo 'fixed 2 MB'); $pols; $(basename "$bin"); max $mj) =="
    # ONLY_CORES=4: canneal is queued at 4, 8 and 16 cores; ocean and barnes
    # are 4 already
    WORKLOADS=$wl OCEAN_CORES=4 ONLY_CORES=4 REGIMES="shared private" ONLY_POLICIES="$pols" \
      BIN="$bin" SCALED="$sc" MAXJOBS="$mj" RESUME_SKIP_BUSY=1 \
      bash "$RUN" "$sub" "$tag" 2>&1 | grep -E "$2|ERROR" | sed 's/^/   /'
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      [ "$sub" = go-tag ] && die "$tag: launch failed (reason above) -- every queue listed before it IS running; check 'status' before retrying"
      die "$tag: $sub failed (reason above)"
    fi
  done <<< "$QUEUES"
}

case "${1:-}" in
  plan)
    preflight
    each plan-tag 'total queued|already done|to run|unrunnable|UNRUNNABLE'
    echo; echo "nothing launched. 'go' to launch." ;;
  go)
    preflight
    # Refuse to overlap a sweep of ours already running. Each go-tag below gets
    # RESUME_SKIP_BUSY=1 so the second queue does not refuse because of the
    # first; this check, made once up front, is what replaces it.
    if pgrep -u "$(id -u)" '^champsim' >/dev/null 2>&1; then
      die "our champsim jobs are already running -- finish or check those first"
    fi
    each go-tag 'launched|START|SKIP|ERROR'
    echo; echo "check: bash ~/server_status.sh 2>&1 | grep -A2 'SWEEP: phaseA_b3_v'" ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
