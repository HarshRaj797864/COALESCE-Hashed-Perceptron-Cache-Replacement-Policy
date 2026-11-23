#!/usr/bin/env bash
# The published SRRIP row (bench/policy_sanity/srrip_pub_design_2026-11-18.md): replacement/srrip_pub
# on the 19 step-5 SRRIP jobs. A copy of ld_all.sh. Each step on the owner's word:
#
#   scripts/sp_all.sh check     # uploads the sources and guards to ~/sp_build (NOT the main tree) and
#                               # sp_server.sh (.new + mv); then, DETACHED on the server: build, guards,
#                               # frozen bin/champsim_sp_<md5>, QS0 (against champsim_g6_1e3060c1). Starts NO run.
#   scripts/sp_all.sh go        # the chain: the 19 runs (step 5's JOBS, policy srrip), QS1 each
#   scripts/sp_all.sh status    # read-only
#   scripts/sp_all.sh pull      # read-only: status, then the runs' logs to simulator/results/sp/
#   scripts/sp_all.sh stop      # ends the sp chain (only its own session)
#
# A dropped connection stops nothing.
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"   # overridable for a rehearsal from a copy
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
CB="$SRV_HOME/sp_build"
VW=sp
PREREG="bench/policy_sanity/srrip_pub_design_2026-11-18.md"
SV="bash $SRV_HOME/sp_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
GUARDS="check_include_path check_fill_hook check_signatures"
MODE="${1:-}"
case "$MODE" in check|go|pull|stop|status) ;; *) echo "usage: $0 check|go|status|pull|stop"; exit 1 ;; esac
SUITE_FILES=""
MICRO_FILES=""
OUTD="${OUTD:-$LROOT/simulator/results/sp}"
LOG="$OUTD/sp_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$OUTD"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0

if [ "$MODE" = check ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/sp_server.sh" || die "sp_server.sh does not parse"
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || die "the pre-registration is not committed"
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES $SUITE_FILES $MICRO_FILES scripts/sp_server.sh scripts/sp_all.sh "$PREREG" \
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
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='run.log' --include='run.log.bin' --include='qs1.txt' --exclude='*' "$SRV:$SR/results/phaseA_b3_sp_*" "$OUTD/logs/" \
    && echo "   pulled: the runs' logs to simulator/results/sp/logs/"
  "${RS[@]}" --include='driver.log' --include='launch.log' --include='BIN' --include='QS0_PASSED' --include='check_run.log' \
    --include='qs0/' --include='qs0/*.log' --include='cfg/' --include='cfg/*.json' --exclude='*' "$SRV:$SRV_HOME/$VW/" "$OUTD/" || true
  echo "Score: python3 scripts/sp_score.py"
  exit 0
fi

step 2 "upload the sources and guards to $CB (the main tree is not touched) and sp_server.sh"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the sp chain is already running -- $0 pull"; fi
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
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/sp_server.sh" "$SRV:$SRV_HOME/sp_server.sh.new" || die "upload of sp_server.sh failed"
R "mv -f $SRV_HOME/sp_server.sh.new $SRV_HOME/sp_server.sh" || die "mv of sp_server.sh failed"
[ "$(R "md5sum < $SRV_HOME/sp_server.sh" | cut -c1-32)" = "$(md5sum < "$LROOT/scripts/sp_server.sh" | cut -c1-32)" ] || die "the uploaded sp_server.sh differs from the laptop's"
for f in $MICRO_FILES; do [ "$(R "md5sum < $CB/$f" | cut -c1-32)" = "$(md5sum < "$LROOT/$f" | cut -c1-32)" ] || die "the uploaded $f differs from the laptop's"; done
echo "   sources, guards and sp_server.sh uploaded; all match"

step 3 "build, guards, QS0 -- detached on the server; no run starts"
R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c '$SV check' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
echo "   following ~/$VW/launch.log for ${FOLLOW_N:-10} polls (the whole check takes 1-2 h; Ctrl-C stops only this view)"
seen=0
started=0
for _ in $(seq 1 "${FOLLOW_N:-10}"); do
  sleep "${FOLLOW_S:-30}"
  out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: $0 pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^CHECK PASSED'; then started=2; break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then die "the build, guards or QS0 failed (above; ~/$VW/check_run.log) -- nothing was launched"; fi
done
echo
if [ "$started" = 2 ]; then
  echo "The check passed (guards, QS0). The runs start only with:  $0 go  (owner's word)"
else
  echo "STILL CHECKING: the build or QS0 is running on the server (detached; this view stopped following)."
  echo "Nothing starts by itself: CHECK PASSED appears in ~/$VW/launch.log; then $0 go (owner's word)."
fi
echo "Where it is:  $0 pull"
echo "log: $LOG"
