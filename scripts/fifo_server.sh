#!/usr/bin/env bash
# H1 (bench/policy_sanity/fifo_check_design_2026-11-14.md), server side: the
# 13 scored gem5 configurations rerun to their longest stop with gem5's stock
# (ordered) L0<->L1 buffers. Everything lives in ~/gem5_fifo (a copy of
# gem5's configs/ with the stock MESI_Three_Level.py, a copy of
# run_gem5_splash.sh, fifo_check.py) and ~/gem5_b3/fifo (the runs). The live
# ~/gem5/configs, ~/run_gem5_splash.sh and the gem5 binary are not touched.
#
#   bash ~/gem5_fifo/fifo_server.sh guards        # read-only checks
#   bash ~/gem5_fifo/fifo_server.sh list          # the 13, their originals, their state
#   bash ~/gem5_fifo/fifo_server.sh chain         # (owner's word) prepare, guards, start the driver detached
#   bash ~/gem5_fifo/fifo_server.sh status
#   bash ~/gem5_fifo/fifo_server.sh stop [runs]   # the driver; with 'runs', H1's gem5 runs too
set -uo pipefail
W="${W:-$HOME/gem5_fifo}"
OUTROOT="${OUTROOT:-$HOME/gem5_b3/fifo}"
B3="${B3:-$HOME/gem5_b3}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
GEM5_TAG="${GEM5_TAG:-v25.1.0.1}"
PAR="${PAR:-4}"                       # runs at once
LIMIT_S="${LIMIT_S:-$((96 * 3600))}"  # a run past this is ended and reported OTHER
QF0_WAIT_S="${QF0_WAIT_S:-900}"       # config.ini must appear within this
POLL_S="${POLL_S:-300}"
PIDF="$W/.driver.pid"
DLOG="$W/driver.log"
MODE="${1:-}"
die() { echo "ERROR: $*" >&2; exit 1; }
ts() { date '+%F %T'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# n|name|original (under $B3)|short stop (under $B3)|run_gem5_splash.sh mode|settings
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
ONLY="${ONLY:-}"   # e.g. ONLY="01 06": only those entries (rehearsal, reruns)

entries() { echo "$ENTRIES" | sed "s|@HOME@|$HOME|g" | while IFS='|' read -r n rest; do
  [ -z "$ONLY" ] || [[ " $ONLY " == *" $n "* ]] || continue; echo "$n|$rest"; done; }
odir_of() { echo "$OUTROOT/$1_$2/$(basename "$3")"; }      # n name original
gem5_pid() { pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$1 " 2>/dev/null | head -1; }

prepare() {
  mkdir -p "$W" "$OUTROOT" || die "mkdir"
  local f="$W/configs/ruby/MESI_Three_Level.py"
  if [ ! -d "$W/configs" ]; then
    rm -rf "$W/configs.tmp"
    cp -a "$GEM5_DIR/configs" "$W/configs.tmp" || die "could not copy $GEM5_DIR/configs"
    cp -p "$GEM5_DIR/configs/ruby/MESI_Three_Level.py.orig_fifo" "$W/configs.tmp/ruby/MESI_Three_Level.py" || die "no .orig_fifo to restore"
    rm -f "$W/configs.tmp/ruby/MESI_Three_Level.py.orig_fifo"
    find "$W/configs.tmp" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
    mv "$W/configs.tmp" "$W/configs" || die "mv configs"
    echo "   prepared $W/configs (stock MESI_Three_Level.py restored)"
  fi
  [ -f "$f" ] || die "no $f"
}

guards() {   # every check; non-zero on the first failure
  local bad=0 n name orig short mode env f t g
  ok() { echo "   ok   $*"; }
  no() { echo "   FAIL $*"; bad=1; }
  [ "$(git -C "$GEM5_DIR" describe --tags 2>/dev/null)" = "$GEM5_TAG" ] && ok "gem5 at $GEM5_TAG" || no "gem5 is not at $GEM5_TAG"
  t=$(git -C "$GEM5_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort | tr '\n' ';')
  [ "$t" = " M configs/ruby/MESI_Three_Level.py;?? .gem5_protocol;?? configs/ruby/MESI_Three_Level.py.orig_fifo;" ] \
    && ok "the live gem5 tree differs from $GEM5_TAG only by the FIFO patch" || no "the live gem5 tree has other changes: $t"
  f="$W/configs/ruby/MESI_Three_Level.py"
  g=$(git -C "$GEM5_DIR" show HEAD:configs/ruby/MESI_Three_Level.py 2>/dev/null | md5sum | cut -c1-32)
  [ -f "$f" ] && [ "$(md5sum < "$f" | cut -c1-32)" = "$g" ] && ok "H1's MESI_Three_Level.py is gem5's stock file (md5 ${g:0:8})" || no "H1's MESI_Three_Level.py is not the stock file"
  [ "$(grep -cE '^[[:space:]]*l0_cntrl\.buffer(ToL1|FromL1) = MessageBuffer\(ordered=True\)$' "$f" 2>/dev/null)" = 2 ] \
    && [ "$(grep -c 'COALESCE: setup_gem5.sh patch-fifo' "$f" 2>/dev/null)" = 0 ] && ok "both L0<->L1 buffers ordered in the copy" || no "the copy's buffers are not both ordered"
  t=$(diff -rq -x __pycache__ -x MESI_Three_Level.py -x MESI_Three_Level.py.orig_fifo "$GEM5_DIR/configs" "$W/configs" 2>&1 | head -3)
  [ -z "$t" ] && ok "the rest of the copy equals the live configs/" || no "the copy differs elsewhere: $t"
  [ "$(grep -c 'COALESCE: setup_gem5.sh patch-fifo' "$GEM5_DIR/configs/ruby/MESI_Three_Level.py")" = 2 ] && ok "the live config is still patched (untouched)" || no "the live config is not as it was"
  grep -q '^GEM5_CONFIGS=' "$W/run_gem5_splash.sh" 2>/dev/null && grep -q 'FIFO_STRICT' "$W/run_gem5_splash.sh" \
    && bash -n "$W/run_gem5_splash.sh" && ok "H1's run_gem5_splash.sh copy has GEM5_CONFIGS and FIFO_STRICT" || no "no usable $W/run_gem5_splash.sh"
  python3 -m py_compile "$W/fifo_check.py" 2>/dev/null && ok "fifo_check.py compiles" || no "no usable $W/fifo_check.py"
  local bin; bin="$GEM5_DIR/build/$(cat "$GEM5_DIR/.gem5_build_dir" 2>/dev/null || echo X86)/gem5.opt"
  [ -x "$bin" ] && ok "gem5 binary $(stat -c '%y' "$bin" | cut -c1-16)" || no "no gem5 binary"
  while IFS='|' read -r n name orig short mode env; do
    [ -n "$n" ] || continue
    if [ -f "$B3/$orig/config.ini" ] && [ -f "$B3/$orig/stats.txt" ] && grep -q 'because a thread reached the max instruction count' "$B3/$orig/run.log" 2>/dev/null \
       && grep -q '^finalTick' "$B3/$short/stats.txt" 2>/dev/null && [ "$bin" -ot "$B3/$orig/config.ini" ]; then
      ok "$n $name: original and short stop ended normally, after the binary was built"
    else
      no "$n $name: original $orig or short stop $short incomplete (or older than the binary)"
    fi
  done < <(entries)
  alive "$PIDF" && no "an H1 driver is running (pid $(cat "$PIDF"))" || ok "no H1 driver running"
  t=$(df -Pk "$HOME" | awk 'NR == 2 { print int($4 / 1048576) }')
  [ "${t:-0}" -ge 5 ] && ok "disk ${t} GB free" || no "disk ${t} GB free (< 5)"
  return $bad
}

result() { cat "$OUTROOT/$1_$2/RESULT" 2>/dev/null; }

launch_one() {   # n name orig mode env -> 0 launched, 1 failed
  local n="$1" name="$2" orig="$3" mode="$4" env="$5" out="$OUTROOT/$1_$2"
  mkdir -p "$out"
  echo "$(ts) LAUNCH $n $name: $mode $env"
  ( cd "$HOME" && env OUT="$out" GEM5_CONFIGS="$W/configs" FIFO_STRICT=1 OCEAN_GRID=514 $env \
      bash "$W/run_gem5_splash.sh" "$mode" ) > "$out/launch.log" 2>&1
  local rc=$?
  sed 's/^/      /' "$out/launch.log"
  return $rc
}

chain() {
  echo $$ > "$PIDF"
  echo "$(ts) CHAIN START (pid $$; $PAR at a time; limit ${LIMIT_S}s)"
  local stop_launching=0 n name orig short mode env od pid waited
  local -a todo
  mapfile -t todo < <(entries)
  for line in "${todo[@]}"; do
    IFS='|' read -r n name orig short mode env <<< "$line"
    [ -z "$(result "$n" "$name")" ] || { echo "$(ts) SKIP $n $name: $(result "$n" "$name")"; continue; }
    if [ "$stop_launching" != 0 ]; then
      mkdir -p "$OUTROOT/${n}_$name"; echo "NOT RUN (the chain stopped launching)" > "$OUTROOT/${n}_$name/RESULT"; continue
    fi
    while :; do   # a slot: count the live runs FIRST, then classify -- every run counted as ended is classified before anything launches
      local running=0 l2
      for l2 in "${todo[@]}"; do IFS='|' read -r a b c _ <<< "$l2"; [ -n "$(gem5_pid "$(odir_of "$a" "$b" "$c")")" ] && running=$((running + 1)); done
      settle
      [ "$stop_launching" = 0 ] || break
      [ "$running" -lt "$PAR" ] && break
      sleep "$POLL_S"
    done
    if [ "$stop_launching" != 0 ]; then   # settle may have stopped launching while this one waited
      mkdir -p "$OUTROOT/${n}_$name"; echo "NOT RUN (the chain stopped launching)" > "$OUTROOT/${n}_$name/RESULT"; continue
    fi
    od=$(odir_of "$n" "$name" "$orig")
    if [ -n "$(gem5_pid "$od")" ]; then echo "$(ts) $n $name: already running -- left alone"; continue; fi
    if ! launch_one "$n" "$name" "$orig" "$mode" "$env"; then
      echo "LAUNCH-FAILED" > "$OUTROOT/${n}_$name/RESULT"; echo "$(ts) $n $name: LAUNCH FAILED -- launching stops"; stop_launching=1; continue
    fi
    waited=0
    while [ ! -s "$od/config.ini" ] && [ "$waited" -lt "$QF0_WAIT_S" ]; do sleep 10; waited=$((waited + 10)); done
    sleep 5
    if python3 "$W/fifo_check.py" qf0 "$B3/$orig" "$od" > "$od/qf0.txt" 2>&1; then
      echo "$(ts) $n $name: $(tail -1 "$od/qf0.txt")"
      date +%s > "$OUTROOT/${n}_$name/STARTED"
    else
      sed 's/^/      /' "$od/qf0.txt"
      pid=$(gem5_pid "$od"); [ -z "$pid" ] || kill "$pid"
      echo "VOID (QF0 failed: $(tail -1 "$od/qf0.txt"))" > "$OUTROOT/${n}_$name/RESULT"
      echo "$(ts) $n $name: QF0 FAILED -- run ended, launching stops"; stop_launching=1
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

settle() {   # classify every started run whose gem5 has ended; end runs past the limit
  local n name orig short mode env od pid st out out_line
  while IFS='|' read -r n name orig short mode env; do
    out="$OUTROOT/${n}_$name"; od=$(odir_of "$n" "$name" "$orig")
    [ -f "$out/STARTED" ] && [ -z "$(result "$n" "$name")" ] || continue
    pid=$(gem5_pid "$od")
    if [ -n "$pid" ]; then
      st=$(cat "$out/STARTED")
      if [ $(( $(date +%s) - st )) -gt "$LIMIT_S" ]; then kill "$pid"; echo "$(ts) $n $name: past the limit -- ended"; sleep 5; else continue; fi
    fi
    out_line=$(python3 "$W/fifo_check.py" qf1 "$B3/$orig" "$od" "$B3/$short" 1 2>&1 | tail -1)
    echo "${out_line#QF1 }" > "$out/RESULT"
    echo "$(ts) $n $name: ${out_line#QF1 }"
    case "$out_line" in *COMPLETE-DIFFERENT*) echo "$(ts) COMPLETE-DIFFERENT contradicts the code reading -- launching stops"; stop_launching=1 ;; esac
  done < <(entries)
}

summary() {
  local n name orig short mode env r
  while IFS='|' read -r n name orig short mode env; do
    r=$(result "$n" "$name")
    if [ -z "$r" ]; then
      if [ -n "$(gem5_pid "$(odir_of "$n" "$name" "$orig")")" ]; then
        st=$(cat "$OUTROOT/${n}_$name/STARTED" 2>/dev/null || echo 0); r="running $(( ($(date +%s) - st) / 3600 )) h"
      else r="pending"; fi
    fi
    printf '   %s %-14s %s\n' "$n" "$name" "$r"
  done < <(entries)
}

case "$MODE" in
  guards) echo "== H1 guards"; guards ;;
  list) while IFS='|' read -r n name orig short mode env; do printf '%s %-14s %s | short %s | %s %s\n' "$n" "$name" "$B3/$orig" "$short" "$mode" "$env"; done < <(entries) ;;
  chain)
    alive "$PIDF" && die "the H1 driver is running (pid $(cat "$PIDF")) -- 'status'"
    echo "== prepare"; prepare
    echo "== guards"; guards || die "a guard failed (above) -- nothing started"
    ends=$(grep -c 'CHAIN END' "$DLOG" 2>/dev/null); ends=${ends:-0}
    setsid nohup bash "$0" __chain >> "$DLOG" 2>&1 < /dev/null &
    sleep 2
    if alive "$PIDF"; then echo "driver started (pid $(cat "$PIDF")); log $DLOG"
    elif [ "$(grep -c 'CHAIN END' "$DLOG" 2>/dev/null)" -gt "$ends" ]; then echo "driver ran and ended at once (nothing left to run); log $DLOG"; summary
    else die "the driver did not start; see $DLOG"; fi ;;
  __chain) chain ;;
  status)
    echo "== H1 (FIFO check): driver $(alive "$PIDF" && echo "alive (pid $(cat "$PIDF"))" || echo "not running")"
    summary; tail -4 "$DLOG" 2>/dev/null | sed 's/^/   /' ;;
  stop)
    if alive "$PIDF"; then kill "$(cat "$PIDF")"; rm -f "$PIDF"; echo "driver stopped"; else echo "no driver running"; fi
    if [ "${2:-}" = runs ]; then
      pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$OUTROOT/" | while read -r p; do kill "$p" && echo "ended gem5 pid $p"; done
    fi ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
