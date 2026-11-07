#!/usr/bin/env bash
# Held-out set 2 (bench/policy_sanity/heldout2_design_2026-11-04.md). One command,
# one password.
#
#   scripts/heldout2_all.sh survey     # READ-ONLY: E1 and E2's evidence (Note 1)
#   scripts/heldout2_all.sh size       # Note 2: stage the candidates' inputs from the laptop's
#                                      # parsec-3.0-input-sim.tar.gz (md5-checked), upload them, the
#                                      # probe and the runners; then on the server, detached: build,
#                                      # size (E3, E5) and start each sized program's two gem5 runs
#   scripts/heldout2_all.sh status     # sizing and the gem5 runs
#   scripts/heldout2_all.sh runners    # Note 3: upload only the gem5 runners (launch_b3_gem5.sh,
#                                      # run_gem5_splash.sh); lists any held-out gem5 run already launched
#   scripts/heldout2_all.sh regem5     # Note 3: bodytrack's and vips's gem5 runs, launched before that
#                                      # upload, stopped (only theirs) and launched again; each run's stop per CPU
#   scripts/heldout2_all.sh tracer     # Note 4: facesim's tracer (-start0 broadcast) to ~/sync_h2_build,
#                                      # sync_server.sh as ~/sync_server_h2.sh (the live chains keep theirs);
#                                      # detached: build under gem5's CPUID, QS, QK, QZ. Nothing is traced
#   scripts/heldout2_all.sh counter    # Note 5: the counter with BROADCAST lines and -base0 broadcast to
#                                      # ~/sync_h2_build (the streamfix counter untouched); detached: build,
#                                      # QR under gem5's CPUID and the host's. Nothing is counted
#   scripts/heldout2_all.sh trace      # Note 6: sync_server.sh as ~/sync_server_h2.sh, then the h2 chain,
#                                      # detached: trace the five programs (two at a time), then their five
#                                      # ChampSim runs on the g6 binary. Returns once the chain has started
#   scripts/heldout2_all.sh count      # Note 7: sync_server.sh as ~/sync_server_h2.sh, then, detached: QE-h2
#                                      # and the 24 counter runs (the five + streamcluster; gem5's CPUID x3,
#                                      # host x1). Returns once QE-h2 has answered. Nothing is read
#   scripts/heldout2_all.sh pullcount  # the counter runs' files to simulator/results/heldout2/count (no rates printed)
#   scripts/heldout2_all.sh sc         # newbench amendment 3, once the h2 chain's five runs have ended:
#                                      # streamcluster's lines (step 4's), then the chain again (six programs;
#                                      # the five done are skipped)
#
# Later modes (traces, counter runs) are added by a note in the design
# before they run.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PREREG="bench/policy_sanity/heldout2_design_2026-11-04.md"
ARCHIVE="$LROOT/simulator/tracer/pin/parsec-3.0-input-sim.tar.gz"
ARCHIVE_MD5=63be26944888ba29069d395e961515a0
H2_PROGS="fluidanimate bodytrack facesim vips oceannc"
MODE="${1:-}"
case "$MODE" in survey|size|status|runners|regem5|tracer|counter|trace|count|pullcount|sc) ;; *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
COMMITTED="$PREREG scripts/heldout2_survey.sh scripts/heldout2_all.sh"
[ "$MODE" = survey ] || COMMITTED="$COMMITTED scripts/heldout2_server.sh scripts/launch_b3_gem5.sh scripts/run_gem5_splash.sh simulator/tracer/h2probe"
# Note 4: what 'tracer' uploads
TRFILES="simulator/tracer/pin/champsim_tracer.cpp simulator/tracer/pin/Makefile simulator/inc/trace_instruction.h"
HOMEFILES="bench/start0_micro.c scripts/start0_check.py scripts/trace_mix.c bench/mutex_micro.c"
[ "$MODE" != tracer ] || COMMITTED="$COMMITTED $TRFILES $HOMEFILES scripts/sync_server.sh"
# Note 5: what 'counter' uploads
CTFILES="simulator/tracer/stream_count/stream_count.cpp simulator/tracer/stream_count/Makefile"
CHOMEFILES="bench/bcast_micro.c scripts/bcast_check.py bench/start0_micro.c"
[ "$MODE" != counter ] || COMMITTED="$COMMITTED $CTFILES $CHOMEFILES scripts/sync_server.sh"
[ "$MODE" != trace ] || COMMITTED="$COMMITTED scripts/sync_server.sh scripts/trace_mix.c"
# Note 7: count and sc upload sync_server.sh; sc follows newbench amendment 3
NBDESIGN="bench/policy_sanity/newbench_design_2026-10-19.md"
case "$MODE" in count|sc) COMMITTED="$COMMITTED scripts/sync_server.sh $NBDESIGN" ;; esac
# shellcheck disable=SC2086
[ -z "$(git -C "$LROOT" status --porcelain -- $COMMITTED)" ] || { echo "uncommitted changes in the design or the scripts -- commit first"; exit 1; }
if [ "$MODE" = size ]; then
  grep -q '^## Note 2' "$LROOT/$PREREG" || { echo "the design has no Note 2 (the build and sizing recipes) -- it is written before sizing"; exit 1; }
