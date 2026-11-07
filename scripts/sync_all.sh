#!/usr/bin/env bash
# Step 2, synchronised replay (bench/policy_sanity/sync_replay_design_2026-10-18.md):
# upload the sources and the Pin tracer to their own tree on the server, build
# and check there, then trace every B3 program with sync records and rerun the
# 12 B3 configurations on them. One command, one password.
#
#   scripts/sync_all.sh          # from the repo root, on the LAPTOP
#   scripts/sync_all.sh pull     # later: status, and the new runs' logs and trace checks
#
# Steps, each checked, stopping at the first failure:
#   1. local    the design and every uploaded file committed; scripts parse
#   2. upload   the simulator sources and the tracer into ~/sync_build -- NOT the
#               main tree -- and sync_server.sh (.new + mv), sync_cut.py, trace_mix.c
#   3. build    sync_server.sh build: ChampSim, guards, frozen copy
#               bin/champsim_sync_<md5>, the tracer, Q0 against b3v4
#   4. start    sync_server.sh chain: trace 8 programs (about 1-2 h), then 12
#               runs (about 3-6 h); detached, no auto-resume
#
# VARIANT=mx (scripts/syncmx_all.sh): mutex order by simulated timing
# (sync_mutex_design_2026-10-19.md), in its own build tree, trace directory and
# run trees (phaseA_b3_m2_*); its build adds Q0b.
# VARIANT=g5 (scripts/syncg5_all.sh): step 3, the gem5-rule view
# (b3_g5rule_design_2026-10-19.md): no tracing; it waits for the mx traces,
# checks Q0m, runs phaseA_b3_g2_*, and checks Q0-full against the m2 runs.
# VARIANT=g6 (scripts/syncg6_all.sh): amendment 2 of the gem5-rule view
# (2026-10-27): the build (Q0 and Q0m against the g5 binary) and the chain
# (phaseA_b3_g3_*, Q0-full against g2, Q3) run DETACHED on the server, one
# command; this script only follows the log. A dropped connection stops nothing.
set -uo pipefail
VARIANT="${VARIANT:-}"
case "$VARIANT" in "") VW=sync; VTAG=s2; VTR=sync ;; mx) VW=sync_mx; VTAG=m2; VTR=sync_mx ;; g5) VW=sync_g5; VTAG=g2; VTR=sync_mx ;; g6) VW=sync_g6; VTAG=g3; VTR=sync_mx ;; *) echo "VARIANT must be empty, mx, g5 or g6"; exit 1 ;; esac
PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
CB="$SRV_HOME/${VW}_build"
PREREG="bench/policy_sanity/sync_replay_design_2026-10-18.md"
[ "$VARIANT" = mx ] && PREREG="bench/policy_sanity/sync_mutex_design_2026-10-19.md"
[ "$VARIANT" = g5 ] || [ "$VARIANT" = g6 ] && PREREG="bench/policy_sanity/b3_g5rule_design_2026-10-19.md"
SV="VARIANT=$VARIANT bash $SRV_HOME/sync_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json simulator/tracer/pin/champsim_tracer.cpp simulator/tracer/pin/Makefile"
HOMEFILES="scripts/sync_server.sh scripts/sync_cut.py scripts/trace_mix.c scripts/sync_anchor.py bench/mutex_micro.c"
MODE="${1:-}"
case "$MODE" in ""|pull|stop) ;; *) echo "usage: $0 [pull|stop]"; exit 1 ;; esac
LOG="$LROOT/simulator/results/${VW}_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/4  $2 ================"; }
STEP=0

if [ -z "$MODE" ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/sync_server.sh" || die "sync_server.sh does not parse"
  python3 -m py_compile "$LROOT/scripts/sync_cut.py" || die "sync_cut.py does not parse"
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES $HOMEFILES "$PREREG" scripts/sync_all.sh bench/policy_sanity/check_include_path.sh bench/policy_sanity/check_fill_hook.sh bench/policy_sanity/check_signatures.sh)
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-$VW-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo; echo "One connection for every step -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

if [ "$MODE" = stop ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = pull ]; then
  R "$SV status" | sed 's/^/   /'
  # g6 builds and checks detached: its launch log says whether Q0m passed and the chain started
  if [ "$VARIANT" = g6 ]; then
    echo "   -- end of ~/$VW/launch.log:"
    R "tail -n 12 $SRV_HOME/$VW/launch.log 2>/dev/null || echo '(no launch log)'" | sed 's/^/      /'
  fi
  mkdir -p "$LROOT/simulator/results/$VW"
  "${RS[@]}" --include='*/' --include='run.log' --exclude='*' "$SRV:$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_${VTAG}_*" \
    "$LROOT/simulator/results/$VW/logs/" && echo "   pulled: the new runs' logs to simulator/results/$VW/logs/"
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='pin.err' --include='cut.log' --include='*.mix' --include='DONE' --exclude='*' \
    "$SRV:$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/$VTR/" "$LROOT/simulator/results/$VW/traces/" \
    && echo "   pulled: tracer reports and mixes to simulator/results/$VW/traces/"
  "${RS[@]}" --include='driver.log' --exclude='*' "$SRV:$SRV_HOME/$VW/" "$LROOT/simulator/results/$VW/" || true
  echo "Then scripts/pull_results.sh for the rows. Tell Claude: sync pulled."
  exit 0
