#!/usr/bin/env bash
# Make barnes run under gem5, and launch its B3 runs. Detached, one step at a
# time, stopping at the first failure.
#
#   scp -P 2222 scripts/barnes_gem5.sh scripts/build_splash_static.sh user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/barnes_gem5.sh go'
#   ssh -n -p 2222 user@your-server 'bash ~/barnes_gem5.sh status'
#
# The static BARNES aborts natively with "buffer overflow detected" on its
# correct input (2026-09-25). build_splash_static.sh added -O2, and on Ubuntu
# -O2 turns on _FORTIFY_SOURCE. The traced dynamic BARNES, built with the
# tree's own flags, has no fortified calls. Shown on the laptop's gcc
# (2026-10-05) with a strcpy into an 8-byte buffer:
#   -O2                        1 fortified call, aborts (rc 134)
#   -O0                        0, the overflow happens SILENTLY (rc 0)
#   -O2 with fortify off       0, silently (rc 0)
# So the abort is a real overflow that the traced build also commits,
# unnoticed. Step 1 records where, before the rebuild hides it.
#
#   1. backtrace  gdb on the current (fortified) static BARNES, the real input
#   2. rebuild    BARNES only, the tree's own flags, fortify off
#                 (ONLY=BARNES OPT= FORTIFY=0 build_splash_static.sh go)
#   3. verify     no fortified call inside BARNES's OWN functions (named from
#                 its object files); OCEAN byte-identical to before (in use
#                 by the ocean B3 comparison); the build log's compile lines
#                 carry -D_FORTIFY_SOURCE=0
#
#   RESUME_FROM=N starts at step N, using what earlier steps left in place.
#   The first run (2026-10-05) stopped at step 3 on a whole-binary count of
#   86 fortified calls. A static binary carries glibc's own code, which makes
#   such calls internally; only calls from barnes's own functions matter.
#   4. native     BARNES runs natively on the input: rc 0, or 124 = still
#                 running at 20 s
#   5. launch     WL=barnes launch_b3_gem5.sh go: LLC 2MB, stop at 50M,
#                 150M, and the whole program
set -uo pipefail
BINS="${BINS:-$HOME/splash-static}"
W="$HOME/gem5_b3/barnes"
LOG="$W/pipeline.log"
PIDF="$W/.pipeline.pid"
alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

SPLASH="${SPLASH:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/tracer/splash-3/codes/apps}"
RESUME_FROM="${RESUME_FROM:-1}"
step() { echo; echo "=== $(date '+%F %T')  $* ==="; }
skip() { [ "$1" -lt "$RESUME_FROM" ] && { echo; echo "=== step $1 skipped (RESUME_FROM=$RESUME_FROM) ==="; return 0; }; return 1; }

# Fortified call sites in a binary, by the function that makes them.
fortified_callers() {
  objdump -d "$1" 2>/dev/null | awk '/^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn) }
    /call.*<__[a-z_]+_chk(@plt)?>/ { print fn }' | sort | uniq -c | sort -rn
}
fail() { echo "STOPPED: $*"; rm -f "$PIDF"; exit 1; }

