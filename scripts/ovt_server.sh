#!/usr/bin/env bash
# H1b (bench/policy_sanity/fifo_overtake_design_2026-11-14.md), server side: a
# copy of ~/gem5 (~/gem5_ovt) with a records-only overtake log in
# MessageBuffer::enqueue, built; QO-S (the micro under both binaries, stats
# equal); then, once H1's driver has ended, the 13 scored gem5 configurations
# rerun exactly as scored with that binary. Writes only ~/gem5_ovt,
# ~/gem5_ovt_w (scripts, logs) and ~/gem5_b3/ovt (the runs). The live
# ~/gem5, its binary and configs, and ~/run_gem5_splash.sh are not touched.
#
#   bash ~/gem5_ovt_w/ovt_server.sh guards        # read-only checks
#   bash ~/gem5_ovt_w/ovt_server.sh list          # the 13 and their originals
#   bash ~/gem5_ovt_w/ovt_server.sh chain         # (owner's word) guards, then copy/patch/build, QO-S, wait for H1, runs -- detached
#   bash ~/gem5_ovt_w/ovt_server.sh status
#   bash ~/gem5_ovt_w/ovt_server.sh stop [runs]   # the driver (and its build); with 'runs', H1b's gem5 runs too
set -uo pipefail
W="${W:-$HOME/gem5_ovt_w}"
TREE="${TREE:-$HOME/gem5_ovt}"
OUTROOT="${OUTROOT:-$HOME/gem5_b3/ovt}"
B3="${B3:-$HOME/gem5_b3}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
GEM5_TAG="${GEM5_TAG:-v25.1.0.1}"
SCONS="${SCONS:-$HOME/.gem5-venv/bin/scons}"
JOBS="${JOBS:-8}"
MICRO="${MICRO:-$HOME/micro/micro_m5}"
H1_PIDF="${H1_PIDF:-$HOME/gem5_fifo/.driver.pid}"
H1_OUT="${H1_OUT:-$HOME/gem5_b3/fifo}"
PAR="${PAR:-4}"
LIMIT_S="${LIMIT_S:-$((96 * 3600))}"
QO0_WAIT_S="${QO0_WAIT_S:-900}"
LOG_WAIT_S="${LOG_WAIT_S:-1800}"   # the counter log opens at the first enqueue; start-up under load can be slow
POLL_S="${POLL_S:-600}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
PIDF="$W/.driver.pid"
DLOG="$W/driver.log"
BIN="$TREE/build/X86/gem5.opt"
MBC=src/mem/ruby/network/MessageBuffer.cc
MODE="${1:-}"
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date '+%F %T'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# n|name|original (under $B3)|short stop (under $B3)|run_gem5_splash.sh mode|settings -- H1's table
ENTRIES='01|ocean2|l2_2MB_mi150M/ocean_4c|l2_2MB_mi50M/ocean_4c|go-ocean-4c|LLC_SIZE=2MB MAXINSTS=150000000
02|ocean8|l2_8MB_mi150M/ocean_4c|l2_8MB_mi50M/ocean_4c|go-ocean-4c|LLC_SIZE=8MB MAXINSTS=150000000
03|canneal4_2MB|canneal/l2_2MB_mi150M/canneal_4c|canneal/l2_2MB_mi50M/canneal_4c|go-canneal-4c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000
04|canneal4_8MB|canneal/l2_8MB_mi150M/canneal_4c|canneal/l2_8MB_mi50M/canneal_4c|go-canneal-4c|LLC_SIZE=8MB WORKER_MAXINSTS=150000000
05|canneal8|canneal8/l2_2MB_mi150M/canneal_8c|canneal8/l2_2MB_mi50M/canneal_8c|go-canneal-8c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000
06|barnes|barnes/l2_2MB_mi150M/barnes_4c|barnes/l2_2MB_mi50M/barnes_4c|go-barnes-4c|LLC_SIZE=2MB MAXINSTS=150000000
07|barnes256|barnes_leaf256/l2_2MB_mi150M/barnes_4c|barnes_leaf256/l2_2MB_mi50M/barnes_4c|go-barnes-4c|LLC_SIZE=2MB MAXINSTS=150000000 BINS=@HOME@/splash-static-leaf256
08|radix|heldout/radix/l2_2MB_mi930M/radix_4c|heldout/radix/l2_2MB_mi830M/radix_4c|go-radix-4c|LLC_SIZE=2MB WORKER_MAXINSTS=930000000 BINS=@HOME@/splash-heldout
09|lunc|newbench/lunc/l2_2MB_mi150M/lunc_4c|newbench/lunc/l2_2MB_mi50M/lunc_4c|go-lunc-4c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000 BINS=@HOME@/splash-newbench
10|streamcluster|newbench/streamcluster/l2_2MB_mi150M/streamcluster_4c|newbench/streamcluster/l2_2MB_mi50M/streamcluster_4c|go-streamcluster-4c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000 BINS=@HOME@/splash-newbench
11|fluidanimate|heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c|heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c|go-fluidanimate-4c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000 BINS=@HOME@/heldout2_static
12|vips|heldout2/vips/l2_2MB_mi150M/vips_4c|heldout2/vips/l2_2MB_mi50M/vips_4c|go-vips-4c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000 BINS=@HOME@/heldout2_static
13|oceannc|heldout2/oceannc/l2_2MB_mi150M/oceannc_4c|heldout2/oceannc/l2_2MB_mi50M/oceannc_4c|go-oceannc-4c|LLC_SIZE=2MB WORKER_MAXINSTS=150000000 BINS=@HOME@/heldout2_static'
ONLY="${ONLY:-}"

