#!/usr/bin/env bash
# B3: the gem5 runs that put gem5 on ChampSim's measured window.
#
#   scp -P 2222 scripts/launch_b3_gem5.sh user@your-server:~/launch_b3_gem5.sh.new   (then mv)
#   ssh -n -p 2222 user@your-server 'bash ~/launch_b3_gem5.sh go'              # ocean
#   ssh -n -p 2222 user@your-server 'WL=barnes bash ~/launch_b3_gem5.sh go'    # barnes
#   ssh -n -p 2222 user@your-server 'WL=canneal bash ~/launch_b3_gem5.sh go'   # canneal (5 CPUs)
#   ssh -n -p 2222 user@your-server '[WL=barnes] bash ~/launch_b3_gem5.sh status'
#   ssh -n -p 2222 user@your-server '[WL=canneal] bash ~/launch_b3_gem5.sh check'   # what each run was given
#   ssh -n -p 2222 user@your-server 'WL=canneal bash ~/launch_b3_gem5.sh restart' # stop a stuck launcher (never gem5), then go
#   ssh -n -p 2222 user@your-server 'WL=barnes VARIANT=leaf256 bash ~/launch_b3_gem5.sh go'   # (barnes256_gem5.sh does this)
#   ssh -n -p 2222 user@your-server 'WL=radix bash ~/launch_b3_gem5.sh go'   # held-out: radix, waternsq, fmm (b3_heldout.sh does this)
#
# ChampSim measures instructions 50M..150M of each thread (50M warmup + 100M,
# counters reset at the start of measurement). gem5 is deterministic with
# randomization off, so a run stopped at 50M and one stopped at 150M share
# their first 50M exactly, and stats(150M) - stats(50M) is that window
# (gem5_stats.sh window). A whole-program run gives a third span, 150M..end,
# which tests whether the rate is steady, and so whether the alignment of
# windows matters at all.
#
# WL=ocean (default): ocean -n514 -p4 (the traced problem), LLC 2MB and 8MB x
#   stop at 50M and 150M -> ~/gem5_b3/l2_<size>_mi<N>M. Its whole-program run
#   is ~/gem5_results_MESI_Three_Level_n514.
# WL=barnes: barnes n16384 -p4 (the barnes_4t traces' input), LLC 2MB x stop
#   at 50M, 100M, 150M and the whole program -> ~/gem5_b3/barnes/l2_2MB_*. No 8MB
#   runs: at 8MB, barnes 4c takes no LLC miss in ChampSim
#   (internals_finding_2026-09-21.md), so it cannot discriminate.
# WL=canneal: canneal 4 15000 2000 100000.nets 128 (the canneal_4t traces'
#   arguments) on 5 CPUs, LLC 2MB and 8MB x stop when a WORKER reaches 50M,
#   100M and 150M -> ~/gem5_b3/canneal/l2_<size>_mi<N>M.
# WL=barnes VARIANT=leaf256 (2026-10-12): the barnes_4t traces are of a
#   BARNES built with MAX_BODIES_PER_LEAF 256, not the source's 10
#   (b3_barnes_stream_2026-10-12.md). This runs that program: the binary in
#   ~/splash-static-leaf256, built and checked by barnes256_gem5.sh. LLC 2MB x
#   stop at 50M and 150M -> ~/gem5_b3/barnes_leaf256/l2_2MB_*. No whole-program
#   run: a step is ~4x as long.
#
# Detached and idempotent, after 2026-10-05: each launch spends about a
# minute in silent checks (two scans of the 950 MB gem5 binary and a 20 s
# native run), and an ssh session dropped during the second one. That killed
# the launcher after run 1 had started. `go` now hands the loop to a
# setsid'd worker and returns at once. The worker skips a run that already
# ENDED: run_gem5_splash.sh would otherwise archive the finished run as
# .prev_* and simulate it again. A run that is live is left alone by
# run_gem5_splash.sh's own guard; a run that failed is archived and
# relaunched. One worker per workload, tracked by a pid file.
set -uo pipefail
B="$HOME/gem5_b3"
WL="${WL:-ocean}"
VARIANT="${VARIANT:-}"
[ -z "$VARIANT" ] || [ "$WL:$VARIANT" = barnes:leaf256 ] || { echo "ERROR: the only variant is WL=barnes VARIANT=leaf256" >&2; exit 1; }

