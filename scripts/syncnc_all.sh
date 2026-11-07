#!/usr/bin/env bash
# F2 of bench/policy_sanity/stream_fix_design_2026-11-02.md: step 4's programs
# traced again as on gem5's CPU (fft, volrend, lu, raytrace, streamcluster,
# lunc), then run on the g6 binary as before (sync_server.sh VARIANT=nc).
# One command, one password; everything runs DETACHED on the server.
#
#   scripts/syncnc_all.sh          # upload, build the tracer, QS + QK, start the chain
#   scripts/syncnc_all.sh pull     # later: status, the runs' logs, the trace reports and mixes
#   scripts/syncnc_all.sh stop     # end the nc chain and its runs (nothing else)
#   scripts/syncnc_all.sh void     # F2 does not hold (stream_fix_results_2026-11-04.md): stop, then move
#                                  # traces/sync_nc aside unread (amendment 1); the tracer build, QS and QK stay
#
# Uploads only the tracer's sources (to ~/sync_nc_build) and the helpers
# (sync_server.sh, sync_cut.py, sync_anchor.py, trace_mix.c, mutex_micro.c;
# each to a new name, then mv). Needs streamfix's gem5.cpuid with QE held --
# or streamfix running (scripts/streamfix_all.sh redo): the server then waits
# for "QE holds" before it builds anything, and stops if streamfix ends without it.
# Programs not yet sized (lunc) are left out: run this again once they are --
# programs already traced are kept, the tracer is not rebuilt.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SROOT="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
W="$SRV_HOME/sync_nc"
CB="$SRV_HOME/sync_nc_build"
SV="VARIANT=nc bash $SRV_HOME/sync_server.sh"
PREREG="bench/policy_sanity/stream_fix_design_2026-11-02.md"
TRFILES="simulator/tracer/pin/champsim_tracer.cpp simulator/tracer/pin/Makefile simulator/inc/trace_instruction.h"
HOMEFILES="scripts/sync_server.sh scripts/sync_cut.py scripts/trace_mix.c scripts/sync_anchor.py bench/mutex_micro.c"
MODE="${1:-}"
case "$MODE" in ""|pull|stop|void) ;; *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
if [ "$MODE" = void ]; then
  git -C "$LROOT" ls-files --error-unmatch bench/policy_sanity/stream_fix_results_2026-11-04.md > /dev/null 2>&1 \
    || { echo "the streamfix verdict is not committed"; exit 1; }
fi

if [ -z "$MODE" ]; then
  bash -n "$LROOT/scripts/sync_server.sh" || { echo "sync_server.sh does not parse"; exit 1; }
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  # shellcheck disable=SC2086
  dirty=$(git -C "$LROOT" status --porcelain -- $TRFILES $HOMEFILES "$PREREG" scripts/syncnc_all.sh)
  [ -z "$dirty" ] || { echo "$dirty"; echo "uncommitted changes in what is uploaded -- commit first"; exit 1; }
  echo "committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi

CTL="$HOME/.ssh/cm-syncnc-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
  -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