fi
if [ "$MODE" = runners ] || [ "$MODE" = regem5 ]; then
  grep -q '^## Note 3' "$LROOT/$PREREG" || { echo "the design has no Note 3 (the worker stop) -- it is written before the upload"; exit 1; }
fi
if [ "$MODE" = trace ]; then
  grep -q '^## Note 6' "$LROOT/$PREREG" || { echo "the design has no Note 6 (step 3: the traces and runs) -- it is written before anything is traced"; exit 1; }
  bash -n "$LROOT/scripts/sync_server.sh" || { echo "sync_server.sh does not parse"; exit 1; }
  echo "committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi
if [ "$MODE" = counter ]; then
  grep -q '^## Note 5' "$LROOT/$PREREG" || { echo "the design has no Note 5 (the counter's BROADCAST line) -- it is written before the build"; exit 1; }
  bash -n "$LROOT/scripts/sync_server.sh" || { echo "sync_server.sh does not parse"; exit 1; }
  echo "committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi
if [ "$MODE" = count ] || [ "$MODE" = sc ]; then
  grep -q '^## Note 7' "$LROOT/$PREREG" || { echo "the design has no Note 7 (the counter runs) -- it is written before they run"; exit 1; }
  grep -q '^## Amendment 3' "$LROOT/$NBDESIGN" || { echo "$NBDESIGN has no amendment 3 (streamcluster) -- it is written first"; exit 1; }
  bash -n "$LROOT/scripts/sync_server.sh" || { echo "sync_server.sh does not parse"; exit 1; }
  echo "committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi
if [ "$MODE" = tracer ]; then
  grep -q '^## Note 4' "$LROOT/$PREREG" || { echo "the design has no Note 4 (facesim's tracer option) -- it is written before the build"; exit 1; }
  bash -n "$LROOT/scripts/sync_server.sh" || { echo "sync_server.sh does not parse"; exit 1; }
  echo "committed: $(git -C "$LROOT" log -1 --format='%h %s' | cut -c1-90)"
fi
OUT="$LROOT/simulator/results/heldout2"
mkdir -p "$OUT"

