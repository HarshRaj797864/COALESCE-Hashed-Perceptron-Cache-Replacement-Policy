#!/usr/bin/env bash
# gem5 on coherence_micro (bench/policy_sanity/micro_design_2026-10-17.md):
# a program whose coherence counts are known by hand. Writes only under ~/micro.
#
#   bash ~/micro_server.sh go       # build the static binary (with gem5 stat markers), start 11 gem5 runs, detached
#   bash ~/micro_server.sh status   # which have finished
#
# Each run: MESI_Three_Level, 4 CPUs, TimingSimpleCPU, the small hierarchy the
# program is written for (L0 data 2 KB x 8, L0 inst 32 KB x 8, private L1
# 8 KB x 8, shared L2 256 KB x 16, one bank). The binary resets the stats at
# thread 0's start mark and dumps them at its end mark (m5ops), so stats.txt's
# FIRST block is the measured window.
set -uo pipefail
W="${W:-$HOME/micro}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
BUILD="X86"; [ -f "$GEM5_DIR/.gem5_build_dir" ] && BUILD="$(cat "$GEM5_DIR/.gem5_build_dir")"
GEM5="$GEM5_DIR/build/$BUILD/gem5.opt"
SE="$GEM5_DIR/configs/deprecated/example/se.py"
CASES="${CASES:-pp_lock pp_store pp_rmw readers upgrade ctl priv_E priv_S llc_out offchip}"
ROUNDS="${ROUNDS:-4}"
mkdir -p "$W/gem5"

die() { echo "STOPPED: $*"; exit 1; }

go() {
  [ -x "$GEM5" ] || die "no gem5 at $GEM5"
  [ "$(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null)" = MESI_Three_Level ] || die "gem5 is not the MESI_Three_Level build"
  [ -f "$W/coherence_micro.c" ] || die "no $W/coherence_micro.c -- upload it"
  gcc -O2 -static -pthread -DM5OPS -o "$W/micro_m5" "$W/coherence_micro.c" || die "the static build failed"
  gcc -O2 -pthread -o "$W/micro_native" "$W/coherence_micro.c" || die "the native build failed"
  for c in $CASES; do timeout 60 "$W/micro_native" "$c" "$ROUNDS" > /dev/null || die "$c fails natively"; done
  echo "built: $W/micro_m5 (md5 $(md5sum < "$W/micro_m5" | cut -c1-32)); every case runs natively"
  # How gem5's sequencer hands an x86 read-modify-write's load to the protocol
  # (micro_design_2026-10-17.md, M3): read the source, do not recall it.
  local seq="$GEM5_DIR/src/mem/ruby/system/Sequencer.cc"
  echo "== $seq, the request types (StoreCheck / RMW_Read / Locked_RMW):"
  grep -n -E "StoreCheck|RMW_Read|Locked_RMW|secondary_type = |primary_type = " "$seq" 2>/dev/null | head -40 | sed 's/^/   /'
  echo "== issueRequest: which type the protocol sees"
  awk '/::issueRequest/,/^}/' "$seq" 2>/dev/null | grep -n -E "type|RubyRequest" | head -12 | sed 's/^/   /'
  local c r odir
  for c in control $CASES; do
    if [ "$c" = control ]; then r=0; cc=pp_lock; else r=$ROUNDS; cc=$c; fi
    odir="$W/gem5/${c}_r$r"
    if [ -f "$odir/stats.txt" ] && grep -q "Exiting @ tick" "$odir/run.log" 2>/dev/null; then echo "   $c: done already"; continue; fi
    if pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=$odir " > /dev/null; then echo "   $c: running"; continue; fi
    rm -rf "$odir"; mkdir -p "$odir"
    ( cd "$odir" || exit 1; setsid nice -n 19 "$GEM5" --outdir="$odir" "$SE" --ruby --num-cpus=4 --cpu-type=TimingSimpleCPU --mem-size=4GB \
        --l0i_size=32kB --l0i_assoc=8 --l0d_size=2kB --l0d_assoc=8 --l1d_size=8kB --l1d_assoc=8 \
        --l2_size=256kB --l2_assoc=16 --num-l2caches=1 --num-clusters=1 \
        -c "$W/micro_m5" --options="$cc $r" < /dev/null > "$odir/run.log" 2>&1 & )
    echo "   $c: started ($cc, $r rounds) -> $odir"
  done
}

status() {
  local d n=0 done=0
  for d in "$W"/gem5/*/; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    if grep -q "Exiting @ tick" "$d/run.log" 2>/dev/null; then
      done=$((done + 1)); printf '   %-16s done, %s stats dump(s)\n' "$(basename "$d")" "$(grep -c 'Begin Simulation Statistics' "$d/stats.txt" 2>/dev/null)"
    elif pgrep -u "$(id -u)" -f "[g]em5.opt --outdir=${d%/} " > /dev/null; then printf '   %-16s running\n' "$(basename "$d")"
    else printf '   %-16s STOPPED: %s\n' "$(basename "$d")" "$(tail -1 "$d/run.log" 2>/dev/null)"; fi
  done
  echo "micro: $done of $n gem5 runs done"
}

case "${1:-}" in
  go) go ;;
  status) status ;;
  *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