pipeline() {
  echo $$ > "$PIDF"
  local in="$W/barnes.in" ocean_before ocean_after n rc

  bash "$HOME/run_gem5_splash.sh" barnes-input "$in" 4 >/dev/null || fail "could not write the barnes input"
  [ -x "$BINS/BARNES" ] || fail "no $BINS/BARNES"
  if ! skip 1; then
  step "1/5 backtrace of the fortified static BARNES"
  if command -v gdb >/dev/null 2>&1; then
    timeout 300 gdb -batch -ex "run < $in" -ex bt "$BINS/BARNES" 2>&1 | tail -30 | tee "$W/fortify_backtrace.txt"
    echo "   saved: $W/fortify_backtrace.txt"
  else
    echo "   gdb not installed -- recording the native abort only"
    ( cd "$W" && timeout 20 "$BINS/BARNES" < "$in" ) > "$W/fortify_backtrace.txt" 2>&1
    echo "   rc=$?; $(tail -2 "$W/fortify_backtrace.txt")"
  fi
  fi

  # The OCEAN reference: recorded before any rebuild. On a resume, the md5
  # saved by the first run is the reference.
  if [ -f "$W/ocean.md5" ]; then ocean_before=$(cat "$W/ocean.md5")
  else ocean_before=$(md5sum < "$BINS/OCEAN" | cut -c1-32); echo "$ocean_before" > "$W/ocean.md5"; fi

  if ! skip 2; then
  step "2/5 rebuild BARNES only, the tree's own flags, fortify off"
  ONLY=BARNES OPT= FORTIFY=0 bash "$HOME/build_splash_static.sh" go || fail "the rebuild failed (~/splash_static_build.log)"
  fi

  step "3/5 verify"
  ocean_after=$(md5sum < "$BINS/OCEAN" | cut -c1-32)
  [ "$ocean_before" = "$ocean_after" ] || fail "OCEAN changed ($ocean_before -> $ocean_after) -- the ocean B3 comparison depends on it"
  echo "   OCEAN byte-identical ($ocean_after)"
  bash "$HOME/build_splash_static.sh" verify
  # Did the flags reach the compiler? The build log holds the compile lines.
  n=$(grep -cE -- '-D_FORTIFY_SOURCE=0' "$HOME/splash_static_build.log" 2>/dev/null)
  echo "   compile lines with -D_FORTIFY_SOURCE=0 in the build log: ${n:-0}"
  grep -E -- '-c |-o BARNES' "$HOME/splash_static_build.log" 2>/dev/null | tail -2 | cut -c1-220 | sed 's/^/     /'
  # Which functions make fortified calls -- barnes's own, or glibc's?
  local prev own_fns callers app_hits
  prev=$(ls -t "$BINS"/BARNES.prev_* 2>/dev/null | head -1)
  echo "   fortified call sites by caller, rebuilt BARNES (top 8):"
  callers=$(fortified_callers "$BINS/BARNES"); echo "$callers" | head -8 | sed 's/^/     /'
  [ -n "$prev" ] && { echo "   ... and in the previous static build $(basename "$prev") (top 8):"; fortified_callers "$prev" | head -8 | sed 's/^/     /'; }
  # barnes's own function names, from the objects the static build left behind
  own_fns=$(nm --defined-only "$SPLASH"/barnes/*.o 2>/dev/null | awk '$2 ~ /^[Tt]$/ { print $3 }' | sort -u)
  [ -n "$own_fns" ] || fail "no barnes object files under $SPLASH/barnes to name its own functions -- cannot tell its calls from glibc's"
  echo "   barnes's own functions (from its objects): $(echo "$own_fns" | wc -l)"
  app_hits=$(echo "$callers" | awk '{ print $2 }' | grep -Fxf <(echo "$own_fns") || true)
  [ -z "$app_hits" ] || fail "barnes's own code still makes fortified calls, in: $(echo $app_hits)"
  echo "   BARNES: no fortified call in barnes's own functions (the rest are glibc-internal)"

  step "4/5 native run on the real input (20 s)"
  ( cd "$W" && timeout 20 "$BINS/BARNES" < "$in" ) > "$W/native_check.log" 2>&1; rc=$?
  tail -3 "$W/native_check.log" | sed 's/^/   /'
  [ "$rc" = 0 ] || [ "$rc" = 124 ] || fail "BARNES still fails natively (rc=$rc)"
  echo "   native ok (rc=$rc)"

  step "5/5 launch the barnes B3 gem5 runs"
  WL=barnes bash "$HOME/launch_b3_gem5.sh" go || fail "launch failed"
  rm -f "$PIDF"
  echo; echo "=== pipeline done $(date '+%F %T') -- the gem5 launcher continues in the background ==="
}

case "${1:-}" in
  go)
    mkdir -p "$W"
    alive && { echo "the pipeline is already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; }
    setsid bash "$0" __pipeline > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    echo "barnes pipeline running in the background; log: $LOG"
    echo "check: bash $0 status" ;;
  __pipeline) pipeline ;;
  status)
    alive && echo "(pipeline still running)"
    grep -E '^=== |STOPPED|saved:|byte-identical|fortified call|compile lines|own functions|native ok|rc=|^     +[0-9]+ ' "$LOG" 2>/dev/null | sed 's/^/   /'
    [ -f "$HOME/launch_b3_gem5.sh" ] && WL=barnes bash "$HOME/launch_b3_gem5.sh" status ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