fi

step 2 "upload the sources and the tracer to $CB (the main tree is not touched)"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the $VW chain is already running -- $SV status"; fi
R "mkdir -p $CB/simulator/tracer/pin $CB/bench/policy_sanity" || die "cannot create $CB"
for d in $SRC_DIRS; do
  "${RS[@]}" --delete "$LROOT/$d/" "$SRV:$CB/$d/" || die "rsync of $d failed"
done
for f in $FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
for g in check_include_path check_fill_hook check_signatures; do
  "${RS[@]}" "$LROOT/bench/policy_sanity/$g.sh" "$SRV:$CB/bench/policy_sanity/$g.sh" || die "rsync of $g.sh failed"
done
R "rm -f $CB/simulator/absolute.options $CB/simulator/_configuration.mk; rm -rf $CB/simulator/.csconfig"
l=$(cd "$LROOT/simulator" && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc src/sharer_directory.cc src/plain_printer.cc tracer/pin/champsim_tracer.cpp | md5sum | cut -c1-32)
r=$(R "cd $CB/simulator && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc src/sharer_directory.cc src/plain_printer.cc tracer/pin/champsim_tracer.cpp | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "the uploaded sources do not match the laptop's"
for f in $HOMEFILES; do
  b=$(basename "$f")
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/$b.new" || die "upload of $b failed"
  R "mv -f $SRV_HOME/$b.new $SRV_HOME/$b" || die "mv of $b failed"
done
echo "   sources, tracer, guards and helpers uploaded; sources match"

if [ "$VARIANT" = g6 ]; then
  step 3 "build, guards, Q0, Q0m, then the chain -- detached on the server"
  R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c 'VARIANT=g6 bash $SRV_HOME/sync_server.sh build && VARIANT=g6 bash $SRV_HOME/sync_server.sh chain' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
  echo "   following ~/$VW/launch.log (about 20-30 min to the chain's start; Ctrl-C stops only this view)"
  seen=0
  for i in $(seq 1 90); do
    sleep 30
    out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: scripts/syncg6_all.sh pull)"; exit 0; }
    if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
    if echo "$out" | grep -q '^started:'; then break; fi
    if echo "$out" | grep -qE '^ERROR|stopped, exit code|Q0m FAILED'; then die "the build or Q0 / Q0m failed (above; ~/$VW/build_run.log) -- nothing was launched"; fi
  done
  echo
  echo "Started: Q0m, then the 12 runs (about 10 h), then Q0-full and Q3. No auto-resume: after a reboot, run this again."
  echo "Step 4 can start now: scripts/newbench_all.sh go"
  echo "Where it is:  scripts/syncg6_all.sh pull   (or scripts/pull_results.sh)"
  echo "log: $LOG"
  exit 0
fi

step 3 "build, guards, the tracer, Q0 (several minutes)"
# nohup: a dropped connection does not stop the build; its output stays in ~/$VW/build_run.log
# (the build includes QS, the tracer on the server's glibc)
R "VARIANT=$VARIANT nohup bash $SRV_HOME/sync_server.sh build 2>&1" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the build, Q0 or Q0b failed or the connection dropped (above; the server keeps ~/$VW/build_run.log) -- nothing was launched"

if [ "$VARIANT" = g5 ]; then step 4 "wait for the m2 traces, Q0m, then 12 runs (detached)"; else step 4 "trace 8 programs with sync records, then 12 runs"; fi
if [ "$VARIANT" = mx ]; then
  # traces made by another tracer are moved aside, with their runs (2026-10-20:
  # the tracer of 2026-10-19 missed every mutex lock and unlock on this glibc)
  R "VARIANT=mx bash $SRV_HOME/sync_server.sh refresh 2>&1" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || die "the refresh failed"
fi
R "$SV chain 2>&1" | sed 's/^/   /'
[ "${PIPESTATUS[0]}" -eq 0 ] || die "the chain did not start"

echo
if [ "$VARIANT" = g5 ]; then echo "Started: it waits for the m2 traces, checks Q0m, then 12 runs (about 10 h). No auto-resume: after a reboot, run this again."
else echo "Started: tracing (about 1-2 h), then 12 runs (about 10 h). No auto-resume: after a reboot, run this again."; fi
case "$VARIANT" in "") me=sync_all.sh ;; mx) me=syncmx_all.sh ;; g5) me=syncg5_all.sh ;; esac
echo "Where it is:  scripts/$me pull   (or scripts/pull_results.sh)"
echo "log: $LOG"
