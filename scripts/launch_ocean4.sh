#!/usr/bin/env bash
# Launch ocean at 4 cores: A5's second workload and B3's ChampSim side.
#
#   scp -P 2222 scripts/launch_ocean4.sh user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/launch_ocean4.sh plan'   # launches nothing
#   ssh -n -p 2222 user@your-server 'bash ~/launch_ocean4.sh go'
#
# Eight queues, each a run_phase_a.sh go-tag. Every one runs ocean_4t in both
# regimes, and they differ in geometry, policies and binary:
#
#   tag                  geometry   policies              binary
#   ocean4               fixed      8 baselines           champsim_phaseA_20260923
#   ocean4_scaled        scaled     8 baselines           champsim_phaseA_20260923
#   ocean4_armA          fixed      COALESCE family       champsim_armA
#   ocean4_scaled_armA   scaled     COALESCE family       champsim_armA
#   ocean4_armB          fixed      COALESCE family       champsim_armB
#   ocean4_scaled_armB   scaled     COALESCE family       champsim_armB
#   b3_ocean4            fixed      LRU                   bin/champsim (store-time counter)
#   b3_ocean4_scaled     scaled     LRU                   bin/champsim (store-time counter)
#
# The binaries are the ones every earlier tree used, so the ocean rows compare
# with canneal's on the same code. LRU in ocean4/ocean4_scaled already ran
# (the pairing probe, 2026-10-01) and is skipped by its end marker.
#
# The b3_* queues exist for the store-time counter (5ac2844), which only
# bin/champsim carries. Deploy and server_build.sh must come FIRST; this
# refuses the b3 queues if bin/champsim lacks the counter. Their LRU rows must
# match the probe's exactly in every column the old binary prints. That is the
# full-length check that the counter changed nothing else.
#
# Concurrency: baselines 14 per queue, so all at once; arms 3 per queue, two
# waves; b3 2 per queue. At most 44 jobs on 48 shared cores, all niced.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
RUN="$HOME/run_phase_a.sh"
BASE="lru srrip drrip ship hawkeye mockingjay srrip_bias random"
FAM="coalesce coalesce_no_mesi coalesce_no_sharer"

die() { echo "ERROR: $*" >&2; exit 1; }

# tag | scaled | policies | binary | maxjobs
QUEUES="ocean4|0|$BASE|$S/bin/champsim_phaseA_20260923|14
ocean4_scaled|1|$BASE|$S/bin/champsim_phaseA_20260923|14
ocean4_armA|0|$FAM|$S/bin/champsim_armA|3
ocean4_scaled_armA|1|$FAM|$S/bin/champsim_armA|3
ocean4_armB|0|$FAM|$S/bin/champsim_armB|3
ocean4_scaled_armB|1|$FAM|$S/bin/champsim_armB|3
b3_ocean4|0|lru|$S/bin/champsim|2
b3_ocean4_scaled|1|lru|$S/bin/champsim|2"

preflight() {
  [ -f "$RUN" ] || die "no $RUN"
  grep -q 'OCEAN_CORES' "$RUN" || die "$RUN predates OCEAN_CORES (46416c4) -- upload it first"
  local tag sc pols bin mj n
  while IFS='|' read -r tag sc pols bin mj; do
    [ -x "$bin" ] || die "$tag: no binary at $bin"
  done <<< "$QUEUES"
  # grep -c, not -q: under pipefail an early -q exit SIGPIPEs strings and the
  # pipeline reads as "not found" (1a2b8ca).
  n=$(strings -a "$S/bin/champsim" 2>/dev/null | grep -c 'RFO-HIT OTHER-SHARER')
  [ "${n:-0}" -gt 0 ] || die "bin/champsim has no store-time counter -- deploy 5ac2844 and run server_build.sh first"
  echo "   preflight ok: run_phase_a.sh has OCEAN_CORES, all binaries present, bin/champsim carries the counter"
}

# env for one queue, then the run_phase_a.sh subcommand
each() {
  local sub="$1" tag sc pols bin mj
  while IFS='|' read -r tag sc pols bin mj; do
    echo "== $tag  ($( [ "$sc" = 1 ] && echo scaled || echo 'fixed 2 MB'); $pols; $(basename "$bin"); max $mj) =="
    WORKLOADS=ocean OCEAN_CORES=4 REGIMES="shared private" ONLY_POLICIES="$pols" \
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
      die "our champsim jobs are already running -- this launches eight queues; finish or check those first"
    fi
    each go-tag 'launched|START|SKIP|ERROR'
    echo; echo "check: bash ~/server_status.sh 2>&1 | grep -A2 'SWEEP: phaseA_.*ocean4'" ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
