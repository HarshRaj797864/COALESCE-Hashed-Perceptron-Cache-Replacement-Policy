#!/usr/bin/env bash
# Matched B3 windows (bench/policy_sanity/matched_b3_design_2026-11-17.md): the
# records-only instrument COHERENCE_POSITION_BINS. A copy of K2's launcher.
# Each step on the owner's word:
#
#   scripts/mw_all.sh check          # uploads the sources and the exact suite to ~/mw_build (NOT the main
#                                    # tree) and mw_server.sh (.new + mv); then, DETACHED on the server:
#                                    # build, guards, frozen bin/champsim_mw_<md5>, Q0, Q0m, K0 (QM0: the
#                                    # instrument off, against champsim_fc_a2e88e46), QM1. Starts NO run.
#   scripts/mw_all.sh go RUNSFILE    # uploads RUNSFILE as ~/mw/RUNS (label|reference tree|<wl>_<n>core|
#                                    # reference config|new tree; the keys step 1 and the checks admit),
#                                    # then the chain: each run with the instrument on, then QM2
#   scripts/mw_all.sh status         # read-only
#   scripts/mw_all.sh pull           # read-only: status, then the runs' logs to simulator/results/mw/
#   scripts/mw_all.sh stop           # ends the mw chain (only its own session)
#
# A dropped connection stops nothing.
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"   # overridable for a rehearsal from a copy
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
CB="$SRV_HOME/mw_build"
VW=mw
PREREG="bench/policy_sanity/matched_b3_design_2026-11-17.md"
SV="bash $SRV_HOME/mw_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
GUARDS="check_include_path check_fill_hook check_signatures"
MODE="${1:-}"
case "$MODE" in check|qm1|go|pull|stop|status) ;; *) echo "usage: $0 check|qm1|go|status|pull|stop"; exit 1 ;; esac
SUITE_FILES="bench/policy_sanity/check_coherence_exact.sh bench/policy_sanity/coherence_exact_traces.py"
OUTD="${OUTD:-$LROOT/simulator/results/mw}"
LOG="$OUTD/mw_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$OUTD"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0

if [ "$MODE" = check ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/mw_server.sh" || die "mw_server.sh does not parse"
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES $SUITE_FILES scripts/mw_server.sh scripts/mw_all.sh "$PREREG" \
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

if [ "$MODE" = status ]; then
  R "$SV status" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = qm1 ]; then   # amendment 1: QM1 again, same binary; uploads only mw_server.sh (.new + mv)
  bash -n "$LROOT/scripts/mw_server.sh" || { echo "mw_server.sh does not parse"; exit 1; }
  [ -z "$(git -C "$LROOT" status --porcelain -- scripts/mw_server.sh scripts/mw_all.sh "$PREREG")" ] || { echo "commit mw_server.sh, mw_all.sh and the note first"; exit 1; }
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/mw_server.sh" "$SRV:$SRV_HOME/mw_server.sh.new" && R "mv -f $SRV_HOME/mw_server.sh.new $SRV_HOME/mw_server.sh" \
    || { echo "upload of mw_server.sh failed"; exit 1; }
  [ "$(R "md5sum < $SRV_HOME/mw_server.sh" | cut -c1-32)" = "$(md5sum < "$LROOT/scripts/mw_server.sh" | cut -c1-32)" ] \
    || { echo "the uploaded mw_server.sh differs from the laptop's"; exit 1; }
  R "setsid nohup bash -c '$SV qm1' > $SRV_HOME/$VW/qm1_launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
  echo "QM1 (amendment 1) runs detached: 6 runs of 1 M + 2 M; see $0 status (CHECK PASSED in ~/$VW/check_run.log)"
  exit 0
