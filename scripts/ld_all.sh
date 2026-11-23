#!/usr/bin/env bash
# C, load-side communication against gem5 (bench/policy_sanity/load_side_design_2026-11-18.md):
# the records-only counters LOAD / OTHER-READ GEM5-RULE OWNER EVENTS. A copy of mw_all.sh.
# Each step on the owner's word:
#
#   scripts/ld_all.sh check          # uploads the sources, the exact suite and the micro harness to ~/ld_build
#                                    # (NOT the main tree) and ld_server.sh (.new + mv); then, DETACHED on the
#                                    # server: build, guards, frozen bin/champsim_ld_<md5>, QC0 (Q0, Q0m, K0
#                                    # against champsim_fc_a2e88e46), then QC1a (ChampSim micro) and QC1b
#                                    # (gem5 micro, 20 short runs). Starts NO B3 run.
#   scripts/ld_all.sh go RUNSFILE    # uploads RUNSFILE as ~/ld/RUNS (label|reference tree|<wl>_<n>core|
#                                    # reference config|new tree), then the chain (needs QC0): each run, then QC2
#   scripts/ld_all.sh status         # read-only
#   scripts/ld_all.sh pull           # read-only: status, then the runs' logs and the checks to simulator/results/ld/
#   scripts/ld_all.sh stop           # ends the ld chain (only its own session)
#
# A dropped connection stops nothing.
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"   # overridable for a rehearsal from a copy
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
CB="$SRV_HOME/ld_build"
VW=ld
PREREG="bench/policy_sanity/load_side_design_2026-11-18.md"
SV="bash $SRV_HOME/ld_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
GUARDS="check_include_path check_fill_hook check_signatures"
MODE="${1:-}"
case "$MODE" in check|go|pull|stop|status) ;; *) echo "usage: $0 check|go|status|pull|stop"; exit 1 ;; esac
SUITE_FILES="bench/policy_sanity/check_coherence_exact.sh bench/policy_sanity/coherence_exact_traces.py"
MICRO_FILES="bench/micro_champsim.sh bench/micro_trim.py bench/coherence_micro.c bench/ld_micro_judge.py"
OUTD="${OUTD:-$LROOT/simulator/results/ld}"
LOG="$OUTD/ld_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$OUTD"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0