# The inputs, from PARSEC's sim archive on the laptop (Note 1): each
# candidate's input_sim*.tar, facesim's once (its three sets are one file)
stage_inputs() {
  local up="$OUT/upload" p s m
  [ -f "$ARCHIVE" ] || { echo "no $ARCHIVE"; return 1; }
  echo "Checking the input archive's md5 ..."
  m=$(md5sum < "$ARCHIVE" | cut -c1-32)
  [ "$m" = "$ARCHIVE_MD5" ] || { echo "the archive's md5 is $m, not $ARCHIVE_MD5"; return 1; }
  rm -rf "$up" "$OUT/stage"; mkdir -p "$up" "$OUT/stage"
  local members=()
  for p in fluidanimate bodytrack vips; do for s in simsmall simmedium simlarge; do members+=("parsec-3.0/pkgs/apps/$p/inputs/input_$s.tar"); done; done
  members+=("parsec-3.0/pkgs/apps/facesim/inputs/input_simsmall.tar")
  tar -xzf "$ARCHIVE" -C "$OUT/stage" "${members[@]}" || { echo "could not extract the inputs"; return 1; }
  for p in fluidanimate bodytrack facesim vips; do
    mkdir -p "$up/$p"
    mv "$OUT/stage/parsec-3.0/pkgs/apps/$p/inputs/"*.tar "$up/$p/"
    ( cd "$up/$p" && md5sum ./*.tar | sed 's|\./||' > MD5SUMS )
  done
  rm -rf "$OUT/stage"
  echo "Staged: $(find "$up" -name '*.tar' | wc -l) input tars, $(du -sh "$up" | cut -f1)"
}
if [ "$MODE" = size ]; then stage_inputs || exit 1; fi

CTL="$HOME/.ssh/cm-heldout2-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 \
  -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
up() {   # local file -> server path, through a new name and mv (a runner may be live)
  scp -q -P "$PORT" -o ControlPath="$CTL" "$1" "$SRV:$2.new" && R "mv -f $2.new $2" || { echo "upload of $1 failed"; exit 1; }
}
case "$MODE" in
  survey)
    up "$LROOT/scripts/heldout2_survey.sh" "$SRV_HOME/heldout2_survey.sh"
    R "bash $SRV_HOME/heldout2_survey.sh" 2>&1 | tee "$OUT/survey.txt"
    echo; echo "Saved to simulator/results/heldout2/survey.txt. Tell Claude: survey done." ;;
  size)
    R "test -f $SRV_HOME/heldout2/.size.pid && kill -0 \$(cat $SRV_HOME/heldout2/.size.pid) 2>/dev/null" \
      && { echo "the sizing is already running on the server -- scripts/heldout2_all.sh status"; exit 1; }
    R "mkdir -p $SRV_HOME/heldout2/h2probe $SRV_HOME/heldout2/upload" || exit 1
    echo "Uploading the inputs ($(du -sh "$OUT/upload" | cut -f1)) ..."
    for p in fluidanimate bodytrack facesim vips; do
      scp -q -r -P "$PORT" -o ControlPath="$CTL" "$OUT/upload/$p" "$SRV:$SRV_HOME/heldout2/upload/" || { echo "upload of $p's inputs failed"; exit 1; }
    done
    R "cd $SRV_HOME/heldout2/upload && for p in fluidanimate bodytrack facesim vips; do (cd \$p && md5sum -c --quiet MD5SUMS) || exit 1; done && echo '   md5 checked on the server: every input'" || { echo "an uploaded input does not match its md5"; exit 1; }
    for f in h2probe.cpp Makefile; do up "$LROOT/simulator/tracer/h2probe/$f" "$SRV_HOME/heldout2/h2probe/$f"; done
    for f in heldout2_server.sh launch_b3_gem5.sh run_gem5_splash.sh; do up "$LROOT/scripts/$f" "$SRV_HOME/$f"; done
    echo "Uploaded the probe and the runners (heldout2_server.sh, launch_b3_gem5.sh, run_gem5_splash.sh)."
    R "bash $SRV_HOME/heldout2_server.sh sizegem5" || exit 1
    echo; echo "Started on the server (detached). In ~30-60 min: scripts/heldout2_all.sh status" ;;
  runners)
    for f in launch_b3_gem5.sh run_gem5_splash.sh; do up "$LROOT/scripts/$f" "$SRV_HOME/$f"; done
    echo "Uploaded the gem5 runners (launch_b3_gem5.sh, run_gem5_splash.sh): the worker stop watches the traced CPUs (Note 3)."
    echo "Held-out gem5 runs launched so far (none is fine; an old-style 'cpu1..' line means it was launched before this upload):"
    R "grep -h 'stop when a worker' $SRV_HOME/gem5_b3/heldout2/*/launch.log 2>/dev/null || echo '   none yet'" | sed 's/^ */   /'
    R "bash $SRV_HOME/heldout2_server.sh status" 2>&1 | head -12 ;;
  regem5)
    up "$LROOT/scripts/heldout2_server.sh" "$SRV_HOME/heldout2_server.sh"
    R "bash $SRV_HOME/heldout2_server.sh regem5 bodytrack vips" 2>&1 | tee "$OUT/regem5_$(date +%Y%m%d_%H%M).txt"
    echo; echo "Saved to simulator/results/heldout2/regem5_*.txt" ;;
  tracer)
    SROOT="$SRV_HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
    CB="$SRV_HOME/sync_h2_build"; W="$SRV_HOME/sync_h2"; SV="VARIANT=h2 bash $SRV_HOME/sync_server_h2.sh"
    RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")
    LOGF="$OUT/tracer_$(date +%Y%m%d_%H%M).txt"
    {
    R "[ -f $W/.build.pid ] && kill -0 \$(cat $W/.build.pid 2>/dev/null) 2>/dev/null" \
      && { echo "the h2 tracer build is running -- scripts/heldout2_all.sh status"; exit 1; }
    src=$(md5sum < "$LROOT/simulator/tracer/pin/champsim_tracer.cpp" | cut -c1-32)
    built=$(R "cat $W/TRACER_SRC 2>/dev/null")
    ntr=$(R "ls -d $SROOT/traces/sync_h2/*/ 2>/dev/null | wc -l")
    if [ -n "$built" ] && [ "$built" != "$src" ] && [ "${ntr:-0}" != 0 ]; then
      echo "the h2 tracer was built from another source and $ntr trace sets exist -- one set is never made by two tracers; nothing changed"; exit 1
    fi
    if [ "$built" = "$src" ] && R "[ -f $W/QZ_PASSED ]"; then
      echo "the h2 tracer is built from this source and passed QS, QK and QZ -- nothing to do"; R "$SV status"; exit 0
    fi
    echo "== upload: the tracer's sources to ~/sync_h2_build; sync_server.sh as ~/sync_server_h2.sh; QZ's program and checker"
    R "mkdir -p $CB/simulator/tracer/pin $CB/simulator/inc $W" || exit 1
    for f in $TRFILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || { echo "rsync of $f failed"; exit 1; }; done
    [ "$(R "md5sum < $CB/simulator/tracer/pin/champsim_tracer.cpp | cut -c1-32")" = "$src" ] || { echo "the uploaded tracer source does not match"; exit 1; }
    up "$LROOT/scripts/sync_server.sh" "$SRV_HOME/sync_server_h2.sh"
    for f in $HOMEFILES; do
      b=$(basename "$f"); m=$(md5sum < "$LROOT/$f" | cut -c1-32)
      if [ "$(R "md5sum 2>/dev/null < $SRV_HOME/$b | cut -c1-32")" = "$m" ]; then echo "   ~/$b: already this file"
      else up "$LROOT/$f" "$SRV_HOME/$b"; echo "   ~/$b: uploaded"; fi
    done
    echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD)); tracer source md5 $src"
    cmd="echo \$\$ > $W/.build.pid; $SV build && md5sum < $CB/simulator/tracer/pin/champsim_tracer.cpp | cut -c1-32 > $W/TRACER_SRC; echo \"h2 build: exit code \$?\""
    echo "== start, detached: the tracer build, QS, QK, QZ"
    R "[ -f $W/launch.log ] && mv -f $W/launch.log $W/launch.log.\$(date +%s); setsid nohup bash -c '$cmd' > $W/launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
    seen=0
    for i in $(seq 1 80); do
      sleep 30
      out=$(R "tail -n +$((seen + 1)) $W/launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: scripts/heldout2_all.sh status)"; exit 0; }
      if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
      if echo "$out" | grep -q '^h2 build: exit code 0'; then echo; echo "Built: QS, QK and QZ hold. Nothing is traced yet. Tell Claude: tracer done."; exit 0; fi
      if echo "$out" | grep -qE '^h2 build: exit code|^ERROR'; then echo; echo "STOPPED: the build, QS, QK or QZ failed (above; ~/sync_h2/build_run.log) -- nothing was traced"; exit 1; fi
    done
    echo "   still running after 40 min -- the server carries on: scripts/heldout2_all.sh status"
    } 2>&1 | tee "$LOGF"
    rc=${PIPESTATUS[0]}; echo "Saved to ${LOGF#"$LROOT"/}"; exit "$rc" ;;
  counter)
    CB="$SRV_HOME/sync_h2_build"; W="$SRV_HOME/sync_h2"; SV="VARIANT=h2 bash $SRV_HOME/sync_server_h2.sh"
    RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")
    LOGF="$OUT/counter_$(date +%Y%m%d_%H%M).txt"
    {
    R "[ -f $W/.counter.pid ] && kill -0 \$(cat $W/.counter.pid 2>/dev/null) 2>/dev/null" \
      && { echo "the h2 counter build is running -- scripts/heldout2_all.sh status"; exit 1; }
    R "[ -f $W/QZ_PASSED ]" || { echo "the h2 tracer has not passed QZ on the server -- scripts/heldout2_all.sh tracer first"; exit 1; }
    src=$(md5sum < "$LROOT/simulator/tracer/stream_count/stream_count.cpp" | cut -c1-32)
    built=$(R "cat $W/COUNTER_SRC 2>/dev/null")
    ncnt=$(R "ls -d $W/count/*/ 2>/dev/null | wc -l")
    if [ "$built" != "$src" ] && [ "${ncnt:-0}" != 0 ]; then
      echo "$ncnt counter runs exist and the h2 counter is not this source's (built from ${built:-an unrecorded source}) -- one set of counts is never made by two counters; nothing changed"; exit 1
    fi
    if [ "$built" = "$src" ] && R "[ -f $W/QR_PASSED ]"; then
      echo "the h2 counter is built from this source and passed QR -- nothing to do"; R "$SV status"; exit 0
    fi
    echo "== upload: the counter's sources to ~/sync_h2_build; sync_server.sh as ~/sync_server_h2.sh; QR's programs and checker"
    R "mkdir -p $CB/simulator/tracer/stream_count $W" || exit 1
    for f in $CTFILES; do "${RS[@]}" "$LROOT/$f" "$SRV:$CB/$f" || { echo "rsync of $f failed"; exit 1; }; done
    [ "$(R "md5sum < $CB/simulator/tracer/stream_count/stream_count.cpp | cut -c1-32")" = "$src" ] || { echo "the uploaded counter source does not match"; exit 1; }
    up "$LROOT/scripts/sync_server.sh" "$SRV_HOME/sync_server_h2.sh"
    for f in $CHOMEFILES; do
      b=$(basename "$f"); m=$(md5sum < "$LROOT/$f" | cut -c1-32)
      if [ "$(R "md5sum 2>/dev/null < $SRV_HOME/$b | cut -c1-32")" = "$m" ]; then echo "   ~/$b: already this file"
      else up "$LROOT/$f" "$SRV_HOME/$b"; echo "   ~/$b: uploaded"; fi
    done
    echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD)); counter source md5 $src"
    cmd="echo \$\$ > $W/.counter.pid; $SV counter && md5sum < $CB/simulator/tracer/stream_count/stream_count.cpp | cut -c1-32 > $W/COUNTER_SRC; echo \"h2 counter: exit code \$?\""
    echo "== start, detached: the counter build, then QR"
    R "[ -f $W/counter_launch.log ] && mv -f $W/counter_launch.log $W/counter_launch.log.\$(date +%s); setsid nohup bash -c '$cmd' > $W/counter_launch.log 2>&1 < /dev/null & sleep 2; echo started" | sed 's/^/   /'
    seen=0
    for i in $(seq 1 80); do
      sleep 30
      out=$(R "tail -n +$((seen + 1)) $W/counter_launch.log" 2>/dev/null) || { echo "   (connection lost -- the server carries on: scripts/heldout2_all.sh status)"; exit 0; }
      if [ -n "$out" ]; then echo "$out" | sed 's/^/   /'; seen=$((seen + $(echo "$out" | wc -l))); fi
      if echo "$out" | grep -q '^h2 counter: exit code 0'; then echo; echo "Built: QR holds. Nothing is counted yet. Tell Claude: counter done."; exit 0; fi
      if echo "$out" | grep -qE '^h2 counter: exit code|^ERROR'; then echo; echo "STOPPED: the counter build or QR failed (above; ~/sync_h2/counter_run.log) -- nothing was counted"; exit 1; fi
    done
    echo "   still running after 40 min -- the server carries on: scripts/heldout2_all.sh status"
    } 2>&1 | tee "$LOGF"
    rc=${PIPESTATUS[0]}; echo "Saved to ${LOGF#"$LROOT"/}"; exit "$rc" ;;
  count)
    W="$SRV_HOME/sync_h2"; SV="VARIANT=h2 bash $SRV_HOME/sync_server_h2.sh"
    LOGF="$OUT/count_$(date +%Y%m%d_%H%M).txt"
    {
    R "[ -f $W/count/.pid ] && kill -0 \$(cat $W/count/.pid 2>/dev/null) 2>/dev/null" \
      && { echo "the counter runs are running -- scripts/heldout2_all.sh status"; exit 1; }
    echo "== upload: sync_server.sh as ~/sync_server_h2.sh (a new file, then mv: the live h2 chain keeps its copy)"
    up "$LROOT/scripts/sync_server.sh" "$SRV_HOME/sync_server_h2.sh"
    echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
    n0=$(R "[ -f $W/count/driver.log ] && wc -l < $W/count/driver.log || echo 0"); n0=${n0:-0}
    echo "== start, detached (its guards first: QR and the counter's md5, gem5.cpuid, cpuid_dump, the six programs)"
    o=$(R "$SV count" 2>&1); rc=$?
    echo "$o" | sed 's/^/   /'
    [ "$rc" = 0 ] || { echo; echo "STOPPED: the counter runs did not start, or stopped at QE-h2 (above) -- nothing was counted"; exit 1; }
    case "$o" in *"nothing to do"*|*"running already"*) R "$SV status" 2>&1 | head -3 | sed 's/^/   /'; exit 0 ;; esac
    l=""
    for i in $(seq 1 20); do
      sleep 15
      l=$(R "tail -n +$((n0 + 1)) $W/count/driver.log 2>/dev/null | grep -E 'QE-h2 (holds|FAILED)' | tail -1")
      [ -n "$l" ] && break
    done
    echo "   ${l:-QE-h2: no answer after 5 min -- the server carries on: scripts/heldout2_all.sh status}"
    case "$l" in *FAILED*) echo; echo "STOPPED: QE-h2 failed -- nothing is counted"; exit 1 ;; esac
    R "$SV status" 2>&1 | head -3 | sed 's/^/   /'
    echo; echo "Started: 24 counter runs, 4 at a time, facesim's first (hours). Progress: scripts/heldout2_all.sh status."
    echo "Nothing is read until step 5's note: scripts/heldout2_all.sh pullcount only copies the files."
    } 2>&1 | tee "$LOGF"
    rc=${PIPESTATUS[0]}; echo "Saved to ${LOGF#"$LROOT"/}"; exit "$rc" ;;
  pullcount)
    mkdir -p "$OUT/count"
    rsync -a --copy-links --prune-empty-dirs --include='*/' --include='c.summary' --include='c.t*.cnt' --include='c.t*.rtn' \
      --include='STATUS' --include='RUN' --include='PROGS' --include='pin.err' --include='driver.log' --include='DONE' --include='COUNTER_MD5' \
      --exclude='*' -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/sync_h2/count/" "$OUT/count/" || { echo "the pull failed"; exit 1; }
    rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/sync_h2/qeh2/" "$OUT/qeh2/" 2>/dev/null || true
    n=$(find "$OUT/count/runs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    ok=$(grep -l '^exit 0 ' "$OUT"/count/runs/*/STATUS 2>/dev/null | wc -l)
    echo "Pulled $n counter runs ($ok exited 0) to simulator/results/heldout2/count/$([ -f "$OUT/count/DONE" ] && echo "; DONE $(cat "$OUT/count/DONE")")."
    grep -E 'QE-h2|COUNT|FAILED' "$OUT/count/driver.log" 2>/dev/null | tail -4 | sed 's/^/   /'
    echo "No rate was read (step 5's note first)." ;;
  sc)
    W="$SRV_HOME/sync_h2"; SV="VARIANT=h2 bash $SRV_HOME/sync_server_h2.sh"
    LOGF="$OUT/sc_$(date +%Y%m%d_%H%M).txt"
    {
    R "[ -f $W/.driver.pid ] && kill -0 \$(cat $W/.driver.pid 2>/dev/null) 2>/dev/null" \
      && { echo "the h2 chain is running -- 'sc' waits until its five runs have ended"; R "$SV status" | sed 's/^/   /'; exit 1; }
    echo "== upload: sync_server.sh as ~/sync_server_h2.sh"
    up "$LROOT/scripts/sync_server.sh" "$SRV_HOME/sync_server_h2.sh"
    echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
    echo "== streamcluster's lines (newbench amendment 3: step 4's, unchanged)"
    R "$SV sc" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" = 0 ] || { echo; echo "STOPPED: streamcluster's lines were not written (above)"; exit 1; }
    echo "== start the h2 chain again (its guards first; the five done are skipped)"
    R "$SV chain" 2>&1 | sed 's/^/   /'
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo; echo "STOPPED: the chain did not start (above) -- nothing was traced"; exit 1; }
    sleep 20
    R "$SV status" 2>&1 | sed 's/^/   /'
    echo; echo "Started: streamcluster traced under gem5's CPUID, then its ChampSim run. Progress: scripts/heldout2_all.sh status."
    } 2>&1 | tee "$LOGF"
    rc=${PIPESTATUS[0]}; echo "Saved to ${LOGF#"$LROOT"/}"; exit "$rc" ;;
  trace)
    W="$SRV_HOME/sync_h2"; SV="VARIANT=h2 bash $SRV_HOME/sync_server_h2.sh"
    LOGF="$OUT/trace_$(date +%Y%m%d_%H%M).txt"
    {
    R "[ -f $W/.driver.pid ] && kill -0 \$(cat $W/.driver.pid 2>/dev/null) 2>/dev/null" \
      && { echo "the h2 chain is running -- scripts/heldout2_all.sh status"; R "$SV status"; exit 1; }
    R "[ -f $W/QZ_PASSED ]" || { echo "the h2 tracer has not passed QZ on the server -- scripts/heldout2_all.sh tracer first"; exit 1; }
    echo "== upload: sync_server.sh as ~/sync_server_h2.sh"
    up "$LROOT/scripts/sync_server.sh" "$SRV_HOME/sync_server_h2.sh"
    echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
    echo "== start the h2 chain (its guards first: the two tracers, gem5.cpuid, the g6 binary, the five sized programs)"
    R "$SV chain" 2>&1 | sed 's/^/   /'
    rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || { echo; echo "STOPPED: the chain did not start (above) -- nothing was traced"; exit 1; }
    sleep 20
    R "$SV status" 2>&1 | sed 's/^/   /'
    echo; echo "Started. Tracing takes a few hours, then five ChampSim runs (~3-6 h each). Progress: scripts/heldout2_all.sh status."
    } 2>&1 | tee "$LOGF"
    rc=${PIPESTATUS[0]}; echo "Saved to ${LOGF#"$LROOT"/}"; exit "$rc" ;;
  status)
    R "[ -f $SRV_HOME/sync_server_h2.sh ] && VARIANT=h2 bash $SRV_HOME/sync_server_h2.sh status" 2>&1 | tee "$OUT/tracer_status_$(date +%Y%m%d_%H%M).txt"
    { R "bash $SRV_HOME/heldout2_server.sh status"
      for p in $H2_PROGS; do R "WL=$p bash $SRV_HOME/launch_b3_gem5.sh status 2>/dev/null" | sed 's/^/   /'; done
    } 2>&1 | tee "$OUT/status_$(date +%Y%m%d_%H%M).txt"
    R "for p in $H2_PROGS; do f=$SRV_HOME/heldout2/\$p/probe_chosen.txt; [ -f \$f ] && { echo \"== \$p\"; cat \$f; }; done" > "$OUT/probes.txt" 2>/dev/null
    echo; echo "Saved: simulator/results/heldout2/status_*.txt and probes.txt" ;;
esac
