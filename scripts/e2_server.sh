#!/usr/bin/env bash
# E (bench/policy_sanity/second_protocol_design_2026-11-18.md), server side: gem5 MESI_Two_Level
# (stock FIFO buffers, no patch) on ocean 2 MB, canneal 4c, radix, fluidanimate at both B3 stops.
#   build: ~/gem5_two, a local clone of ~/gem5 at v25.1.0.1 (clean), defconfig build/X86 from
#          build_opts/X86 (must read PROTOCOL="MESI_Two_Level", one protocol on), gem5.opt at nice 19;
#          the binary must embed MESI_Two_Level controllers and no MESI_Three_Level one. ~/gem5 untouched.
#   QL1:   the micro (C's static binary, ~/ld/g5micro/micro_m5) on the 10 cases at ROUNDS 4 and 8 under
#          MESI_Two_Level (L1D 8 kB 8-way, L1I 32 kB, L2 256 kB 16-way); judged against C's MESI_Three_Level
#          runs (~/ld/g5micro/gem5) by e2_check.py ql1 once both sides have ended.
#   runs:  8 (4 programs x 2 stops), each the original's command through E's runner copy
#          (~/e2/run_gem5_splash.sh: GEM5_DIR=~/gem5_two, TWO_LEVEL_L1=l2c); QL0 on each config.ini (a
#          failure ends the run and stops launching); QEND when it ends; 168 h limit.
#   output ~/gem5_b3/e2/<program>/l2_2MB_mi<stop>M/<tag>; state ~/e2. Writes only under ~/e2, ~/gem5_two
#   and ~/gem5_b3/e2.
#
#   bash ~/e2/e2_server.sh guards     # read-only
#   bash ~/e2/e2_server.sh go         # (owner's word) guards, then the driver, detached: build, QL1's runs, the 8 runs
#   bash ~/e2/e2_server.sh status | list | stop [runs]
set -uo pipefail
SELF="$(readlink -f "$0")"
W="${W:-$HOME/e2}"
GSRC="${GSRC:-$HOME/gem5}"
G2="${G2:-$HOME/gem5_two}"
GEM5_TAG="${GEM5_TAG:-v25.1.0.1}"
OUTROOT="${OUTROOT:-$HOME/gem5_b3/e2}"
B3="${B3:-$HOME/gem5_b3}"
GRUN="${GRUN:-$W/run_gem5_splash.sh}"
LDW="${LDW:-$HOME/ld/g5micro}"           # C's QC1b: micro_m5 and the MESI_Three_Level micro runs
BUILD_JOBS="${BUILD_JOBS:-24}"
PAR="${PAR:-8}"; MPAR="${MPAR:-10}"
LIMIT_S="${LIMIT_S:-$((168 * 3600))}"
QV0_WAIT_S="${QV0_WAIT_S:-1800}"
POLL_S="${POLL_S:-300}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
MCASES="pp_lock pp_store pp_rmw readers upgrade ctl priv_E priv_S llc_out offchip"
EXIT_OK='because a thread reached the max instruction count'
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
export PATH="$HOME/.gem5-venv/bin:$HOME/.local/bin:$PATH"
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date '+%F %T'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
free_gb() { df -BG --output=avail "$HOME" | tail -1 | tr -dc 0-9; }
GBIN="$G2/build/X86/gem5.opt"

