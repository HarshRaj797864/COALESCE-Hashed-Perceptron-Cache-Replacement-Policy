#!/usr/bin/env bash
# B3 v4's chain, on the server: wait for the 24 LRU runs launch_b3_v4.sh
# started, apply the rule pre-registered in
# bench/policy_sanity/b3v4_coherent_private_design_2026-10-11.md, and start the
# A5 rerun only if it passes. Started by launch_b3_v4.sh; unattended.
#
#   bash ~/b3v4_chain.sh status      # where it is, and the verdict once there is one
#   bash ~/b3v4_chain.sh preflight   # what 'run' needs, checked; launches nothing
#   BIN=<frozen binary> bash ~/b3v4_chain.sh run       # (launch_b3_v4.sh does this, detached)
#
# THE RULE (b3_score.py gate): the rerun starts if, and only if, at level 2:
# the level-0 control equals the step-1 rows (Q0), every private-regime row
# equals its step-1 row (Q1), every row passes its checks (Q2), and ocean and
# canneal are in the band at both sizes. barnes is reported and does not gate.
#
# THE RERUN: level 2, shared regime, fixed 2 MB (l2_fixed) and scaled
# (l2_scaled); the 8 baselines and COALESCE as deployed; canneal at 4, 8 and
# 16 cores and ocean at 4. run_phase_a.sh also queues LRU in the private
# regime, which measures Q1 at 8 and 16 cores. 40 jobs a queue, 7 at a time
# each, longest first; about 3 days.
#
# Everything it decides is written to ~/b3v4_chain/: chain.log, the two rows
# files it scored, score.txt, gate.txt, and VERDICT (one line).
set -uo pipefail

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"   # overridable only to test this script
S="$R/simulator"
OUT="${CHAIN_OUT:-$HOME/b3v4_chain}"
RUN="$HOME/run_phase_a.sh"
POLL="${CHAIN_POLL:-120}"          # seconds between looks
GIVE_UP="${CHAIN_GIVE_UP:-129600}" # 36 h: these runs take ~3
DONE_MARKER="ChampSim completed all CPUs"
A5_POLICIES="lru srrip drrip ship hawkeye mockingjay srrip_bias random coalesce"

# tag | workload     (launch_b3_v4.sh's twelve queues)
TAGS="b3_v4_ocean4|ocean
b3_v4_ocean4_scaled|ocean
b3_v4_canneal4|canneal
b3_v4_canneal4_scaled|canneal
b3_v4_barnes4|barnes
b3_v5_ocean4|ocean
b3_v5_ocean4_scaled|ocean
b3_v5_canneal4|canneal
b3_v5_canneal4_scaled|canneal
b3_v5_barnes4|barnes
b3_v4l0_canneal4|canneal
b3_v4l0_barnes4|barnes"

say() { echo "$(date '+%F %T') $*"; }
verdict() { echo "$(date '+%F %T') $*" > "$OUT/VERDICT"; say "VERDICT: $*"; }

logs_done() {   # -> "<complete> <expected>"
  local tag wl rg d=0 n=0
  while IFS='|' read -r tag wl; do
    for rg in shared private; do
      n=$((n + 1))
      grep -q "$DONE_MARKER" "$S/results/phaseA_$tag/regime_$rg/${wl}_4core/lru/run.log" 2>/dev/null && d=$((d + 1))
    done
  done <<< "$TAGS"
  echo "$d $n"
}
drivers_alive() {   # -> how many of the twelve queue drivers are still running
  local tag wl lk a=0
  while IFS='|' read -r tag wl; do
    lk="$HOME/.phase_a_$tag/driver.pid"
    [ -f "$lk" ] && kill -0 "$(cat "$lk" 2>/dev/null)" 2>/dev/null && a=$((a + 1))
  done <<< "$TAGS"
  echo "$a"
}

preflight() {
  local f
  for f in "$RUN" "$HOME/b3_rows.sh" "$HOME/b3_score.py" "$HOME/gem5_b3_rows_v1.txt"; do
    [ -f "$f" ] || { echo "   chain: missing $f" >&2; return 1; }
  done
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null || { echo "   chain: python3 >= 3.6 is needed for b3_score.py" >&2; return 1; }
  # Not a pipeline: b3_score.py without arguments exits 2 after printing its
  # usage, and under pipefail that failed this check with 'gate' present.
  local usage; usage=$(python3 "$HOME/b3_score.py" 2>/dev/null)
  case "$usage" in *"gate PHASEA_ROWS"*) ;; *) echo "   chain: ~/b3_score.py has no 'gate'" >&2; return 1 ;; esac
  [ "$(wc -l < "$HOME/gem5_b3_rows_v1.txt")" -ge 13 ] || { echo "   chain: ~/gem5_b3_rows_v1.txt is short" >&2; return 1; }
  # the step-1 rows the gate compares with must still be on disk
  local suf rg wl
  for suf in ocean4 ocean4_scaled canneal4 canneal4_scaled barnes4; do
    wl=${suf%%4*}
    for rg in shared private; do
      grep -q "$DONE_MARKER" "$S/results/phaseA_b3_v3_$suf/regime_$rg/${wl}_4core/lru/run.log" 2>/dev/null \
        || { echo "   chain: the step-1 run phaseA_b3_v3_$suf ($rg) is not on disk; the rule compares with it" >&2; return 1; }
    done
  done
  return 0
}

