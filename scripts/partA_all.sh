#!/usr/bin/env bash
# Part A (bench/policy_sanity/upstream_equiv_design_2026-11-10.md): our
# ChampSim with the extension off against upstream ChampSim f9ed890e, on the
# server. Uploads our sources to ~/partA_ours_build and upstream's tree (git
# archive f9ed890e of the laptop's ChampSim clone) to ~/partA_up_build -- NOT
# the main tree -- and partA_server.sh (.new + mv); then, DETACHED on the
# server: both builds, guards, frozen binaries, E0 (the upstream checksum,
# every trace counted, the configs), and the chain of 185 runs. A dropped
# connection stops nothing.
#
#   scripts/partA_all.sh          # from the repo root, on the LAPTOP (owner's word)
#   scripts/partA_all.sh pull     # read-only: status, then the logs to simulator/results/partA/logs/
#   scripts/partA_all.sh stop     # ends the partA chain (only its own session)
#   scripts/partA_all.sh add16    # (owner's word; once the 185 runs have ended) amendment 3: uploads
#                                 # partA_server.sh (.new + mv), writes the 16-core configs (e0_16) and
#                                 # starts the chain again: the 185 done are skipped, 22 runs added
#   scripts/partA_all.sh add16wait  # (owner's word, 2026-11-13; amendment 5) the same, made to wait on the
#                                 # server: stages the runner as ~/partA_server.sh.add16 (the live file is
#                                 # not touched), starts ~/partA_add16_wait.sh detached; it runs add16's
#                                 # server half once the chain has ended (log ~/partA/add16_wait.log)
#
# Score: python3 scripts/upstream_equiv.py dir simulator/results/partA/logs   (E1)
#        python3 scripts/upstream_equiv.py e2  simulator/results/partA/logs   (E2)
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
LROOT="${LROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
UPREPO="${UPREPO:-$HOME/programming-playground/repos/ChampSim}"
UPCOMMIT=f9ed890e9477649c24b8defc4d789fbecbc1e7d5
SRV_HOME="${SRV_HOME:-/home/harshraj}"
SR="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
OB="$SRV_HOME/partA_ours_build"
UB="$SRV_HOME/partA_up_build"
VW=partA
PREREG="bench/policy_sanity/upstream_equiv_design_2026-11-10.md"
SV="bash $SRV_HOME/partA_server.sh"
SRC_DIRS="simulator/inc simulator/src simulator/branch simulator/btb simulator/prefetcher simulator/replacement simulator/config simulator/test simulator/scripts"
FILES="simulator/Makefile simulator/global.options simulator/module.options simulator/vcpkg.json"
GUARDS="check_include_path check_fill_hook check_signatures"
MODE="${1:-}"
case "$MODE" in ""|pull|stop|add16|add16wait) ;; *) echo "usage: $0 [pull|stop|add16|add16wait]"; exit 1 ;; esac
OUTD="${OUTD:-$LROOT/simulator/results/partA}"
LOG="$OUTD/partA_all_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$OUTD"
exec > >(tee -a "$LOG") 2>&1

die() { echo; echo "STOPPED at step $STEP: $*"; echo "log: $LOG"; exit 1; }
step() { STEP="$1"; echo; echo "================ $1/3  $2 ================"; }
STEP=0
TMPD=""
cleanup_tmp() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }

if [ -z "$MODE" ]; then
  step 1 "local checks"
  bash -n "$LROOT/scripts/partA_server.sh" || die "partA_server.sh does not parse"
  for f in "$PREREG" scripts/upstream_equiv.py scripts/upstream_equiv_allow.txt; do
    git -C "$LROOT" ls-files --error-unmatch "$f" > /dev/null 2>&1 || die "$f is not committed"
  done
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $SRC_DIRS $FILES scripts/partA_server.sh scripts/partA_all.sh "$PREREG" \
          scripts/upstream_equiv.py scripts/upstream_equiv_allow.txt $(for g in $GUARDS; do echo "bench/policy_sanity/$g.sh"; done))
  [ -z "$dirty" ] || { echo "$dirty"; die "uncommitted changes in what is uploaded -- commit first"; }
  [ "$(git -C "$UPREPO" rev-parse "$UPCOMMIT^{commit}" 2>/dev/null)" = "$UPCOMMIT" ] || die "no commit $UPCOMMIT in $UPREPO"
  TMPD=$(mktemp -d); trap cleanup_tmp EXIT
  git -C "$UPREPO" archive "$UPCOMMIT" | tar -x -C "$TMPD" || die "git archive of $UPCOMMIT failed"
  um=$( cd "$TMPD" && find . -type f -not -path './vcpkg*' | LC_ALL=C sort | xargs md5sum | md5sum | cut -c1-32 )
  echo "   committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
  echo "   upstream $UPCOMMIT archived; source checksum $um"
fi

CTL="$HOME/.ssh/cm-$VW-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; cleanup_tmp; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