# program|original long|original short|mode|env|stop variable|long stop|short stop  (hset_server.sh's rows)
TABLE="${E2_TABLE:-}"
[ -n "$TABLE" ] || TABLE='ocean4|l2_2MB_mi150M/ocean_4c|l2_2MB_mi50M/ocean_4c|go-ocean-4c|LLC_SIZE=2MB|MAXINSTS|150000000|50000000
canneal4|canneal/l2_2MB_mi150M/canneal_4c|canneal/l2_2MB_mi50M/canneal_4c|go-canneal-4c|LLC_SIZE=2MB|WORKER_MAXINSTS|150000000|50000000
radix|heldout/radix/l2_2MB_mi930M/radix_4c|heldout/radix/l2_2MB_mi830M/radix_4c|go-radix-4c|LLC_SIZE=2MB BINS=@HOME@/splash-heldout|WORKER_MAXINSTS|930000000|830000000
fluidanimate|heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c|heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c|go-fluidanimate-4c|LLC_SIZE=2MB BINS=@HOME@/heldout2_static|WORKER_MAXINSTS|150000000|50000000'
table() { echo "$TABLE" | sed "s|@HOME@|$HOME|g"; }
tf() { table | awk -F'|' -v p="$1" -v f="$2" '$1 == p { print $f }'; }
jobs_e() { local stop p; for stop in long short; do for p in $(table | cut -d'|' -f1); do echo "$p|$stop"; done; done; }
stopv() { if [ "$2" = long ]; then tf "$1" 7; else tf "$1" 8; fi; }
orig() { if [ "$2" = long ]; then tf "$1" 2; else tf "$1" 3; fi; }
odir() { echo "$OUTROOT/$1/l2_2MB_mi$(( $(stopv "$1" "$2") / 1000000 ))M/$(basename "$(orig "$1" "$2")")"; }
st() { echo "$W/state/$1_$2"; }
result() { cat "$(st "$1" "$2")/RESULT" 2>/dev/null; }
gem5_pid() { pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$1 " 2>/dev/null | head -1; }

# ---------------------------------------------------------------- the gem5 build
build_ok() { [ -x "$GBIN" ] && [ "$(cat "$W/BUILD_OK" 2>/dev/null)" = "$(md5sum < "$GBIN" | cut -c1-32)" ]; }
build() {
  if build_ok; then echo "$(ts) BUILD: kept, $GBIN (md5 $(cut -c1-8 "$W/BUILD_OK"))"; return 0; fi
  echo "$(ts) BUILD START: $G2 from $GSRC at $GEM5_TAG, MESI_Two_Level, $BUILD_JOBS jobs, nice 19"
  if [ ! -d "$G2/.git" ]; then git clone -q "$GSRC" "$G2" || { echo "$(ts) BUILD FAILED: clone"; return 1; }; fi
  git -C "$G2" checkout -q "$GEM5_TAG" 2>&1 || { echo "$(ts) BUILD FAILED: checkout $GEM5_TAG"; return 1; }
  [ "$(git -C "$G2" describe --tags)" = "$GEM5_TAG" ] || { echo "$(ts) BUILD FAILED: $G2 is not at $GEM5_TAG"; return 1; }
  local t; t=$(git -C "$G2" status --porcelain --untracked-files=no)
  [ -z "$t" ] || { echo "$(ts) BUILD FAILED: $G2 has changes: $t"; return 1; }
  ( cd "$G2" && scons defconfig build/X86 build_opts/X86 ) > "$W/build_defconfig.log" 2>&1 || { tail -5 "$W/build_defconfig.log"; echo "$(ts) BUILD FAILED: defconfig"; return 1; }
  local cfg="$G2/build/X86/gem5.build/config" n
  grep -qx 'PROTOCOL="MESI_Two_Level"' "$cfg" || { grep PROTOCOL "$cfg"; echo "$(ts) BUILD FAILED: defconfig does not read PROTOCOL=\"MESI_Two_Level\""; return 1; }
  n=$(grep -cE '^[A-Za-z0-9_]*PROTOCOL_[A-Za-z0-9_]+=y' "$cfg")
  [ "$n" = 1 ] || { grep -E 'PROTOCOL_[A-Za-z0-9_]+=y' "$cfg"; echo "$(ts) BUILD FAILED: $n protocols on, not 1"; return 1; }
  echo "$(ts) BUILD: config $(grep -E '^[A-Za-z0-9_]*PROTOCOL_[A-Za-z0-9_]+=y|^PROTOCOL=' "$cfg" | tr '\n' ' ')"
  ( cd "$G2" && nice -n 19 scons build/X86/gem5.opt -j"$BUILD_JOBS" ) > "$W/build.log" 2>&1 || { tail -15 "$W/build.log"; echo "$(ts) BUILD FAILED: scons ($W/build.log)"; return 1; }
  "$GBIN" --help > /dev/null 2>&1 || { echo "$(ts) BUILD FAILED: the binary does not run"; return 1; }
  local two three
  two=$(strings -a "$GBIN" | grep -c 'MESI_Two_Level_L1Cache_Controller')
  three=$(strings -a "$GBIN" | grep -c 'MESI_Three_Level_L1Cache_Controller')
  [ "$two" -gt 0 ] && [ "$three" = 0 ] || { echo "$(ts) BUILD FAILED: MESI_Two_Level references $two, MESI_Three_Level $three"; return 1; }
  echo MESI_Two_Level > "$G2/.gem5_protocol"; echo X86 > "$G2/.gem5_build_dir"
  md5sum < "$GBIN" | cut -c1-32 > "$W/BUILD_OK"
  echo "$(ts) BUILD DONE: $GBIN md5 $(cut -c1-8 "$W/BUILD_OK"); MESI_Two_Level only ($two references)"
}

# ---------------------------------------------------------------- QL1: the micro under MESI_Two_Level
ql1_runs() {
  local c r od n=0 waited=0
  while [ ! -x "$LDW/micro_m5" ]; do
    [ "$waited" = 0 ] && echo "$(ts) QL1: waiting for C's micro binary $LDW/micro_m5"
    sleep "$POLL_S"; waited=$((waited + POLL_S))
  done
  mkdir -p "$W/g5micro"
  if [ ! -x "$W/g5micro/micro_m5" ]; then cp -p "$LDW/micro_m5" "$W/g5micro/micro_m5"; fi
  cmp -s "$LDW/micro_m5" "$W/g5micro/micro_m5" || { echo "$(ts) QL1 FAILED: $W/g5micro/micro_m5 differs from C's"; return 1; }
  echo "$(ts) QL1: micro_m5 md5 $(md5sum < "$W/g5micro/micro_m5" | cut -c1-12) (C's); 20 MESI_Two_Level runs, $MPAR at a time"
  for r in 4 8; do for c in $MCASES; do
    od="$W/g5micro/gem5/${c}_r$r"
    if [ -f "$od/stats.txt" ] && grep -q "Exiting @ tick" "$od/run.log" 2>/dev/null; then continue; fi
    while [ "$(jobs -rp | wc -l)" -ge "$MPAR" ]; do sleep 20; done
    rm -rf "$od"; mkdir -p "$od"
    ( cd "$od" && nice -n 19 "$GBIN" --outdir="$od" "$G2/configs/deprecated/example/se.py" --ruby --num-cpus=4 --cpu-type=TimingSimpleCPU --mem-size=4GB \
        --l1d_size=8kB --l1d_assoc=8 --l1i_size=32kB --l1i_assoc=8 --l2_size=256kB --l2_assoc=16 --num-l2caches=1 \
        -c "$W/g5micro/micro_m5" --options="$c $r" < /dev/null > "$od/run.log" 2>&1 ) &
    n=$((n + 1))
  done; done
  wait
  echo "$(ts) QL1: $n MESI_Two_Level micro runs ended; waiting for C's MESI_Three_Level runs"
  local c3
  while :; do
    c3=0; for r in 4 8; do for c in $MCASES; do grep -q "Exiting @ tick" "$LDW/gem5/${c}_r$r/run.log" 2>/dev/null && c3=$((c3 + 1)); done; done
    [ "$c3" = 20 ] && break
    sleep "$POLL_S"
  done
  python3 "$W/e2_check.py" ql1 "$W/g5micro/gem5" "$LDW/gem5" > "$W/ql1.txt" 2>&1
  local rc=$?
  sed 's/^/      /' "$W/ql1.txt"
  if [ "$rc" = 0 ]; then md5sum < "$GBIN" | cut -c1-32 > "$W/QL1_PASSED"; echo "$(ts) QL1 HOLDS"; else echo "$(ts) QL1 FAILED"; fi
}

# ---------------------------------------------------------------- the 8 runs
launch() {   # p stop
  local p=$1 stop=$2 s env sv
  s=$(st "$p" "$stop"); mkdir -p "$s"
  env=$(tf "$p" 5); sv=$(tf "$p" 6)
  echo "$(ts) LAUNCH $p $stop: $(tf "$p" 4) $env $sv=$(stopv "$p" "$stop") on $G2 (MESI_Two_Level, TWO_LEVEL_L1=l2c)"
  # shellcheck disable=SC2086 -- $env is a list of assignments
  ( cd "$HOME" && env GEM5_DIR="$G2" TWO_LEVEL_L1=l2c OUT="$OUTROOT/$p/l2_2MB_mi$(( $(stopv "$p" "$stop") / 1000000 ))M" \
      OCEAN_GRID=514 $env "$sv=$(stopv "$p" "$stop")" bash "$GRUN" "$(tf "$p" 4)" ) > "$s/launch.log" 2>&1
  local rc=$?
  sed 's/^/      /' "$s/launch.log"
  return $rc
}

settle() {
  local p stop s od pid t0 line
  while IFS='|' read -r p stop; do
    s=$(st "$p" "$stop"); od=$(odir "$p" "$stop")
    [ -f "$s/STARTED" ] && [ -z "$(result "$p" "$stop")" ] || continue
    pid=$(gem5_pid "$od")
    if [ -n "$pid" ]; then
      t0=$(cat "$s/STARTED")
      if [ $(( $(date +%s) - t0 )) -gt "$LIMIT_S" ]; then kill "$pid"; echo "$(ts) $p $stop: past the limit -- ended"; sleep 5; else continue; fi
    fi
    line=$(python3 "$W/hset_check.py" qend "$od" 1 2>&1 | tail -1)
    echo "${line#QEND }" > "$s/RESULT"
    echo "$(ts) $p $stop: ${line#QEND }"
  done < <(jobs_e)
}

running() { local n=0 p stop; while IFS='|' read -r p stop; do [ -n "$(gem5_pid "$(odir "$p" "$stop")")" ] && n=$((n + 1)); done < <(jobs_e); echo "$n"; }

drive() {
  echo $$ > "$PIDF"
  echo "$(ts) E DRIVER START (pid $$)"
  build || { rm -f "$PIDF"; echo "$(ts) E DRIVER END: the build failed"; return 1; }
  ql1_runs > "$W/ql1_driver.log" 2>&1 &
  local stop_launching=0 p stop s od waited pid
  while IFS='|' read -r p stop; do
    s=$(st "$p" "$stop"); od=$(odir "$p" "$stop")
    [ -z "$(result "$p" "$stop")" ] || { echo "$(ts) SKIP $p $stop: $(result "$p" "$stop")"; continue; }
    if [ -n "$(gem5_pid "$od")" ]; then echo "$(ts) $p $stop: already running -- left alone"; [ -f "$s/STARTED" ] || date +%s > "$s/STARTED"; continue; fi
    while :; do settle; [ "$stop_launching" = 0 ] || break; [ "$(running)" -lt "$PAR" ] && [ "$(free_gb)" -ge "$MIN_FREE_GB" ] && break; sleep "$POLL_S"; done
    if [ "$stop_launching" != 0 ]; then mkdir -p "$s"; echo "NOT RUN (launching stopped)" > "$s/RESULT"; continue; fi
    rm -f "$s/STARTED"
    if ! launch "$p" "$stop"; then echo "LAUNCH-FAILED" > "$s/RESULT"; echo "$(ts) $p $stop: LAUNCH FAILED -- launching stops"; stop_launching=1; continue; fi
    waited=0
    while [ ! -s "$od/config.ini" ] && [ "$waited" -lt "$QV0_WAIT_S" ]; do sleep 10; waited=$((waited + 10)); done
    sleep 5
    if python3 "$W/e2_check.py" ql0 "$B3/$(orig "$p" "$stop")" "$od" "$GSRC" "$G2" > "$s/ql0.txt" 2>&1; then
      echo "$(ts) $p $stop: $(tail -1 "$s/ql0.txt")"; date +%s > "$s/STARTED"
    else
      sed 's/^/      /' "$s/ql0.txt"
      pid=$(gem5_pid "$od"); [ -z "$pid" ] || kill "$pid"
      echo "VOID (QL0 failed: $(tail -1 "$s/ql0.txt"))" > "$s/RESULT"
      echo "$(ts) $p $stop: QL0 FAILED -- run ended, launching stops"; stop_launching=1
    fi
  done < <(jobs_e)
  echo "$(ts) ALL LAUNCHED OR SKIPPED; waiting for the runs"
  local open
  while :; do
    settle; open=0
    while IFS='|' read -r p stop; do [ -n "$(result "$p" "$stop")" ] || open=$((open + 1)); done < <(jobs_e)
    [ "$open" = 0 ] && break
    sleep "$POLL_S"
  done
  wait
  echo "$(ts) E DRIVER END: $(grep -c . <(for x in "$W"/state/*/RESULT; do grep -h 'ENDED-AT-STOP' "$x"; done 2>/dev/null)) of 8 ended at their stop; QL1 $([ -f "$W/QL1_PASSED" ] && echo holds || echo 'not passed')"
  rm -f "$PIDF"
}

guards() {
  local bad=0 p f stop t
  ok() { echo "   ok   $*"; }
  no() { echo "   FAIL $*"; bad=1; }
  [ "$(git -C "$GSRC" describe --tags 2>/dev/null)" = "$GEM5_TAG" ] && ok "$GSRC at $GEM5_TAG (the clone's source)" || no "$GSRC is not at $GEM5_TAG"
  command -v scons > /dev/null && ok "scons $(command -v scons)" || no "no scons on PATH"
  [ -s "$GRUN" ] && bash -n "$GRUN" && grep -q 'TWO_LEVEL_L1' "$GRUN" && ok "E's runner copy $GRUN (md5 $(md5sum < "$GRUN" | cut -c1-8); TWO_LEVEL_L1)" || no "no usable $GRUN with TWO_LEVEL_L1"
  python3 -m py_compile "$W/hset_check.py" && python3 "$W/e2_check.py" selftest > "$W/selftest.txt" 2>&1 && ok "e2_check.py selftest ($(tail -1 "$W/selftest.txt"))" || no "e2_check.py / hset_check.py not usable"
  for p in $(table | cut -d'|' -f1); do
    for stop in long short; do
      f="$B3/$(orig "$p" "$stop")"
      if [ -f "$f/config.ini" ] && grep -q '^finalTick' "$f/stats.txt" 2>/dev/null && grep -q "$EXIT_OK" "$f/run.log" 2>/dev/null \
         && grep -q '^\[system.ruby.l0_cntrl0\]$' "$f/config.ini"; then ok "$p $stop: original $(orig "$p" "$stop") ended at its stop (MESI_Three_Level)"
      else no "$p $stop: original $f incomplete or not MESI_Three_Level"; fi
    done
  done
  alive "$PIDF" && no "the E driver is running (pid $(cat "$PIDF"))" || ok "no E driver running"
  t=$(free_gb); [ "${t:-0}" -ge "$MIN_FREE_GB" ] && ok "disk $t GB free" || no "disk $t GB free (< $MIN_FREE_GB)"
  return $bad
}

list() {
  local p stop r
  echo "-- the build: $(build_ok && echo "done (md5 $(cut -c1-8 "$W/BUILD_OK"))" || echo 'not done')"
  echo "-- QL1: $([ -f "$W/QL1_PASSED" ] && echo holds || tail -1 "$W/ql1_driver.log" 2>/dev/null || echo 'not started')"
  while IFS='|' read -r p stop; do
    r=$(result "$p" "$stop")
    if [ -z "$r" ]; then
      if [ -n "$(gem5_pid "$(odir "$p" "$stop")")" ]; then r="running $(( ($(date +%s) - $(cat "$(st "$p" "$stop")/STARTED" 2>/dev/null || date +%s)) / 3600 )) h"; else r=pending; fi
    fi
    printf '   %-13s %-5s %s\n' "$p" "$stop" "$r"
  done < <(jobs_e)
}

case "${1:-}" in
  guards) echo "== E guards"; guards ;;
  list) list ;;
  go)
    mkdir -p "$W/state" "$OUTROOT"
    alive "$PIDF" && die "the E driver is running -- 'status'"
    echo "== guards"; guards || die "a guard failed (above) -- nothing started"
    setsid nohup bash "$SELF" __drive >> "$LOG" 2>&1 < /dev/null &
    sleep 3
    alive "$PIDF" && echo "E driver started (pid $(cat "$PIDF")); log $LOG" || { tail -3 "$LOG"; die "the driver did not start"; } ;;
  __drive) drive ;;
  status)
    echo "== E (MESI_Two_Level): driver $(alive "$PIDF" && echo alive || echo 'not running'); $(free_gb) GB free"
    list
    tail -n 4 "$LOG" 2>/dev/null | sed 's/^/   /' ;;
  stop)
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'e2_server.sh __drive' || die "pid $sid is not an e2_server.sh driver -- stopping nothing"
      pkill -TERM -s "$sid"; rm -f "$PIDF"; echo "driver stopped (session $sid: the driver and QL1's micro runs; the 8 runs have their own sessions)"
    fi
    if [ "${2:-}" = runs ]; then
      pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$OUTROOT/" | while read -r x; do kill "$x" && echo "ended gem5 pid $x"; done
      pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$W/g5micro/" | while read -r x; do kill "$x" && echo "ended micro gem5 pid $x"; done
    fi ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