case "$WL" in
  ocean)  BASE="$B"
          runs() { for l2 in 2MB 8MB; do for mi in 50000000 150000000; do echo "$l2 $mi"; done; done; } ;;
  barnes) if [ "$VARIANT" = leaf256 ]; then
            BASE="$B/barnes_leaf256"
            export BINS="${BINS:-$HOME/splash-static-leaf256}"   # run_gem5_splash.sh reads it
            runs() { for mi in 50000000 150000000; do echo "2MB $mi"; done; }
          else
            BASE="$B/barnes"
            # 100 M (2026-10-13): with the 50 M stop it bounds a span inside
            # the first force phase, for the standard-barnes traces
            # (b3_barnes_std_design_2026-10-13.md). The other three have ended.
            runs() { for mi in 50000000 100000000 150000000 0; do echo "2MB $mi"; done; }
          fi ;;
  # canneal: 5 CPUs (loader + 4 workers); the stop counts WORKER instructions
  # (WORKER_MAXINSTS, run_gem5_splash.sh). The loader alone runs ~4.0 G
  # instructions before any worker starts (valgrind, 0 anneal steps,
  # 2026-10-06), so gem5's 0..50M span is mostly loader and cannot test
  # steadiness the way ocean's did. A stop at 100M gives two worker-only
  # spans, 50-100M and 100-150M, inside the measured window. No
  # whole-program run.
  canneal) BASE="$B/canneal"
          runs() { for l2 in 2MB 8MB; do for mi in 50000000 100000000 150000000; do echo "$l2 $mi"; done; done; } ;;
  # Held-out programs (b3_heldout_design_2026-10-14.md), 2026-10-14: the
  # static binaries b3_heldout.sh builds into ~/splash-heldout; LLC 2MB x stop
  # when a WORKER (cpu 1-3) reaches 50M and 150M, so thread 0's serial start
  # falls before the window -> ~/gem5_b3/heldout/<wl>/l2_2MB_mi<N>M.
  # radix's traces skip its first 780 M instructions a thread (key generation,
  # before the first barrier), so its stops are 830 M and 930 M.
  radix|waternsq|fmm)
          BASE="$B/heldout/$WL"
          export BINS="${BINS:-$HOME/splash-heldout}"
          if [ "$WL" = radix ]; then runs() { for mi in 830000000 930000000; do echo "2MB $mi"; done; }
          else runs() { for mi in 50000000 150000000; do echo "2MB $mi"; done; }; fi ;;
  # canneal at 8 workers (b3_canneal8_design_2026-10-14.md): 9 CPUs, LLC 2MB x
  # stop when a worker reaches 50M and 150M -> ~/gem5_b3/canneal8/l2_2MB_mi<N>M/canneal_8c
  canneal8)
          BASE="$B/canneal8"
          runs() { for mi in 50000000 150000000; do echo "2MB $mi"; done; } ;;
  # New benchmarks (newbench_design_2026-10-19.md): the static binaries
  # newbench_server.sh builds into ~/splash-newbench, their chosen inputs in
  # ~/newbench/<wl>; LLC 2MB x stop when a WORKER reaches 50M and 150M ->
  # ~/gem5_b3/newbench/<wl>/l2_2MB_mi<N>M. streamcluster on 5 CPUs, as canneal.
  fft|lu|cholesky|waterspatial|raytrace|streamcluster|volrend|radiosity|lunc)
          BASE="$B/newbench/$WL"
          export BINS="${BINS:-$HOME/splash-newbench}"
          runs() { for mi in 50000000 150000000; do echo "2MB $mi"; done; } ;;
  # Held-out set 2 (heldout2_design_2026-11-04.md): the static binaries
  # heldout2_server.sh builds into ~/heldout2_static, the chosen inputs and
  # CPU counts in ~/heldout2/<wl>; LLC 2MB x stop when a WORKER reaches 50M
  # and 150M -> ~/gem5_b3/heldout2/<wl>/l2_2MB_mi<N>M. A run not ended after
  # 96 h is stopped (run_gem5_splash.sh, H2_TIMEOUT).
  fluidanimate|bodytrack|facesim|vips|oceannc)
          BASE="$B/heldout2/$WL"
          export BINS="${BINS:-$HOME/heldout2_static}"
          runs() { for mi in 50000000 150000000; do echo "2MB $mi"; done; } ;;
  *) echo "ERROR: WL must be ocean, barnes, canneal, canneal8, radix, waternsq, fmm, fft, lu, cholesky, waterspatial, raytrace, streamcluster, volrend, radiosity, lunc, fluidanimate, bodytrack, facesim, vips or oceannc" >&2; exit 1 ;;
esac
# The run's tag and run_gem5_splash.sh's entry: <wl>_4c and go-<wl>-4c, except
# canneal at 8 workers (canneal_8c, go-canneal-8c).
if [ "$WL" = canneal8 ]; then TAG=canneal_8c; ENTRY=go-canneal-8c; else TAG="${WL}_4c"; ENTRY="go-$WL-4c"; fi
# MAXINSTS 0 = the whole program
out() { echo "$BASE/l2_$1_$( [ "$2" = 0 ] && echo whole || echo "mi$(( $2 / 1000000 ))M")"; }
LOG="$BASE/launch.log"
PIDF="$BASE/.launcher.pid"
worker_alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

