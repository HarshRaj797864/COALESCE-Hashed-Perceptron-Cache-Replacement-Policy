#!/usr/bin/env bash
# Q16's ChampSim half on the server (breadth_bc_design_2026-11-10.md,
# amendment 5; moved from the laptop by amendment 8): the micro program at 16
# threads (actors on threads 12-15), traced with Pin, replayed on the frozen
# champsim_g6_1e3060c1 at levels 0, 1 and 2, in two forms side by side:
#   timed     timed waits, traced without sync records (the micro test's form)
#   barrier   -DBARRIER_STEPS, traced with -sync 1 (Q2's form)
# Each form is bench/micro_champsim.sh as committed, run from ~/q16cs/root (the
# four files it needs, uploaded by scripts/q16cs_all.sh); its traces go to
# /tmp/harshraj_q16cs (on /, not on the nearly full /home) and are removed by
# the harness when it ends. Writes only ~/q16cs and that directory.
#
#   bash ~/q16cs_server.sh go       # guards, numpy in ~/q16cs/venv (pip, once), then both forms, detached
#   bash ~/q16cs_server.sh status   # how far each form is
#   bash ~/q16cs_server.sh stop     # ends both forms (only their own session)
#   bash ~/q16cs_server.sh diag FORM CASE LEVEL   # q16_results_2026-11-13.md: one case at one level in one
#                                   # form, the event log kept (KEEP_EVENTS=1), into ~/q16cs/diag_FORM_CASE_LLEVEL
set -uo pipefail
SELF="$(readlink -f "$0")"
W="${W:-$HOME/q16cs}"
ROOTD="$W/root"
S="${S:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator}"
BIN="${BIN:-$S/bin/champsim_g6_1e3060c1}"
BIN_MD5="${BIN_MD5:-1e3060c1760b4b3b18e5728a9dfb75ed}"
TRACER="${TRACER:-$HOME/sync_h2_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so}"
TRACER_MD5="${TRACER_MD5:-02ff8f48654b81f6f277cdac8a13d60b}"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
TMPD="${TMPD:-/tmp/harshraj_q16cs}"
NUMPY="${NUMPY:-2.4.6}"                    # the laptop's, where micro_trim.py was written and checked
CASES="${CASES:-pp_lock pp_store pp_rmw readers upgrade ctl priv_E priv_S llc_out offchip s16}"
JOBS="${JOBS:-6}"                          # ChampSim runs at once, per form
PIDF="$W/.driver.pid"
LOG="$W/driver.log"
FORMS="timed barrier"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "STOPPED: $*"; exit 1; }
nlev() { echo 3; }
want_x() { echo $(( ($(echo "$CASES" | wc -w) + 1) * $(nlev) )); }   # xline files when a form is done

guards() {
  local f
  for f in bench/micro_champsim.sh bench/micro_trim.py bench/coherence_micro.c simulator/scripts/make_config.py; do
    [ -s "$ROOTD/$f" ] || die "no $ROOTD/$f -- scripts/q16cs_all.sh uploads it"
  done
  [ -x "$BIN" ] && [ "$(md5sum < "$BIN" | cut -c1-32)" = "$BIN_MD5" ] || die "no $BIN with md5 $BIN_MD5"
  [ -f "$TRACER" ] && [ "$(md5sum < "$TRACER" | cut -c1-32)" = "$TRACER_MD5" ] || die "no tracer $TRACER with md5 $TRACER_MD5"
  [ -x "$PIN_ROOT/pin" ] || die "no Pin at $PIN_ROOT"
  command -v gcc > /dev/null || die "no gcc"
  mkdir -p "$TMPD" || die "cannot create $TMPD"
  local free; free=$(df -Pk "$TMPD" | awk 'NR == 2 { print int($4 / 1048576) }')
  [ "$free" -ge 200 ] || die "only $free GB free under $TMPD (want 200)"
  echo "guards: binary $(basename "$BIN") md5 ${BIN_MD5:0:8}; tracer md5 ${TRACER_MD5:0:8}; Pin; $free GB free under $TMPD"
}

venv() {
  if ! "$W/venv/bin/python3" -c "import numpy, sys; sys.exit(numpy.__version__ != '$NUMPY')" 2>/dev/null; then
    echo "numpy $NUMPY into $W/venv (pip; the server's python3 has none)"
    rm -rf "$W/venv"
    python3 -m venv "$W/venv" || die "python3 -m venv failed"
    "$W/venv/bin/pip" install -q "numpy==$NUMPY" > "$W/pip.log" 2>&1 || { tail -5 "$W/pip.log"; die "pip install numpy==$NUMPY failed"; }
  fi
  "$W/venv/bin/python3" -c "import numpy; print('numpy', numpy.__version__, 'in', '$W/venv')" || die "numpy does not import"
}