entries() { echo "$ENTRIES" | sed "s|@HOME@|$HOME|g" | while IFS='|' read -r n rest; do
  [ -z "$ONLY" ] || [[ " $ONLY " == *" $n "* ]] || continue; echo "$n|$rest"; done; }
odir_of() { echo "$OUTROOT/$1_$2/$(basename "$3")"; }
gem5_pid() { pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$1 " 2>/dev/null | head -1; }
result() { cat "$OUTROOT/$1_$2/RESULT" 2>/dev/null; }

# the one change: inserted before the strict-FIFO check, the check's own condition
patch_src() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
inc = '#include <cassert>\n'
anchor = '    // Check the arrival time\n    assert(arrival_time >= current_time);\n'
assert s.count(inc) == 1 and s.count(anchor) == 1 and 'COALESCE H1b' not in s, 'anchors not found once'
blk = '''    // COALESCE H1b (bench/policy_sanity/fifo_overtake_design_2026-11-14.md),
    // records only: every message that arrives before the previous one enqueued
    // in this buffer -- the strict-FIFO check's own condition -- whether or not
    // the buffer is ordered, appended to $COALESCE_OVERTAKE_LOG (opened, empty,
    // at the run's first enqueue). Nothing else changes.
    static std::FILE *coalesce_ovt = [] {
        const char *p = std::getenv("COALESCE_OVERTAKE_LOG");
        return p ? std::fopen(p, "w") : nullptr;
    }();
    if (coalesce_ovt &&
        !(bypassStrictFIFO || m_last_message_strict_fifo_bypassed) &&
        arrival_time < m_last_arrival_time) {
        std::fprintf(coalesce_ovt, "%llu %s %llu %llu %llu %d\\n",
                     (unsigned long long)current_time, name().c_str(),
                     (unsigned long long)delta,
                     (unsigned long long)arrival_time,
                     (unsigned long long)m_last_arrival_time,
                     (int)m_strict_fifo);
        std::fflush(coalesce_ovt);
    }

'''
s = s.replace(inc, inc + '#include <cstdio>\n#include <cstdlib>\n', 1).replace(anchor, blk + anchor, 1)
open(p, 'w').write(s)
PY
}