fi
if [ "$MODE" = stop ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = go ]; then
  RUNS_IN="${2:-}"
  [ -s "$RUNS_IN" ] || { echo "usage: $0 go RUNSFILE (label|reference tree|<wl>_<n>core|reference config|new tree)"; exit 1; }
  awk -F'|' 'NF != 5 || $5 !~ /^phaseA_b3_mw_/ { bad = 1 } END { exit bad }' "$RUNS_IN" || { echo "$RUNS_IN: every line needs 5 fields and a phaseA_b3_mw_ tree"; exit 1; }
  R "mkdir -p $SRV_HOME/$VW" || exit 1
  "${RS[@]}" "$RUNS_IN" "$SRV:$SRV_HOME/$VW/RUNS.new" && R "mv -f $SRV_HOME/$VW/RUNS.new $SRV_HOME/$VW/RUNS" || { echo "upload of the runs list failed"; exit 1; }
  echo "   runs list: $(grep -c . "$RUNS_IN") runs ($(cut -d'|' -f1 "$RUNS_IN" | tr '\n' ' '))"
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
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='run.log' --include='cmd.txt' --include='qm2.txt' --exclude='*' "$SRV:$SR/results/phaseA_b3_mw_*" "$OUTD/logs/" \
    && echo "   pulled: the runs' logs to simulator/results/mw/logs/"
  "${RS[@]}" --include='driver.log' --include='build_run.log' --include='launch.log' --include='qm2.txt' --include='RUNS' --include='BIN' \
    --include='Q0_PASSED' --include='Q0M_PASSED' --include='K0_PASSED' --include='QM1_PASSED' --include='check_run.log' --include='qm1_launch.log' \
    --include='k0/' --include='k0/suite_*.txt' --exclude='*' "$SRV:$SRV_HOME/$VW/" "$OUTD/" || true
  echo "Score (once QM2 holds): python3 scripts/matched_b3.py score <run.log> <LOC rows> <count rows> <gem5 b3 rows> KEY LO HI"
  exit 0
fi

step 2 "upload the sources to $CB (the main tree is not touched) and mw_server.sh"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the mw chain is already running -- $0 pull"; fi
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
l=$(cd "$LROOT/simulator" && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc src/champsim.cc src/legacy_environment.cc scripts/make_config.py src/main.cc inc/sharer_directory.h | md5sum | cut -c1-32)
r=$(R "cd $CB/simulator && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc src/champsim.cc src/legacy_environment.cc scripts/make_config.py src/main.cc inc/sharer_directory.h | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "the uploaded sources do not match the laptop's"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/mw_server.sh" "$SRV:$SRV_HOME/mw_server.sh.new" || die "upload of mw_server.sh failed"
R "mv -f $SRV_HOME/mw_server.sh.new $SRV_HOME/mw_server.sh" || die "mv of mw_server.sh failed"
echo "   sources, guards, the exact suite and mw_server.sh uploaded; sources match"

step 3 "build, guards, Q0, Q0m, K0, QM1 -- detached on the server; no run starts"
R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c '$SV check' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
echo "   following ~/$VW/launch.log for ${FOLLOW_N:-10} polls (the whole check takes 1-2 h; Ctrl-C stops only this view)"
seen=0
started=0
for _ in $(seq 1 "${FOLLOW_N:-10}"); do
  sleep "${FOLLOW_S:-30}"
  out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: $0 pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^CHECK PASSED'; then started=1; break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then die "the build, Q0, Q0m, K0 or QM1 failed (above; ~/$VW/check_run.log) -- nothing was launched"; fi
done
echo
if [ "$started" = 1 ]; then
  echo "The check passed. The runs start only with:  $0 go RUNSFILE  (owner's word)"
else
  echo "STILL CHECKING: the build, Q0, Q0m, K0 or QM1 is running on the server (detached; this view stopped following)."
  echo "Nothing starts by itself: a pass is printed as CHECK PASSED in ~/$VW/launch.log; then $0 go RUNSFILE (owner's word)."
fi
echo "Where it is:  $0 pull"
echo "log: $LOG"
