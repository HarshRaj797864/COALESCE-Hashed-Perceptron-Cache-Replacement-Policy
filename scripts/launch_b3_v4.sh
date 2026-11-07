#!/usr/bin/env bash
# Launch B3 v4's ChampSim side: coherent private caches, steps 2 and 3, as
# pre-registered in bench/policy_sanity/b3v4_coherent_private_design_2026-10-11.md.
#
#   ssh -n -p 2222 user@your-server 'bash ~/launch_b3_v4.sh plan'    # launches nothing
#   ssh -n -p 2222 user@your-server 'bash ~/launch_b3_v4.sh go'
#   ssh -n -p 2222 user@your-server 'bash ~/launch_b3_v4.sh status'
#   ssh -n -p 2222 user@your-server 'CHAIN=0 bash ~/launch_b3_v4.sh go'   # without the A5 rerun
#
# LRU, 4 cores, both regimes, one frozen binary, 12 queues of 2 jobs:
#   b3_v4_*    level 1 (step 2)   ocean4, ocean4_scaled, canneal4, canneal4_scaled, barnes4
#   b3_v5_*    level 2 (step 3)   the same five
#   b3_v4l0_*  level 0 (control)  canneal4, barnes4
# against the existing gem5 runs. Tags begin b3_ so b3_rows.sh picks them up.
#
# 'go' first runs the exact-count check on THIS machine's binary (the fast
# cases, ~3 min), keeps the binary as bin/champsim_b3v4_<md5>, and starts the
# queues on that copy. Then, unless CHAIN=0, it starts ~/b3v4_chain.sh, which
# waits for the 24 runs, applies the pre-registered rule, and starts the A5
# rerun only if the rule passes.
#
# Derived from launch_b3_v2.sh (tested f23e03f), with a level column.
set -uo pipefail

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"   # overridable only to test this script
S="$R/simulator"
RUN="$HOME/run_phase_a.sh"
CHAIN_SH="$HOME/b3v4_chain.sh"
COUNTER='COHERENCE DIR STALE-HOLDER VIOLATIONS'

die() { echo "ERROR: $*" >&2; exit 1; }

# tag | scaled | workload | level
QUEUES="b3_v4_ocean4|0|ocean|1
b3_v4_ocean4_scaled|1|ocean|1
b3_v4_canneal4|0|canneal|1
b3_v4_canneal4_scaled|1|canneal|1
b3_v4_barnes4|0|barnes|1
b3_v5_ocean4|0|ocean|2
b3_v5_ocean4_scaled|1|ocean|2
b3_v5_canneal4|0|canneal|2
b3_v5_canneal4_scaled|1|canneal|2
b3_v5_barnes4|0|barnes|2
b3_v4l0_canneal4|0|canneal|0
b3_v4l0_barnes4|0|barnes|0"

# The frozen copy the queues run: named by the binary's own md5, so the name
# says which build made a result.
frozen() { echo "$S/bin/champsim_b3v4_$(md5sum < "$S/bin/champsim" | cut -c1-8)"; }

preflight() {
  [ -f "$RUN" ] || die "no $RUN"
  grep -q 'COHERENCE' "$RUN" || die "$RUN predates COHERENCE (B3 v4) -- upload it first"
  [ -x "$S/bin/champsim" ] || die "no binary at $S/bin/champsim -- run server_build.sh first"
  local n
  # grep -c, not -q: under pipefail an early -q exit SIGPIPEs strings (1a2b8ca).
  n=$(strings -a "$S/bin/champsim" 2>/dev/null | grep -c "$COUNTER")
  [ "${n:-0}" -gt 0 ] || die "bin/champsim predates B3 v4 -- deploy it and run server_build.sh first"
  n=$("$S/scripts/make_config.py" --policy lru --cores 4 --regime shared --private-coherence 2 2>/dev/null | grep -c '"private_coherence": 2')
  [ "${n:-0}" = 1 ] || die "the deployed make_config.py has no --private-coherence"
  if [ "${CHAIN:-1}" != 0 ]; then
    [ -f "$CHAIN_SH" ] && [ -f "$HOME/b3_score.py" ] && [ -f "$HOME/gem5_b3_rows_v1.txt" ] && [ -f "$HOME/b3_rows.sh" ] \
      || die "the chain needs ~/b3v4_chain.sh, ~/b3_score.py, ~/b3_rows.sh and ~/gem5_b3_rows_v1.txt -- upload them, or set CHAIN=0"
    bash "$CHAIN_SH" preflight || die "the chain's own preflight failed (reason above)"
  fi
  echo "   preflight ok: run_phase_a.sh has COHERENCE, bin/champsim is a B3 v4 build, make_config.py takes --private-coherence"
}