if [ "$MODE" = check ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/ld_server.sh" || die "ld_server.sh does not parse"
  python3 "$LROOT/bench/ld_micro_judge.py" selftest > /dev/null || die "ld_micro_judge.py selftest fails"
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES $SUITE_FILES $MICRO_FILES scripts/ld_server.sh scripts/ld_all.sh "$PREREG" \
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
if [ "$MODE" = stop ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = go ]; then
  RUNS_IN="${2:-}"
  [ -s "$RUNS_IN" ] || { echo "usage: $0 go RUNSFILE (label|reference tree|<wl>_<n>core|reference config|new tree)"; exit 1; }
  awk -F'|' 'NF != 5 || $5 !~ /^phaseA_b3_ld_/ { bad = 1 } END { exit bad }' "$RUNS_IN" || { echo "$RUNS_IN: every line needs 5 fields and a phaseA_b3_ld_ tree"; exit 1; }
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
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='run.log' --include='cmd.txt' --include='qc2.txt' --exclude='*' "$SRV:$SR/results/phaseA_b3_ld_*" "$OUTD/logs/" \
    && echo "   pulled: the runs' logs to simulator/results/ld/logs/"
  "${RS[@]}" --include='driver.log' --include='launch.log' --include='qc2.txt' --include='RUNS' --include='BIN' \
    --include='Q0_PASSED' --include='Q0M_PASSED' --include='K0_PASSED' --include='QC1A_PASSED' --include='QC1B_PASSED' --include='check_run.log' \
    --include='qc1a.txt' --include='qc1b.txt' --include='qc1a_run.log' --include='qc1b_run.log' --include='qc1a_harness.log' \
    --include='k0/' --include='k0/suite_*.txt' --include='micro_cs/' --include='micro_cs/*.log' --include='micro_cs/*.xline' --include='micro_cs/summary.txt' \
    --include='g5micro/' --include='g5micro/gem5/' --include='g5micro/gem5/*/' --include='g5micro/gem5/*/stats.txt' --include='g5micro/gem5/*/run.log' --include='g5micro/gem5/*/config.ini' \
    --exclude='*' "$SRV:$SRV_HOME/$VW/" "$OUTD/" || true
  echo "Judge locally: python3 bench/ld_micro_judge.py cs $OUTD/micro_cs (needs the event logs: QC1a's verdict is in qc1a.txt) and g5 $OUTD/g5micro/gem5"
  echo "Score (once QC1a, QC1b and QC2 hold): python3 scripts/ld_score.py"
  exit 0
fi

step 2 "upload the sources, suite and micro harness to $CB (the main tree is not touched) and ld_server.sh"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the ld chain is already running -- $0 pull"; fi
R "mkdir -p $CB/simulator $CB/bench/policy_sanity" || die "cannot create $CB"
for d in $SRC_DIRS; do
  "${RS[@]}" --delete "$LROOT/$d/" "$SRV:$CB/$d/" || die "rsync of $d failed"
done
for f in $FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
for g in $GUARDS; do
  "${RS[@]}" "$LROOT/bench/policy_sanity/$g.sh" "$SRV:$CB/bench/policy_sanity/$g.sh" || die "rsync of $g.sh failed"
done
for f in $SUITE_FILES $MICRO_FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || die "rsync of $f failed"; done
R "rm -f $CB/simulator/absolute.options $CB/simulator/_configuration.mk; rm -rf $CB/simulator/.csconfig"
l=$(cd "$LROOT/simulator" && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc src/champsim.cc src/legacy_environment.cc scripts/make_config.py src/main.cc inc/sharer_directory.h | md5sum | cut -c1-32)
r=$(R "cd $CB/simulator && cat src/cache.cc src/ooo_cpu.cc src/sync_replay.cc inc/sync_replay.h src/sharer_directory.cc src/plain_printer.cc src/champsim.cc src/legacy_environment.cc scripts/make_config.py src/main.cc inc/sharer_directory.h | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "the uploaded sources do not match the laptop's"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/ld_server.sh" "$SRV:$SRV_HOME/ld_server.sh.new" || die "upload of ld_server.sh failed"
R "mv -f $SRV_HOME/ld_server.sh.new $SRV_HOME/ld_server.sh" || die "mv of ld_server.sh failed"
[ "$(R "md5sum < $SRV_HOME/ld_server.sh" | cut -c1-32)" = "$(md5sum < "$LROOT/scripts/ld_server.sh" | cut -c1-32)" ] || die "the uploaded ld_server.sh differs from the laptop's"
for f in $MICRO_FILES; do [ "$(R "md5sum < $CB/$f" | cut -c1-32)" = "$(md5sum < "$LROOT/$f" | cut -c1-32)" ] || die "the uploaded $f differs from the laptop's"; done
echo "   sources, guards, the exact suite, the micro harness and ld_server.sh uploaded; all match"

step 3 "build, guards, QC0 (Q0, Q0m, K0), QC1a, QC1b -- detached on the server; no B3 run starts"
R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c '$SV check' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
echo "   following ~/$VW/launch.log for ${FOLLOW_N:-10} polls (the whole check takes 1-2 h; Ctrl-C stops only this view)"
seen=0
started=0
for _ in $(seq 1 "${FOLLOW_N:-10}"); do
  sleep "${FOLLOW_S:-30}"
  out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: $0 pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^QC0 PASSED'; then started=1; fi
  if echo "$out" | grep -q '^CHECK PASSED'; then started=2; break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then die "the build, QC0 or QC1 failed (above; ~/$VW/check_run.log) -- nothing was launched"; fi
done
echo
if [ "$started" = 2 ]; then
  echo "The whole check passed (QC0, QC1a, QC1b). The runs start only with:  $0 go RUNSFILE  (owner's word)"
elif [ "$started" = 1 ]; then
  echo "QC0 passed; QC1a and QC1b are running (detached). The runs may start:  $0 go RUNSFILE  (owner's word); nothing is scored before QC1 holds."
else
  echo "STILL CHECKING: the build or QC0 is running on the server (detached; this view stopped following)."
  echo "Nothing starts by itself: QC0 PASSED / CHECK PASSED appear in ~/$VW/launch.log; then $0 go RUNSFILE (owner's word)."
fi
echo "Where it is:  $0 pull"
echo "log: $LOG"