if [ "$MODE" = stop ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = add16wait ]; then
  STEP=1
  bash -n "$LROOT/scripts/partA_server.sh" && bash -n "$LROOT/scripts/partA_add16_wait.sh" || die "a script does not parse"
  [ -z "$(git -C "$LROOT" status --porcelain -- scripts/partA_server.sh scripts/partA_all.sh scripts/partA_add16_wait.sh "$PREREG")" ] \
    || die "uncommitted changes in partA_server.sh / partA_all.sh / partA_add16_wait.sh / the design -- commit first"
  git -C "$LROOT" ls-files --error-unmatch scripts/partA_add16_wait.sh > /dev/null 2>&1 || die "partA_add16_wait.sh is not committed"
  grep -q '^## Amendment 5, ' "$LROOT/$PREREG" || die "$PREREG has no amendment 5 (the waiter)"
  if R "[ -f $SRV_HOME/$VW/.add16_wait.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.add16_wait.pid 2>/dev/null) 2>/dev/null"; then die "a waiter is running already ($0 pull)"; fi
  l=$(md5sum < "$LROOT/scripts/partA_server.sh" | cut -c1-32)
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/partA_server.sh" "$SRV:$SRV_HOME/partA_server.sh.add16.new" || die "upload of the runner failed"
  R "mv -f $SRV_HOME/partA_server.sh.add16.new $SRV_HOME/partA_server.sh.add16" || die "mv of the staged runner failed"
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/partA_add16_wait.sh" "$SRV:$SRV_HOME/partA_add16_wait.sh.new" || die "upload of the waiter failed"
  R "mv -f $SRV_HOME/partA_add16_wait.sh.new $SRV_HOME/partA_add16_wait.sh" || die "mv of the waiter failed"
  r=$(R "md5sum < $SRV_HOME/partA_server.sh.add16 | cut -c1-32")
  [ "$l" = "$r" ] || die "~/partA_server.sh.add16 reads $r, the laptop's $l"
  echo "   staged: ~/partA_server.sh.add16 ($(git -C "$LROOT" log -1 --format=%h -- scripts/partA_server.sh), md5 ${l:0:8}); the live ~/partA_server.sh untouched"
  R "setsid nohup bash $SRV_HOME/partA_add16_wait.sh $l >> $SRV_HOME/$VW/add16_wait.log 2>&1 < /dev/null & sleep 3; tail -n 3 $SRV_HOME/$VW/add16_wait.log" | sed 's/^/   /'
  R "kill -0 \$(cat $SRV_HOME/$VW/.add16_wait.pid 2>/dev/null) 2>/dev/null" || die "the waiter is not running (log ~/$VW/add16_wait.log)"
  echo "Waiting on the server: once the chain ends, e0_16 and the chain again (16a, 16b). Where it is:  $0 pull"
  exit 0
fi
if [ "$MODE" = add16 ]; then
  STEP=1
  bash -n "$LROOT/scripts/partA_server.sh" || die "partA_server.sh does not parse"
  git -C "$LROOT" ls-files --error-unmatch scripts/partA_server.sh > /dev/null 2>&1 || die "partA_server.sh is not committed"
  [ -z "$(git -C "$LROOT" status --porcelain -- scripts/partA_server.sh scripts/partA_all.sh "$PREREG")" ] || die "uncommitted changes in partA_server.sh / partA_all.sh / the design -- commit first"
  grep -q '^## Amendment 4, ' "$LROOT/$PREREG" || die "$PREREG has no amendment 4 (the 16-core runner change and its rehearsal)"
  if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the partA chain is still running -- the 16-core runs are added after it ends ($0 pull)"; fi
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/partA_server.sh" "$SRV:$SRV_HOME/partA_server.sh.new" || die "upload of partA_server.sh failed"
  R "mv -f $SRV_HOME/partA_server.sh.new $SRV_HOME/partA_server.sh" || die "mv of partA_server.sh failed"
  l=$(md5sum < "$LROOT/scripts/partA_server.sh" | cut -c1-32); r=$(R "md5sum < $SRV_HOME/partA_server.sh | cut -c1-32")
  [ "$l" = "$r" ] || die "~/partA_server.sh reads $r, the laptop's $l"
  echo "   partA_server.sh uploaded ($(git -C "$LROOT" log -1 --format=%h))"
  R "$SV e0_16" 2>&1 | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || die "e0_16 failed (above) -- nothing added"
  R "$SV chain" 2>&1 | sed 's/^/   /'; [ "${PIPESTATUS[0]}" = 0 ] || die "the chain did not start (above)"
  sleep "${FOLLOW_S:-20}"
  R "$SV status" 2>&1 | sed 's/^/   /'
  echo "Added: 16a and 16b (20 runs for E1, 2 for E2); the 185 earlier runs are skipped if made by the same frozen binaries."
  echo "Where it is:  $0 pull      log: $LOG"
  exit 0