# env for one queue, then the run_phase_a.sh subcommand. $3 = the binary.
each() {
  local sub="$1" bin="$3" tag sc wl lv
  while IFS='|' read -r tag sc wl lv; do
    echo "== $tag  ($wl; $( [ "$sc" = 1 ] && echo scaled || echo 'fixed 2 MB'); level $lv; $(basename "$bin")) =="
    # ONLY_CORES=4: canneal is queued at 4, 8 and 16 cores
    WORKLOADS=$wl OCEAN_CORES=4 ONLY_CORES=4 REGIMES="shared private" ONLY_POLICIES=lru \
      BIN="$bin" SCALED="$sc" COHERENCE="$lv" MAXJOBS=2 RESUME_SKIP_BUSY=1 \
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
    each plan-tag 'total queued|already done|to run|unrunnable|UNRUNNABLE' "$S/bin/champsim"
    echo; echo "nothing launched. 'go' to launch$( [ "${CHAIN:-1}" != 0 ] && echo ', with the A5 rerun chained to the result' )." ;;
  go)
    preflight
    # Refuse to overlap a sweep of ours already running. Each go-tag below gets
    # RESUME_SKIP_BUSY=1 so a later queue does not refuse because of an earlier
    # one; this check, made once up front, is what replaces it.
    if pgrep -u "$(id -u)" '^champsim' >/dev/null 2>&1; then
      die "our champsim jobs are already running -- finish or check those first"
    fi
    echo "== exact counts on this machine's binary (fast cases, a few minutes) =="
    # /tmp on this machine is the full root filesystem: keep the traces in $HOME.
    mkdir -p "$HOME/.b3v4_tmp"
    if ! TMPDIR="$HOME/.b3v4_tmp" JOBS=12 ONLY="order pingpong upgrade upgrade_l2 forward storm" \
         bash "$R/bench/policy_sanity/check_coherence_exact.sh" > "$HOME/.b3v4_tmp/exact.log" 2>&1; then
      tail -30 "$HOME/.b3v4_tmp/exact.log" | sed 's/^/   /'
      die "the exact-count check FAILED on this build -- nothing launched (log: ~/.b3v4_tmp/exact.log)"
    fi
    tail -1 "$HOME/.b3v4_tmp/exact.log" | sed 's/^/   /'
    BINF="$(frozen)"
    if [ -e "$BINF" ]; then cmp -s "$S/bin/champsim" "$BINF" || die "$BINF exists and differs from bin/champsim"
    else cp -p "$S/bin/champsim" "$BINF" && cmp -s "$S/bin/champsim" "$BINF" || die "could not keep bin/champsim as $BINF"; fi
    echo "   the queues run $(basename "$BINF"), a copy of bin/champsim"
    each go-tag 'launched|START|SKIP|ERROR' "$BINF"
    if [ "${CHAIN:-1}" != 0 ]; then
      mkdir -p "$HOME/b3v4_chain"
      # A subshell, and every stream closed: nothing here may hold the caller's pipe (0700b8c).
      ( BIN="$BINF" setsid nohup bash "$CHAIN_SH" run < /dev/null >> "$HOME/b3v4_chain/chain.log" 2>&1 & )
      echo; echo "== the chain is started: it waits for these 24 runs, applies the rule, and may start the A5 rerun =="
      echo "   log: ~/b3v4_chain/chain.log"
    fi
    echo; echo "check: bash ~/launch_b3_v4.sh status" ;;
  status)
    while IFS='|' read -r tag sc wl lv; do
      d=0
      for rg in shared private; do
        grep -q 'ChampSim completed all CPUs' "$S/results/phaseA_$tag/regime_$rg/${wl}_4core/lru/run.log" 2>/dev/null && d=$((d + 1))
      done
      lk="$HOME/.phase_a_$tag/driver.pid"
      printf '   %-24s level %s   %s / 2 complete   driver %s\n' "$tag" "$lv" "$d" \
        "$( [ -f "$lk" ] && kill -0 "$(cat "$lk" 2>/dev/null)" 2>/dev/null && echo alive || echo 'not running' )"
    done <<< "$QUEUES"
    echo "   our champsim processes now: $(pgrep -u "$(id -u)" -c '^champsim' 2>/dev/null)"
    [ -f "$CHAIN_SH" ] && bash "$CHAIN_SH" status ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
