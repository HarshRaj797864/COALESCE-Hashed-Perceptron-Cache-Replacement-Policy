#!/usr/bin/env bash
# F-C (bench/policy_sanity/lock_fix_design_2026-11-12.md): a contended mutex
# waiter issues one ownership request for the lock word. A copy of
# lockwait_all.sh. Two steps since amendment 2 (2026-11-12), each on the owner's word:
#
#   scripts/lockfix_all.sh check    # uploads the sources and the exact suite to ~/sync_fc_build (NOT the
#                                   # main tree) and lockfix_server.sh (.new + mv); then, DETACHED on the
#                                   # server: build, guards, frozen bin/champsim_fc_<md5>, Q0 and Q0m (the
#                                   # setting absent) against the lock-wait binary champsim_lc_c601b4e4,
#                                   # Q0r (request, 1 M + 2 M), K0 (the exact suite with both binaries).
#                                   # Starts NO rerun.
#   scripts/lockfix_all.sh go       # the chain on the checked binary: the lock-wait set's 14 spans with
#                                   # sync_lock_word request into results/phaseA_b3_fc_*, then Q3
#   scripts/lockfix_all.sh pull     # read-only: status, then the reruns' logs to simulator/results/lockfix/
#   scripts/lockfix_all.sh stop     # ends the fc chain (only its own session)
#
# A dropped connection stops nothing.
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"   # overridable for a rehearsal from a copy
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
CB="$SRV_HOME/sync_fc_build"
VW=sync_fc
PREREG="bench/policy_sanity/lock_fix_design_2026-11-12.md"
SV="bash $SRV_HOME/lockfix_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
GUARDS="check_include_path check_fill_hook check_signatures"
MODE="${1:-}"
case "$MODE" in check|go|pull|stop) ;; *) echo "usage: $0 check|go|pull|stop"; exit 1 ;; esac
SUITE_FILES="bench/policy_sanity/check_coherence_exact.sh bench/policy_sanity/coherence_exact_traces.py"
OUTD="${OUTD:-$LROOT/simulator/results/lockfix}"
LOG="$OUTD/lockfix_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$OUTD"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0

if [ "$MODE" = check ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/lockfix_server.sh" || die "lockfix_server.sh does not parse"
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES $SUITE_FILES scripts/lockfix_server.sh scripts/lockfix_all.sh "$PREREG" \
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
if [ "$MODE" = go ]; then
  R "$SV status" | sed 's/^/   /'
  R "$SV chain" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" = 0 ] || { echo "NOT started (above)"; exit 1; }
  echo "Where it is:  $0 pull"
  exit 0
fi
if [ "$MODE" = pull ]; then
  R "$SV status" | sed 's/^/   /'
  echo "   -- end of ~/$VW/launch.log:"
  R "tail -n 8 $SRV_HOME/$VW/launch.log 2>/dev/null || echo '(no launch log)'" | sed 's/^/      /'
  mkdir -p "$OUTD/logs"
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='run.log' --include='cmd.txt' --exclude='*' "$SRV:$SR/results/phaseA_b3_fc_*" "$OUTD/logs/" \
    && echo "   pulled: the reruns' logs to simulator/results/lockfix/logs/"
  "${RS[@]}" --include='driver.log' --include='build_run.log' --include='launch.log' --include='q3.txt' --include='BIN' \
    --include='Q0_PASSED' --include='Q0M_PASSED' --include='Q0R_PASSED' --include='K0_PASSED' --include='check_run.log' \
    --include='k0/' --include='k0/suite_*.txt' --include='cfg/' --include='cfg/*.json' --exclude='*' "$SRV:$SRV_HOME/$VW/" "$OUTD/" || true
  echo "Score (once every rerun is complete and Q3 reads 14 hold): python3 scripts/lock_fix_score.py"
  exit 0
fi

step 2 "upload the sources to $CB (the main tree is not touched) and lockfix_server.sh"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the fc chain is already running -- $0 pull"; fi
R "mkdir -p $CB/simulator $CB/bench/policy_sanity" || die "cannot create $CB"
for d in $SRC_DIRS; do
  "${RS[@]}" --delete "$LROOT/$d/" "$SRV:$CB/$d/" || die "rsync of $d failed"
done
for f in $FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
for g in $GUARDS; do
  "${RS[@]}" "$LROOT/bench/policy_sanity/$g.sh" "$SRV:$CB/bench/policy_sanity/$g.sh" || die "rsync of $g.sh failed"
done
for f in $SUITE_FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
R "rm -f $CB/simulator/absolute.options $CB/simulator/_configuration.mk; rm -rf $CB/simulator/.csconfig"
l=$(cd "$LROOT/simulator" && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc | md5sum | cut -c1-32)
r=$(R "cd $CB/simulator && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "the uploaded sources do not match the laptop's"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/lockfix_server.sh" "$SRV:$SRV_HOME/lockfix_server.sh.new" || die "upload of lockfix_server.sh failed"
R "mv -f $SRV_HOME/lockfix_server.sh.new $SRV_HOME/lockfix_server.sh" || die "mv of lockfix_server.sh failed"
echo "   sources, guards, the exact suite and lockfix_server.sh uploaded; sources match"

step 3 "build, guards, Q0, Q0m, Q0r, K0 -- detached on the server; no rerun starts"
R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c '$SV check' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
echo "   following ~/$VW/launch.log for ${FOLLOW_N:-10} polls (the whole check takes 1-2 h; Ctrl-C stops only this view)"
seen=0
started=0
for _ in $(seq 1 "${FOLLOW_N:-10}"); do
  sleep "${FOLLOW_S:-30}"
  out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: $0 pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^CHECK PASSED'; then started=1; break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then die "the build, Q0, Q0m, Q0r or K0 failed (above; ~/$VW/check_run.log) -- nothing was launched"; fi
done
echo
if [ "$started" = 1 ]; then
  echo "The check passed. The 14 reruns start only with:  $0 go  (owner's word)"
else
  echo "STILL CHECKING: the build, Q0, Q0m, Q0r or K0 is running on the server (detached; this view stopped following)."
  echo "Nothing starts by itself: a pass is printed as CHECK PASSED in ~/$VW/launch.log; then $0 go (owner's word)."
fi
echo "Where it is:  $0 pull"
echo "log: $LOG"