guards() {
  local bad=0 n name orig short mode env t
  ok() { echo "   ok   $*"; }
  no() { echo "   FAIL $*"; bad=1; }
  [ "$(git -C "$GEM5_DIR" describe --tags 2>/dev/null)" = "$GEM5_TAG" ] && ok "gem5 at $GEM5_TAG" || no "gem5 is not at $GEM5_TAG"
  t=$(git -C "$GEM5_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort | tr '\n' ';')
  [ "$t" = " M configs/ruby/MESI_Three_Level.py;?? .gem5_protocol;?? configs/ruby/MESI_Three_Level.py.orig_fifo;" ] \
    && ok "the live gem5 tree differs from $GEM5_TAG only by the FIFO patch" || no "the live gem5 tree has other changes: $t"
  [ "$(grep -c 'COALESCE: setup_gem5.sh patch-fifo' "$GEM5_DIR/configs/ruby/MESI_Three_Level.py")" = 2 ] && ok "the live configs are patched as scored" || no "the live configs are not as scored"
  [ -x "$GEM5_DIR/build/X86/gem5.opt" ] && ok "live gem5 binary present" || no "no live gem5 binary"
  if [ -f "$TREE/BUILT" ]; then ok "the counter build exists ($(cat "$TREE/BUILT"))"
  elif [ -e "$TREE" ]; then no "$TREE exists without BUILT (a half-made copy? remove it)"
  else [ -x "$SCONS" ] && ok "scons $SCONS" || no "no scons at $SCONS"; fi
  [ -x "$MICRO" ] && file -b "$MICRO" | grep -q 'statically linked' && ok "micro $MICRO" || no "no static micro at $MICRO"
  grep -q 'GEM5_BIN' "$W/run_gem5_splash.sh" 2>/dev/null && bash -n "$W/run_gem5_splash.sh" && ok "H1b's run_gem5_splash.sh copy has GEM5_BIN" || no "no usable $W/run_gem5_splash.sh"
  python3 "$W/ovt_check.py" selftest > /dev/null 2>&1 && ok "ovt_check.py self-test" || no "ovt_check.py self-test fails"
  while IFS='|' read -r n name orig short mode env; do
    [ -n "$n" ] || continue
    if [ -f "$B3/$orig/config.ini" ] && [ -f "$B3/$orig/stats.txt" ] && grep -q 'because a thread reached the max instruction count' "$B3/$orig/run.log" 2>/dev/null \
       && grep -q '^finalTick' "$B3/$short/stats.txt" 2>/dev/null; then ok "$n $name: original and short stop present"
    else no "$n $name: original $orig or short stop $short incomplete"; fi
  done < <(entries)
  alive "$PIDF" && no "an H1b driver is running (pid $(cat "$PIDF"))" || ok "no H1b driver running"
  t=$(df -Pk "$HOME" | awk 'NR == 2 { print int($4 / 1048576) }')
  [ "${t:-0}" -ge "$MIN_FREE_GB" ] && ok "disk ${t} GB free" || no "disk ${t} GB free (< $MIN_FREE_GB)"
  return $bad
}

build() {
  if [ -f "$TREE/BUILT" ]; then echo "$(ts) BUILD present: $(cat "$TREE/BUILT")"; return 0; fi
  echo "$(ts) COPY $GEM5_DIR -> $TREE"
  rm -rf "$TREE.tmp"
  cp -a "$GEM5_DIR" "$TREE.tmp" || { echo "$(ts) copy failed"; return 1; }
  patch_src "$TREE.tmp/$MBC" || { echo "$(ts) patch failed"; return 1; }
  local add del
  add=$(diff "$GEM5_DIR/$MBC" "$TREE.tmp/$MBC" | grep -c '^>'); del=$(diff "$GEM5_DIR/$MBC" "$TREE.tmp/$MBC" | grep -c '^<')
  [ "$del" = 0 ] && [ "$add" -gt 20 ] || { echo "$(ts) the patch is not additions only (+$add -$del)"; return 1; }
  mv "$TREE.tmp" "$TREE" || return 1
  echo "$(ts) PATCHED $MBC (+$add lines, -0); BUILD scons build/X86/gem5.opt -j$JOBS, nice 19"
  ( cd "$TREE" && nice -n 19 "$SCONS" build/X86/gem5.opt -j"$JOBS" --ignore-style < /dev/null ) > "$W/build.log" 2>&1
  local rc=$?
  echo "$(ts) scons rc=$rc ($(grep -c '\[ *CXX\]' "$W/build.log") compiled, $(grep -c '\[ *LINK\]' "$W/build.log") linked)"
  [ "$rc" = 0 ] && [ -x "$BIN" ] && [ "$BIN" -nt "$TREE/$MBC" ] || { echo "$(ts) BUILD FAILED"; return 1; }
  [ "$(strings -a "$BIN" | grep -c COALESCE_OVERTAKE_LOG)" -ge 1 ] || { echo "$(ts) the binary lacks the counter"; return 1; }
  echo "md5 $(md5sum < "$BIN" | cut -c1-32) built $(ts)" > "$TREE/BUILT"
  echo "$(ts) BUILT: $(cat "$TREE/BUILT")"
}

micro_run() {   # $1 binary $2 outdir [$3 log]
  rm -rf "$2"; mkdir -p "$2"
  ( cd "$2" && env ${3:+COALESCE_OVERTAKE_LOG=$3} nice -n 19 "$1" --outdir="$2" "$GEM5_DIR/configs/deprecated/example/se.py" --ruby --num-cpus=4 \
      --cpu-type=TimingSimpleCPU --mem-size=4GB --l0i_size=32kB --l0i_assoc=8 --l0d_size=2kB --l0d_assoc=8 --l1d_size=8kB --l1d_assoc=8 \
      --l2_size=256kB --l2_assoc=16 --num-l2caches=1 --num-clusters=1 -c "$MICRO" --options="pp_store 4" < /dev/null > "$2/run.log" 2>&1 )
}

qs() {
  if grep -q '^QO-S HOLDS' "$W/qs/qs.txt" 2>/dev/null; then echo "$(ts) $(cat "$W/qs/qs.txt")"; return 0; fi
  echo "$(ts) QO-S: the micro (pp_store 4) under the live binary and the counter's"
  micro_run "$GEM5_DIR/build/X86/gem5.opt" "$W/qs/old" & local p1=$!
  micro_run "$BIN" "$W/qs/new" "$W/qs/new_overtakes.txt" & local p2=$!
  wait "$p1" "$p2"
  python3 "$W/ovt_check.py" qs "$W/qs/old" "$W/qs/new" "$W/qs/new_overtakes.txt" > "$W/qs/qs.txt" 2>&1
  local rc=$?
  echo "$(ts) $(tail -1 "$W/qs/qs.txt")"
  return $rc
}

launch_one() {   # n name orig mode env
  local n="$1" name="$2" orig="$3" mode="$4" env="$5" out="$OUTROOT/$1_$2"
  mkdir -p "$out"
  echo "$(ts) LAUNCH $n $name: $mode $env"
  ( cd "$HOME" && env OUT="$out" GEM5_BIN="$BIN" COALESCE_OVERTAKE_LOG="$out/overtakes.txt" OCEAN_GRID=514 $env \
      bash "$W/run_gem5_splash.sh" "$mode" ) > "$out/launch.log" 2>&1
  local rc=$?
  sed 's/^/      /' "$out/launch.log"
  return $rc
}

settle() {
  local n name orig short mode env od pid st out line
  while IFS='|' read -r n name orig short mode env; do
    out="$OUTROOT/${n}_$name"; od=$(odir_of "$n" "$name" "$orig")
    [ -f "$out/STARTED" ] && [ -z "$(result "$n" "$name")" ] || continue
    pid=$(gem5_pid "$od")
    if [ -n "$pid" ]; then
      st=$(cat "$out/STARTED")
      if [ $(( $(date +%s) - st )) -gt "$LIMIT_S" ]; then kill "$pid"; echo "$(ts) $n $name: past the limit -- ended"; sleep 5; else continue; fi
    fi
    line=$(python3 "$W/ovt_check.py" qo1 "$B3/$orig" "$od" "$out/overtakes.txt" 2>&1 | tail -1)
    echo "${line#QO1 }" > "$out/RESULT"
    echo "$(ts) $n $name: $line"
    python3 "$W/ovt_check.py" qo2 "$H1_OUT/${n}_$name/RESULT" "$out/overtakes.txt" > "$out/qo2.txt" 2>&1
    python3 "$W/ovt_check.py" report "${n}_$name" "$B3/$orig" "$B3/$short" "$od" "$out/overtakes.txt" "$H1_OUT/${n}_$name/RESULT" > "$out/REPORT" 2>&1
    echo "$(ts) $n $name: $(tail -1 "$out/qo2.txt"); $(tail -1 "$out/REPORT")"
    case "$line" in *COMPLETE-DIFFERENT*) echo "$(ts) COMPLETE-DIFFERENT: the counter changed the simulation -- launching stops"; stop_launching=1 ;; esac
  done < <(entries)
}