form() {   # timed | barrier [CASES LEVELS OUT KEEP]
  local f="$1" out="${4:-$W/out_$1}" mf="" ta="" cases="${2:-$CASES}" levels="${3:-0 1 2}" keep="${5:-}"
  [ "$f" = barrier ] && { mf="-DBARRIER_STEPS"; ta="-sync 1"; }
  rm -rf "$out"; mkdir -p "$out" "$TMPD"
  echo "$(date '+%F %T') START $f (MICRO_CFLAGS '$mf', TRACER_ARGS '$ta')"
  local tag="$f"; [ -n "$keep" ] && tag="$(basename "$out")"
  PATH="$W/venv/bin:$PATH" TMPDIR="$TMPD" NT=16 ACT0=12 LEVELS="$levels" JOBS="$JOBS" KEEP_EVENTS="$keep" \
    BIN="$BIN" TRACER="$TRACER" PIN_ROOT="$PIN_ROOT" OUT="$out" MICRO_CFLAGS="$mf" TRACER_ARGS="$ta" \
    nice -n 19 bash "$ROOTD/bench/micro_champsim.sh" "$cases" > "$W/form_$tag.log" 2>&1
  local rc=$?
  echo "$rc" > "$W/RC_$tag"
  echo "$(date '+%F %T') END   $tag rc=$rc; $(ls "$out"/*.xline 2>/dev/null | wc -l) counts"
}

drive() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') DRIVER START: forms $FORMS, cases control $CASES, levels 0 1 2, $JOBS runs at once per form"
  local f
  for f in $FORMS; do form "$f" & done
  wait
  rmdir "$TMPD" 2>/dev/null
  echo "$(date '+%F %T') DRIVER END"
  rm -f "$PIDF"
}

case "${1:-}" in
  go)
    mkdir -p "$W"
    alive "$PIDF" && { echo "running already (pid $(cat "$PIDF")) -- 'status'"; exit 0; }
    guards
    venv
    rm -f "$W"/RC_*
    setsid bash "$SELF" __drive >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$PIDF" || { tail -5 "$LOG"; die "the driver stopped (above; $LOG)"; }
    echo "started: both forms, detached; log $LOG" ;;
  __drive) drive ;;
  diag)
    [ $# = 4 ] && case "$2" in timed|barrier) true ;; *) false ;; esac && case "$4" in 0|1|2) true ;; *) false ;; esac \
      || die "usage: $0 diag timed|barrier CASE LEVEL"
    mkdir -p "$W"
    alive "$PIDF" && die "the forms' driver is running (pid $(cat "$PIDF")) -- 'status'"
    guards; venv
    t="diag_$2_$3_L$4"; rm -rf "$W/$t" "$W/RC_$t"
    setsid bash "$SELF" __diag "$2" "$3" "$4" "$W/$t" >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$PIDF" || { tail -5 "$LOG"; die "the diagnosis stopped (above; $LOG)"; }
    echo "started: $t (control and $3 at level $4, $2 form, event log kept); log $LOG" ;;
  __diag)
    echo $$ > "$PIDF"
    echo "$(date '+%F %T') DIAG START: $2 form, $3 at level $4, event log kept -> $5"
    form "$2" "$3" "$4" "$5" 1
    rmdir "$TMPD" 2>/dev/null
    echo "$(date '+%F %T') DIAG END"
    rm -f "$PIDF" ;;
  status)
    echo "== Q16, ChampSim half: driver $(alive "$PIDF" && echo alive || echo 'not running')"
    for f in $FORMS; do
      echo "   $f: $(ls "$W/out_$f"/*.xline 2>/dev/null | wc -l) of $(want_x) counts written; exit code $(cat "$W/RC_$f" 2>/dev/null || echo -)"
      [ -f "$W/form_$f.log" ] && tail -n 2 "$W/form_$f.log" | sed 's/^/      /'
    done
    [ -f "$LOG" ] && tail -n 3 "$LOG" | sed 's/^/   /'
    exit 0 ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'q16cs_server.sh __drive' || die "pid $sid is not the Q16 driver -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2; rm -f "$PIDF"; echo "stopped (session $sid)"
    else
      echo "not running"
    fi ;;
  *) echo "usage: $0 go | status | stop"; exit 1 ;;
esac