case "${1:-}" in
  go)
    mkdir -p "$BASE"
    if worker_alive; then echo "a $WL launch is already in progress (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    WL="$WL" VARIANT="$VARIANT" setsid bash "$0" __go > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    echo "launching $WL${VARIANT:+ ($VARIANT)} in the background (about a minute of checks per run); log: $LOG"
    echo "check: ${WL:+WL=$WL }${VARIANT:+VARIANT=$VARIANT }bash $0 status" ;;
  restart)
    # Stop a launcher stuck waiting on a run, then `go`. Needed once, on
    # 2026-10-06: before run_gem5_splash.sh's backgrounding fix, the launcher
    # waited for each gem5 run to END before starting the next. The worker
    # was started with setsid, so its pid is its session id. Everything in
    # that session goes: the worker, its loop, run_gem5_splash.sh and the
    # subshell waiting on gem5. gem5 itself is in a session of its own (it is
    # started with setsid too) and is not touched; refuse if one is not.
    if worker_alive; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || { echo "ERROR: pid $sid is not a session leader -- not our launcher; stopping nothing" >&2; exit 1; }
      ps -o args= -p "$sid" | grep -c 'launch_b3_gem5.sh __go' >/dev/null || { echo "ERROR: pid $sid is not a launch_b3_gem5.sh worker; stopping nothing" >&2; exit 1; }
      inside=$(ps -eo pid=,sid=,comm= | awk -v s="$sid" '$2 == s && $3 ~ /^gem5/ { print $1 }')
      [ -z "$inside" ] || { echo "ERROR: gem5 pid(s) $inside are in the launcher's session -- stopping nothing" >&2; exit 1; }
      pkill -TERM -s "$sid"; sleep 2
      pgrep -s "$sid" >/dev/null && { echo "ERROR: the launcher's session $sid did not stop" >&2; exit 1; }
      rm -f "$PIDF"
      echo "stopped the $WL launcher (session $sid); no gem5 run was touched"
    fi
    exec env WL="$WL" VARIANT="$VARIANT" bash "$0" go ;;
  __go)
    echo $$ > "$PIDF"
    runs | while read -r l2 mi; do
      o="$(out "$l2" "$mi")"
      echo "== $WL${VARIANT:+ ($VARIANT, binaries in $BINS)}, LLC $l2, stop at ${mi/#0/the end} =="
      if grep -q "Exiting @ tick" "$o/$TAG/run.log" 2>/dev/null; then
        echo "   already ended -- skipped"; continue
      fi
      if [ "$mi" = 0 ]; then lim=""; else lim="$mi"; fi
      case "$WL" in canneal|canneal8|radix|waternsq|fmm|fft|lu|cholesky|waterspatial|raytrace|streamcluster|volrend|radiosity|lunc|fluidanimate|bodytrack|facesim|vips|oceannc) wlim="$lim"; lim="" ;; *) wlim="" ;; esac
      OUT="$o" OCEAN_GRID=514 LLC_SIZE="$l2" MAXINSTS="$lim" WORKER_MAXINSTS="$wlim" \
        bash "$HOME/run_gem5_splash.sh" "$ENTRY" 2>&1 | sed 's/^/   /'
      [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "ERROR: that launch failed -- the runs above it ARE running"; rm -f "$PIDF"; exit 1; }
    done
    rm -f "$PIDF"
    echo "== launcher done $(date '+%F %T') ==" ;;
  status)
    if worker_alive; then echo "(launcher still working -- tail $LOG)"; fi
    runs | while read -r l2 mi; do
      printf '== %s, LLC %s, stop at %s:  ' "$WL" "$l2" "${mi/#0/the end}"
      line=$(OUT="$(out "$l2" "$mi")" bash "$HOME/run_gem5_splash.sh" stats 2>&1 | grep -E "$TAG" | sed 's/^ *//')
      echo "${line:-not started}"
    done ;;
  check)
    # What each started run was really given, read back from its config.ini:
    # the command, the L2 size, the per-CPU stop, the patch-fifo buffers and
    # randomization. Checks the --param stop on canneal (2026-10-06).
    runs | while read -r l2 mi; do
      c="$(out "$l2" "$mi")/$TAG/config.ini"
      printf '== %s, LLC %s, stop at %s\n' "$WL" "$l2" "${mi/#0/the end}"
      [ -f "$c" ] || { echo "   no config.ini yet"; continue; }
      awk '
        /^\[/ { sec = substr($0, 2, length($0) - 2); next }
        { k = $0; sub(/=.*/, "", k); v = substr($0, length(k) + 2) }
        sec ~ /^system\.cpu[0-9]+$/ && k == "max_insts_any_thread" { n = substr(sec, 11) + 0; stop[n] = v; if (n + 1 > ncpu) ncpu = n + 1 }
        sec ~ /^system\.ruby\.l0_cntrl[0-9]+\.buffer(To|From)L1$/ && k == "ordered" { nb++; if (v == "false") nf++ }
        sec == "system.ruby" && k == "randomization" { rnd = v }
        sec ~ /^system\.ruby\.l2_cntrl[0-9]+\.L2cache$/ && k == "size" { l2 = v }
        sec ~ /^system\.cpu[0-9]+\.workload$/ && k == "cmd" && cmd == "" { cmd = v }
        END {
          printf "   cmd            %s\n", cmd
          printf "   L2             %d bytes (%.0f MB)\n", l2, l2 / 1048576
          printf "   stop per cpu  "; for (i = 0; i < ncpu; i++) printf " cpu%d=%s", i, stop[i]; printf "\n"
          printf "   L0<->L1 buffers ordered=false: %d of %d   randomization=%s\n", nf, nb, rnd
        }' "$c"
    done ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