launch_a5() {
  local tag sc
  for tag in l2_fixed l2_scaled; do
    [ "$tag" = l2_scaled ] && sc=1 || sc=0
    say "starting the A5 rerun queue $tag (level 2, shared, $( [ "$sc" = 1 ] && echo scaled || echo 'fixed 2 MB'))"
    WORKLOADS="canneal ocean" OCEAN_CORES=4 REGIMES=shared ONLY_POLICIES="$A5_POLICIES" BIN="$BIN" \
      SCALED="$sc" COHERENCE=2 MAXJOBS=7 LONGEST_FIRST=1 RESUME_SKIP_BUSY=1 bash "$RUN" go-tag "$tag" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { verdict "RULE PASSED, but the A5 queue $tag FAILED TO START -- see chain.log"; return 1; }
    # A multi-day queue: restart it after a reboot. (The 2026-09-27 reboot's
    # resume did not fire; server_status.sh shows whether a queue is alive.)
    bash "$RUN" install-resume "$tag" > /dev/null 2>&1 || say "   note: install-resume $tag failed"
  done
}

run() {
  mkdir -p "$OUT"
  [ -n "${BIN:-}" ] && [ -x "$BIN" ] || { verdict "STOPPED: no frozen binary given (BIN='${BIN:-}')"; exit 1; }
  preflight || { verdict "STOPPED: the chain's preflight failed"; exit 1; }
  say "chain started; binary $BIN ($(md5sum < "$BIN" | cut -c1-32))"
  echo "$(date '+%F %T') WAITING for the 24 runs" > "$OUT/VERDICT"
  local waited=0 d n a
  while :; do
    read -r d n <<< "$(logs_done)"
    a=$(drivers_alive)
    [ "$d" = "$n" ] && break
    # Every driver gone and a run unfinished: it failed. (A driver takes a
    # moment to appear after launch, so not before the first few polls.)
    if [ "$a" = 0 ] && [ "$waited" -ge $((POLL * 3)) ]; then
      verdict "STOPPED: only $d of $n runs finished and no queue driver is alive -- a run failed; nothing else launched"; exit 1
    fi
    [ "$waited" -lt "$GIVE_UP" ] || { verdict "STOPPED: gave up after $((GIVE_UP / 3600)) h with $d of $n runs finished"; exit 1; }
    sleep "$POLL"; waited=$((waited + POLL))
  done
  say "all $n runs have their end marker"
  # Let the drivers write their last lines and exit.
  local i=0; while [ "$(drivers_alive)" != 0 ] && [ "$i" -lt 30 ]; do sleep 10; i=$((i + 1)); done

  bash "$RUN" rows > "$OUT/phasea_rows.txt" 2>> "$OUT/chain.err" || { verdict "STOPPED: run_phase_a.sh rows failed"; exit 1; }
  bash "$HOME/b3_rows.sh" > "$OUT/b3_rows.txt" 2>> "$OUT/chain.err" || { verdict "STOPPED: b3_rows.sh failed"; exit 1; }
  python3 "$HOME/b3_score.py" score "$OUT/phasea_rows.txt" "$OUT/b3_rows.txt" "$HOME/gem5_b3_rows_v1.txt" v3 v4 v5 v4l0 > "$OUT/score.txt" 2>&1 \
    || say "note: b3_score.py score exited non-zero (see score.txt); the gate decides"
  python3 "$HOME/b3_score.py" gate "$OUT/phasea_rows.txt" "$OUT/b3_rows.txt" "$HOME/gem5_b3_rows_v1.txt" > "$OUT/gate.txt" 2>&1
  local rc=$?
  sed 's/^/   /' "$OUT/gate.txt"
  if [ "$rc" -ne 0 ]; then
    verdict "RULE NOT MET (gate exit $rc): the A5 rerun was NOT started -- see gate.txt"; exit 0
  fi
  grep -q '^GATE: PASS' "$OUT/gate.txt" || { verdict "STOPPED: the gate exited 0 without printing PASS"; exit 1; }
  if [ "${CHAIN_DRY:-0}" = 1 ]; then verdict "RULE PASSED (dry run: nothing started)"; exit 0; fi
  launch_a5 || exit 1
  verdict "RULE PASSED: the A5 rerun is running (queues l2_fixed and l2_scaled)"
}

status() {
  echo "== chain =="
  [ -d "$OUT" ] || { echo "   not started"; return 0; }
  read -r d n <<< "$(logs_done)"
  echo "   B3 v4 runs with their end marker: $d / $n   queue drivers alive: $(drivers_alive)"
  [ -f "$OUT/VERDICT" ] && sed 's/^/   /' "$OUT/VERDICT"
  pgrep -u "$(id -u)" -f '^bash [^ ]*b3v4_chain\.sh run' > /dev/null 2>&1 && echo "   the chain process is alive" || echo "   the chain process is not running"
  [ -f "$OUT/gate.txt" ] && { echo "== gate =="; sed 's/^/   /' "$OUT/gate.txt"; }
  local tag
  for tag in l2_fixed l2_scaled; do
    [ -d "$HOME/.phase_a_$tag" ] || continue
    echo "== A5 rerun: $tag =="
    bash "$RUN" status-tag "$tag" 2>&1 | sed -n '2,5p' | sed 's/^/   /'
  done
}

case "${1:-}" in
  run)       run ;;
  preflight) preflight ;;
  status)    status ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