summary() {
  local n name orig short mode env r st
  while IFS='|' read -r n name orig short mode env; do
    r=$(result "$n" "$name")
    if [ -z "$r" ]; then
      if [ -n "$(gem5_pid "$(odir_of "$n" "$name" "$orig")")" ]; then
        st=$(cat "$OUTROOT/${n}_$name/STARTED" 2>/dev/null || echo 0); r="running $(( ($(date +%s) - st) / 3600 )) h"
      else r="pending"; fi
    else r="$r | $(tail -1 "$OUTROOT/${n}_$name/REPORT" 2>/dev/null | cut -c1-150)"; fi
    printf '   %s %-14s %s\n' "$n" "$name" "$r"
  done < <(entries)
}

chain() {
  echo $$ > "$PIDF"
  echo "$(ts) CHAIN START (pid $$)"
  build || { echo "$(ts) STOPPED at the build"; rm -f "$PIDF"; exit 1; }
  qs || { echo "$(ts) QO-S FAILED: no run starts (the note)"; rm -f "$PIDF"; exit 1; }
  if alive "$H1_PIDF"; then
    echo "$(ts) WAITING for H1's driver (pid $(cat "$H1_PIDF")) to end"
    while alive "$H1_PIDF"; do sleep "$POLL_S"; done
    echo "$(ts) H1's driver has ended"
  fi
  stop_launching=0
  local n name orig short mode env od pid waited q why
  local -a todo
  mapfile -t todo < <(entries)
  for line in "${todo[@]}"; do
    IFS='|' read -r n name orig short mode env <<< "$line"
    [ -z "$(result "$n" "$name")" ] || { echo "$(ts) SKIP $n $name: $(result "$n" "$name")"; continue; }
    while :; do
      local running=0 l2
      for l2 in "${todo[@]}"; do IFS='|' read -r a b c _ <<< "$l2"; [ -n "$(gem5_pid "$(odir_of "$a" "$b" "$c")")" ] && running=$((running + 1)); done
      settle
      [ "$stop_launching" = 0 ] || break
      [ "$running" -lt "$PAR" ] && break
      sleep "$POLL_S"
    done
    if [ "$stop_launching" != 0 ]; then
      mkdir -p "$OUTROOT/${n}_$name"; echo "NOT RUN (the chain stopped launching)" > "$OUTROOT/${n}_$name/RESULT"; continue
    fi
    od=$(odir_of "$n" "$name" "$orig")
    if [ -n "$(gem5_pid "$od")" ]; then echo "$(ts) $n $name: already running -- left alone"; continue; fi
    rm -f "$OUTROOT/${n}_$name/overtakes.txt"
    if ! launch_one "$n" "$name" "$orig" "$mode" "$env"; then
      echo "LAUNCH-FAILED" > "$OUTROOT/${n}_$name/RESULT"; echo "$(ts) $n $name: LAUNCH FAILED -- launching stops"; stop_launching=1; continue
    fi
    waited=0
    while [ ! -s "$od/config.ini" ] && [ "$waited" -lt "$QO0_WAIT_S" ]; do sleep 10; waited=$((waited + 10)); done
    waited=0
    while [ ! -f "$OUTROOT/${n}_$name/overtakes.txt" ] && [ "$waited" -lt "$LOG_WAIT_S" ]; do sleep 10; waited=$((waited + 10)); done
    python3 "$W/ovt_check.py" qo0 "$B3/$orig" "$od" > "$od/qo0.txt" 2>&1; q=$?
    if [ "$q" = 0 ] && [ -f "$OUTROOT/${n}_$name/overtakes.txt" ]; then
      echo "$(ts) $n $name: $(tail -1 "$od/qo0.txt"); counter log open"
      date +%s > "$OUTROOT/${n}_$name/STARTED"
    else
      if [ "$q" = 0 ]; then why="no counter log after $LOG_WAIT_S s (the variable did not reach gem5)"; else why=$(tail -1 "$od/qo0.txt"); fi
      sed 's/^/      /' "$od/qo0.txt"
      pid=$(gem5_pid "$od"); [ -z "$pid" ] || kill "$pid"
      echo "VOID ($why)" > "$OUTROOT/${n}_$name/RESULT"
      echo "$(ts) $n $name: VOID -- run ended, launching stops"; stop_launching=1
    fi
  done
  echo "$(ts) ALL LAUNCHED OR SKIPPED; waiting for the runs"
  while :; do
    settle
    local open=0
    for line in "${todo[@]}"; do IFS='|' read -r n name _ <<< "$line"; [ -n "$(result "$n" "$name")" ] || open=$((open + 1)); done
    [ "$open" = 0 ] && break
    sleep "$POLL_S"
  done
  echo "$(ts) CHAIN END"; summary
  rm -f "$PIDF"
}