fi
if [ "$MODE" = pull ]; then
  R "$SV status" | sed 's/^/   /'
  R "[ -f $SRV_HOME/$VW/add16_wait.log ] && { echo '   -- add16 waiter:'; tail -n 3 $SRV_HOME/$VW/add16_wait.log | sed 's/^/      /'; }; true"
  echo "   -- end of ~/$VW/launch.log:"
  R "tail -n 8 $SRV_HOME/$VW/launch.log 2>/dev/null || echo '(no launch log)'" | sed 's/^/      /'
  mkdir -p "$OUTD/logs"
  "${RS[@]}" --include='*.log' --include='*.log.bin' --exclude='*' "$SRV:$SR/results/partA/" "$OUTD/logs/" \
    && echo "   pulled: $(ls "$OUTD/logs" | grep -c '\.log$') logs (+ each one's binary, <log>.bin) to simulator/results/partA/logs/"
  "${RS[@]}" --include='driver.log' --include='build_run.log' --include='launch.log' --include='tracelen.txt' --include='BIN_*' \
    --include='E0_PASSED' --exclude='*' "$SRV:$SRV_HOME/$VW/" "$OUTD/" || true
  echo "Score (once every run is complete): python3 scripts/upstream_equiv.py dir simulator/results/partA/logs   (E1)"
  echo "                                    python3 scripts/upstream_equiv.py e2  simulator/results/partA/logs   (E2)"
  exit 0
fi

step 2 "upload our sources to $OB, upstream's to $UB (the main tree is not touched), and partA_server.sh"
if R "[ -f $SRV_HOME/$VW/.driver.pid ] && kill -0 \$(cat $SRV_HOME/$VW/.driver.pid 2>/dev/null) 2>/dev/null"; then die "the partA chain is already running -- $0 pull"; fi
R "mkdir -p $OB/simulator $OB/bench/policy_sanity $UB" || die "cannot create the build trees"
for d in $SRC_DIRS; do
  "${RS[@]}" --delete "$LROOT/$d/" "$SRV:$OB/$d/" || die "rsync of $d failed"
done
for f in $FILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$OB/$f" || die "rsync of $f failed"; done
for g in $GUARDS; do
  "${RS[@]}" "$LROOT/bench/policy_sanity/$g.sh" "$SRV:$OB/bench/policy_sanity/$g.sh" || die "rsync of $g.sh failed"
done
R "rm -f $OB/simulator/absolute.options $OB/simulator/_configuration.mk; rm -rf $OB/simulator/.csconfig"
"${RS[@]}" --delete "$TMPD/" "$SRV:$UB/" || die "rsync of upstream's tree failed"
l=$(cd "$LROOT/simulator" && cat src/cache.cc src/ooo_cpu.cc src/main.cc src/legacy_environment.cc src/sharer_directory.cc inc/sharer_directory.h | md5sum | cut -c1-32)
r=$(R "cd $OB/simulator && cat src/cache.cc src/ooo_cpu.cc src/main.cc src/legacy_environment.cc src/sharer_directory.cc inc/sharer_directory.h | md5sum | cut -c1-32")
[ "$l" = "$r" ] || die "our uploaded sources do not match the laptop's"
r=$(R "cd $UB && find . -type f -not -path './vcpkg*' | LC_ALL=C sort | xargs md5sum | md5sum | cut -c1-32")
[ "$r" = "$um" ] || die "upstream's uploaded tree reads $r, not $um"
scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/partA_server.sh" "$SRV:$SRV_HOME/partA_server.sh.new" || die "upload of partA_server.sh failed"
R "mv -f $SRV_HOME/partA_server.sh.new $SRV_HOME/partA_server.sh" || die "mv of partA_server.sh failed"
echo "   sources, upstream tree and partA_server.sh uploaded; both match"

step 3 "both builds, guards, E0, then the chain -- detached on the server"
R "mkdir -p $SRV_HOME/$VW; [ -f $SRV_HOME/$VW/launch.log ] && mv -f $SRV_HOME/$VW/launch.log $SRV_HOME/$VW/launch.log.\$(date +%s); setsid nohup bash -c '$SV build && $SV chain' > $SRV_HOME/$VW/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
echo "   following ~/$VW/launch.log (two builds and E0's trace counts take about 15-30 min; Ctrl-C stops only this view)"
seen=0
started=0
for _ in $(seq 1 120); do
  sleep "${FOLLOW_S:-30}"
  out=$(R "tail -n +$((seen + 1)) $SRV_HOME/$VW/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: $0 pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^started:'; then started=1; break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then die "a build or E0 failed (above; ~/$VW/build_run.log) -- nothing was launched"; fi
done
echo
if [ "$started" = 1 ]; then
  echo "Started: 185 runs (E1 170, E2 15), 8-core first, 24 at a time. Expect about 1-2 days: an 8-core run may take 10-24 h"
  echo "(a laptop rehearsal ran 8 SPEC cores at IPC ~0.2). No auto-resume: after a reboot, run this again; complete runs"
  echo "are skipped only if made by the same frozen binary (a rebuild is byte-identical when the sources are)."
else
  echo "NOT STARTED YET: a build or E0 is still running on the server (detached; this view stopped following)."
  echo "If they pass, the chain starts by itself; if one fails, nothing is launched. Check with the pull below."
fi
echo "Where it is:  $0 pull"
echo "log: $LOG"
