#!/usr/bin/env bash
# Round 2, step 1 (bench/policy_sanity/lock_wait_design_2026-11-06.md): the
# records-only counter of mutex acquires that waited. Uploads the sources to
# ~/sync_lc_build (NOT the main tree) and lockwait_server.sh (.new + mv); then,
# DETACHED on the server: build, guards, frozen bin/champsim_lc_<md5>, Q0 and
# Q0m against champsim_g6_1e3060c1, and the chain -- round 1's 14 spans rerun
# into results/phaseA_b3_lc_*, then Q0-full against the scored logs. A dropped
# connection stops nothing.
#
#   scripts/lockwait_all.sh          # from the repo root, on the LAPTOP (owner's word)
#   scripts/lockwait_all.sh pull     # read-only: status, then the reruns' logs to simulator/results/lockwait/
#   scripts/lockwait_all.sh stop     # ends the lc chain (only its own session)
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"   # overridable for a rehearsal from a copy
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
CB="$SRV_HOME/sync_lc_build"
VW=sync_lc
PREREG="bench/policy_sanity/lock_wait_design_2026-11-06.md"
SV="bash $SRV_HOME/lockwait_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
GUARDS="check_include_path check_fill_hook check_signatures"
MODE="${1:-}"
case "$MODE" in ""|pull|stop) ;; *) echo "usage: $0 [pull|stop]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/lockwait}"
LOG="$OUTD/lockwait_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$OUTD"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0

if [ -z "$MODE" ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/lockwait_server.sh" || die "lockwait_server.sh does not parse"
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES scripts/lockwait_server.sh scripts/lockwait_all.sh "$PREREG" \
          $(for g in $GUARDS; do echo "bench/policy_sanity/$g.sh"; done))
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-$VW-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

if [ "$MODE" = stop ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = pull ]; then
  R "$SV status" | sed 's/^/   /'
  echo "   -- end of ~/$VW/launch.log:"
  R "tail -n 8 $SRV_HOME/$VW/launch.log 2>/dev/null || echo '(no launch log)'" | sed 's/^/      /'
  mkdir -p "$OUTD/logs"
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='run.log' --include='cmd.txt' --exclude='*' "$SRV:$SR/results/phaseA_b3_lc_*" "$OUTD/logs/" \
    && echo "   pulled: the reruns' logs to simulator/results/lockwait/logs/"
  "${RS[@]}" --include='driver.log' --include='build_run.log' --include='launch.log' --include='q0full.txt' --include='BIN' \
    --include='Q0_PASSED' --include='Q0M_PASSED' --exclude='*' "$SRV:$SRV_HOME/$VW/" "$OUTD/" || true
  echo "Score (once every rerun is complete and Q0-full reads 14 identical): python3 scripts/lock_wait_score.py"
  exit 0
fi

step 2 "upload the sources to $CB (the main tree is not touched) and lockwait_server.sh"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the lc chain is already running -- $0 pull"; fi
R "mkdir -p $CB/simulator $CB/bench/policy_sanity" || die "cannot create $CB"
for d in $SRC_DIRS; do
  "${RS[@]}" --delete "$LROOT/$d/" "$SRV:$CB/$d/" || die "rsync of $d failed"
done
for f in $FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
for g in $GUARDS; do
  "${RS[@]}" "$LROOT/bench/policy_sanity/$g.sh" "$SRV:$CB/bench/policy_sanity/$g.sh" || die "rsync of $g.sh failed"
done
R "rm -f $CB/simulator/absolute.options $CB/simulator/_configuration.mk; rm -rf $CB/simulator/.csconfig"
l=$(cd "$LROOT/simulator" && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc | md5sum | cut -c1-32)
r=$(R "cd $CB/simulator && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "the uploaded sources do not match the laptop's"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/lockwait_server.sh" "$SRV:$SRV_HOME/lockwait_server.sh.new" || die "upload of lockwait_server.sh failed"
R "mv -f $SRV_HOME/lockwait_server.sh.new $SRV_HOME/lockwait_server.sh" || die "mv of lockwait_server.sh failed"
echo "   sources, guards and lockwait_server.sh uploaded; sources match"

step 3 "build, guards, Q0, Q0m, then the chain -- detached on the server"
R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c '$SV build && $SV chain' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
echo "   following ~/$VW/launch.log (the build and Q0 take about 20-40 min; Ctrl-C stops only this view)"
seen=0
started=0
for _ in $(seq 1 120); do
  sleep "${FOLLOW_S:-30}"
  out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: $0 pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^started:'; then started=1; break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then die "the build, Q0 or Q0m failed (above; ~/$VW/build_run.log) -- nothing was launched"; fi
done
echo
if [ "$started" = 1 ]; then
  echo "Started: 14 reruns, then Q0-full. No auto-resume: after a reboot, run this again (complete reruns are skipped)."
else
  # found by the 2026-11-10 rehearsal: the view used to print "Started" here while Q0 was still running
  echo "NOT STARTED YET: the build, Q0 or Q0m is still running on the server (detached; this view stopped following)."
  echo "If they pass, the chain starts by itself; if one fails, nothing is launched. Check with the pull below."
fi
echo "Where it is:  $0 pull"
echo "log: $LOG"