case "$MODE" in
  guards) echo "== H1b guards"; guards ;;
  list) while IFS='|' read -r n name orig short mode env; do printf '%s %-14s %s | short %s | %s %s\n' "$n" "$name" "$B3/$orig" "$short" "$mode" "$env"; done < <(entries) ;;
  chain)
    mkdir -p "$W" "$OUTROOT"
    alive "$PIDF" && die "the H1b driver is running (pid $(cat "$PIDF")) -- 'status'"
    echo "== guards"; guards || die "a guard failed (above) -- nothing started"
    n0=0; [ -f "$DLOG" ] && n0=$(wc -l < "$DLOG")
    setsid nohup bash "$0" __chain >> "$DLOG" 2>&1 < /dev/null &
    sleep 3
    alive "$PIDF" || tail -n +$((n0 + 1)) "$DLOG" | grep -q 'CHAIN START' || die "the driver did not start; see $DLOG"
    echo "driver started; log $DLOG" ;;
  __chain) chain ;;
  status)
    echo "== H1b (overtake counter): driver $(alive "$PIDF" && echo "alive (pid $(cat "$PIDF"))" || echo "not running"); build $( [ -f "$TREE/BUILT" ] && cat "$TREE/BUILT" || echo 'not yet')"
    [ -f "$W/build.log" ] && [ ! -f "$TREE/BUILT" ] && echo "   build: $(grep -c '\[ *CXX\]' "$W/build.log") compiled so far; $(tail -1 "$W/build.log" | cut -c1-120)"
    [ -f "$W/qs/qs.txt" ] && echo "   $(tail -1 "$W/qs/qs.txt")"
    summary; tail -4 "$DLOG" 2>/dev/null | sed 's/^/   /' ;;
  stop)
    if alive "$PIDF"; then kill -- "-$(cat "$PIDF")" 2>/dev/null || kill "$(cat "$PIDF")"; rm -f "$PIDF"; echo "driver (and its build) stopped"; else echo "no driver running"; fi
    if [ "${2:-}" = runs ]; then
      pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$OUTROOT/" | while read -r p; do kill "$p" && echo "ended gem5 pid $p"; done
    fi ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