if [ "$MODE" = stop ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  exit 0
fi
if [ "$MODE" = void ]; then
  R "$SV stop" 2>&1 | sed 's/^/   /'
  R "if [ -f $W/.driver.pid ] && kill -0 \$(cat $W/.driver.pid) 2>/dev/null; then echo 'the nc chain is still alive -- nothing moved'; exit 1; fi
     if [ -e $SROOT/traces/sync_nc_void_F2no ]; then echo 'moved aside already: $SROOT/traces/sync_nc_void_F2no'; exit 0; fi
     if [ -d $SROOT/traces/sync_nc ]; then mv $SROOT/traces/sync_nc $SROOT/traces/sync_nc_void_F2no || exit 1; fi
     echo \"\$(date '+%F %T') F2 does not hold (stream_fix_results_2026-11-04.md): traces moved aside unread to traces/sync_nc_void_F2no\" | tee -a $W/VOID $W/driver.log
     ls $SROOT/traces/sync_nc_void_F2no 2>/dev/null | tr '\n' ' '; echo; du -sh $SROOT/traces/sync_nc_void_F2no 2>/dev/null" 2>&1 | sed 's/^/   /'
  exit "${PIPESTATUS[0]}"
fi
if [ "$MODE" = pull ]; then
  R "$SV status" | sed 's/^/   /'
  echo "   -- end of ~/sync_nc/launch.log:"
  R "tail -n 15 $W/launch.log 2>/dev/null || echo '(no launch log)'" | sed 's/^/      /'
  OUT="$LROOT/simulator/results/sync_nc"
  mkdir -p "$OUT"
  "${RS[@]}" --include='*/' --include='run.log' --exclude='*' "$SRV:$SROOT/results/phaseA_b3_n3_*" "$OUT/logs/" \
    && echo "   pulled: the runs' logs to simulator/results/sync_nc/logs/"
  "${RS[@]}" --prune-empty-dirs --include='*/' --include='pin.err' --include='cut.log' --include='*.mix' --include='DONE' --include='CPUID' \
    --include='LEN' --include='FAILED' --include='anchor.txt' --include='anchor.err' --exclude='*' \
    "$SRV:$SROOT/traces/sync_nc/" "$OUT/traces/" && echo "   pulled: tracer reports, anchors and mixes to simulator/results/sync_nc/traces/"
  "${RS[@]}" --include='*.log' --include='gem5.cpuid' --include='*_PASSED' --include='qk/' --include='qk/dump.diff' --include='qk/*.err' \
    --exclude='*' "$SRV:$W/" "$OUT/" || true
  echo "Tell Claude: nc pulled."
  exit 0
fi

echo "== the server: gem5's CPUID, the g6 binary, what is sized"
R "grep 'QE holds' $SRV_HOME/streamfix/driver.log 2>/dev/null | tail -1" | sed 's/^/   /'
SFP="$SRV_HOME/streamfix/.driver.pid"
if R "[ -s $SRV_HOME/streamfix/gem5.cpuid ] && grep -q 'QE holds' $SRV_HOME/streamfix/driver.log"; then
  echo "   QE holds"
elif R "[ -f $SFP ] && kill -0 \$(cat $SFP) 2>/dev/null && ! grep -qE 'QE FAILED|gem5-CPUID runs are skipped' $SRV_HOME/streamfix/driver.log"; then
  echo "   streamfix is running and QE is not decided yet: the server waits for it before building anything"
else
  echo "   no gem5.cpuid that passed QE, and streamfix is not running (scripts/streamfix_all.sh pull shows where it is) -- nothing started"; exit 1
fi
R "[ -f $SRV_HOME/sync_g6/Q0_PASSED ] && [ -f $SRV_HOME/sync_g6/Q0M_PASSED ] && echo \"   g6 binary: \$(cat $SRV_HOME/sync_g6/BIN)\"" \
  || { echo "   the g6 binary has not passed Q0 and Q0m -- nothing started"; exit 1; }
R "for p in fft volrend lu raytrace streamcluster lunc; do awk -F'|' -v n=\$p '\$1 == n { f = 1 } END { exit !f }' $SRV_HOME/newbench/PROGS && echo \"   \$p: sized\" || echo \"   \$p: NOT sized -- left out; run this again once it is\"; done"
if R "[ -f $W/.driver.pid ] && kill -0 \$(cat $W/.driver.pid 2>/dev/null) 2>/dev/null"; then
  echo "   the nc chain is running -- $SV status; nothing changed"; exit 1
fi

echo "== upload: the tracer's sources to ~/sync_nc_build, the helpers to ~"
src=$(md5sum < "$LROOT/simulator/tracer/pin/champsim_tracer.cpp" | cut -c1-32)
built=$(R "cat $W/TRACER_SRC 2>/dev/null")
ntr=$(R "ls -d $SROOT/traces/sync_nc/*/ 2>/dev/null | wc -l")
if [ -n "$built" ] && [ "$built" != "$src" ] && [ "${ntr:-0}" != 0 ]; then
  echo "   the tracer was built from another source and $ntr trace sets exist -- one set is never made by two tracers; nothing changed"; exit 1
fi
R "mkdir -p $CB/simulator/tracer/pin $CB/simulator/inc $W" || exit 1
for f in $TRFILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || { echo "rsync of $f failed"; exit 1; }; done
[ "$(R "md5sum < $CB/simulator/tracer/pin/champsim_tracer.cpp | cut -c1-32")" = "$src" ] || { echo "the uploaded tracer source does not match"; exit 1; }
for f in $HOMEFILES; do
  b=$(basename "$f")
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/$b.new" || { echo "upload of $b failed"; exit 1; }
  R "mv -f $SRV_HOME/$b.new $SRV_HOME/$b" || exit 1
done
echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD)); tracer source md5 $src"

if [ "$built" = "$src" ] && R "[ -f $W/QK_PASSED ] && [ -f $W/QS_PASSED ]"; then
  what="the chain (the tracer is built and passed QS and QK)"
  cmd="$SV chain"
else
  what="the tracer build, QS, QK, then the chain"
  cmd="$SV build && md5sum < $CB/simulator/tracer/pin/champsim_tracer.cpp | cut -c1-32 > $W/TRACER_SRC && $SV chain"
fi
# first wait, on the server, for streamfix's QE (no wait when it holds already)
SFL="$SRV_HOME/streamfix/driver.log"
waitqe="n=0; until grep -q \"QE holds\" $SFL 2>/dev/null; do
  if grep -qE \"QE FAILED|gem5-CPUID runs are skipped\" $SFL 2>/dev/null || ! { [ -f $SFP ] && kill -0 \$(cat $SFP) 2>/dev/null; }; then echo \"ERROR: streamfix has no gem5 CPUID that passed QE -- nothing built or traced\"; exit 1; fi
  [ \$n = 0 ] && echo \"\$(date \"+%F %T\") waiting for streamfix QE\"; n=1; sleep 30; done; echo \"\$(date \"+%F %T\") QE holds: \$(grep \"QE holds\" $SFL | tail -1 | cut -c1-140)\""
cmd="$waitqe; $cmd"
echo "== start, detached: $what"
R "[ -f $W/launch.log ] && mv -f $W/launch.log $W/launch.log.\$(date +%s); setsid nohup bash -c '$cmd' > $W/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
seen=0
for i in $(seq 1 70); do
  sleep 30
  out=$(R "tail -n +$((seen + 1)) $W/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: scripts/syncnc_all.sh pull)"; exit 0; }
  if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
  if echo "$out" | grep -q '^started:'; then break; fi
  if echo "$out" | grep -qE '^ERROR|stopped, exit code|FAILED'; then echo "STOPPED: the build, QS or QK failed (above; ~/sync_nc/build_run.log) -- nothing was traced"; exit 1; fi
done
echo
echo "Started: tracing (fft and volrend are whole runs: a day or more), then the runs. No auto-resume: after a reboot, run this again."
echo "Where it is:  scripts/syncnc_all.sh pull"
