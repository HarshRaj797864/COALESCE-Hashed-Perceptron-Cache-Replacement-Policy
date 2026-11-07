#!/usr/bin/env bash
# Read-only audit of the B3 ChampSim runs: is the server running what we think,
# did each run use the traces and lengths we think, and do the rows files say
# what the logs say? Nothing here changes a result.
#
#   scp -P 2222 scripts/verify_b3.sh scripts/count_rmw.py user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/verify_b3.sh' > simulator/results/verify_b3.txt   # seconds; also starts the trace count
#   ssh -n -p 2222 user@your-server 'bash ~/verify_b3.sh rmw'                                 # ~10 min later
#
# (default)
#   1. SOURCE   md5 of the deployed simulator sources and of the binaries, to
#               compare with the laptop's commit
#   2. RUNS     every phaseA_b3_v2_* / _v3_* log: lengths, core count, the
#               trace each CPU ran, aliased fills, whether the binary printed
#               the step-1 counter, the end marker
#   3. RAW      one run's counter lines, both stats blocks, to re-derive its
#               rows by hand (canneal 4c shared, fixed 2 MB, step 1)
#   then starts the trace count below, detached and niced.
# rmw
#   4. RMW      read-modify-write instructions counted straight from the
#               traces (count_rmw.py), records 50M..150M of each thread, to set
#               against the simulator's "RMW LOADS ISSUED AS RFO". The trace
#               count is an upper bound: a load forwarded from an older store
#               is never issued.
set -uo pipefail
R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
OUT="$HOME/verify_b3_rmw"
# The measured window, in records of each thread's trace. Overridable only to
# test this script on small files.
SKIP="${VERIFY_SKIP:-50000000}"; COUNT="${VERIFY_COUNT:-100000000}"

# Is a trace count of ours still running? Match the python process itself: a
# bare 'count_rmw.py' also matches any shell whose command line names the file
# (the scp, or a test of this script -- it did, 2026-10-11).
counting() { pgrep -u "$(id -u)" -f '^python3 [^ ]*count_rmw\.py [0-9]+ [0-9]+' >/dev/null 2>&1; }

traces_of() {   # workload -> the trace files, as run_phase_a.sh picks them
  local f
  case "$1" in
    canneal) for f in 1 2 3 4; do ls "$S/traces/canneal_4t/canneal$f.champsimtrace"* 2>/dev/null | head -1; done ;;
    barnes)  for f in 0 1 2 3; do ls "$S/traces/barnes_4t$f.champsimtrace"* 2>/dev/null | head -1; done ;;
    ocean)   ls "$S/traces/ocean_4t/ocean0.champsimtrace"* 2>/dev/null | head -1 ;;   # one thread: 12 GB each, uncompressed
  esac
}

if [ "${1:-}" = rmw ]; then
  echo "== 4. RMW instructions in the traces, records 50M..150M =="
  if counting; then echo "   (still counting -- run this again in a few minutes)"; fi
  for f in "$OUT"/*.txt; do [ -f "$f" ] && printf '   %-28s %s\n' "$(basename "$f" .txt)" "$(cat "$f")"; done
  exit 0
fi

echo "verify_b3  $(date '+%F %T')"
echo
echo "== 1. SOURCE (md5) =="
( cd "$S" && md5sum src/ooo_cpu.cc src/cache.cc src/sharer_directory.cc src/plain_printer.cc src/core_stats.cc src/vmem.cc src/champsim.cc \
              inc/ooo_cpu.h inc/cache.h inc/core_stats.h inc/sharer_directory.h inc/block.h inc/cache_stats.h scripts/make_config.py 2>&1 | sed 's/^/   /' )
for b in champsim champsim_b3v2_acb76b2; do
  [ -f "$S/bin/$b" ] && printf '   %-28s md5 %s  built %s  step-1 counter: %s  directory: %s\n' "bin/$b" "$(md5sum < "$S/bin/$b" | cut -c1-32)" \
    "$(date -r "$S/bin/$b" '+%F %T')" "$(strings -a "$S/bin/$b" | grep -c 'RMW LOADS ISSUED AS RFO')" "$(strings -a "$S/bin/$b" | grep -c 'COHERENCE DIR RFO PROTOCOL-OTHER')"
done

echo
echo "== 2. RUNS =="
for log in "$S"/results/phaseA_b3_v[23]_*/regime_*/*/*/run.log; do
  [ -f "$log" ] || continue
  rel="${log#"$S"/results/}"
  printf '   %s\n' "${rel%/run.log}"
  printf '      warmup %s  sim %s  cpus %s  ended %s  log written %s\n' \
    "$(awk '/^Warmup Instructions:/ { print $3; exit }' "$log")" "$(awk '/^Simulation Instructions:/ { print $3; exit }' "$log")" \
    "$(awk '/^Number of CPUs:/ { print $4; exit }' "$log")" "$(grep -c 'ChampSim completed all CPUs' "$log")" "$(date -r "$log" '+%F %T')"
  printf '      traces: %s\n' "$(awk '/^CPU [0-9]+ runs / { n = split($4, a, "/"); printf "%s:%s/%s ", $2, a[n-1], a[n] }' "$log")"
  printf '      aliased fills: %s   step-1 counter lines: %s   wrapped: %s\n' \
    "$(awk '/^VMEM ALIASED FILLS/ { print $NF; exit }' "$log")" "$(grep -c 'RMW LOADS ISSUED AS RFO' "$log")" "$(grep -c 'Reached end of trace' "$log")"
done

echo
log="$S/results/phaseA_b3_v3_canneal4/regime_shared/canneal_4core/lru/run.log"
echo "== 3. RAW: ${log#"$S"/results/} =="
if [ -f "$log" ]; then
  grep -E '^Simulation complete CPU' "$log" | sed 's/ (Simulation time.*//; s/^/   /'
  echo "   -- whole-simulation block (first), then Region of Interest block --"
  for blk in first roi; do
    echo "   [$blk]"
    awk -v want="$blk" '
      /^Region of Interest Statistics/ { roi = 1 }
      (want == "roi") == (roi == 1) && (/^cpu[0-9]+->LLC (TOTAL|LOAD|RFO|WRITE|TRANSLATION) / || /^LLC COHERENCE / || /^CPU [0-9]+ RMW LOADS/ || /^CPU [0-9]+ cumulative IPC/) { print "      " $0 }' "$log"
  done
else
  echo "   not found"
fi

echo
echo "== 4. RMW count from the traces: started in the background =="
mkdir -p "$OUT"
if counting; then
  echo "   already running"
elif [ ! -f "$HOME/count_rmw.py" ]; then
  echo "   no ~/count_rmw.py -- upload it with this script"
else
  for wl in canneal barnes ocean; do
    for t in $(traces_of "$wl"); do
      name="$(basename "$(dirname "$t")")_$(basename "$t" | sed 's/\.champsimtrace.*//')"
      [ "$wl" = barnes ] && name="$(basename "$t" | sed 's/\.champsimtrace.*//')"
      case "$t" in *.xz) rd="xz -dc" ;; *) rd="cat" ;; esac
      ( setsid nice -n 19 bash -c "$rd '$t' 2>/dev/null | python3 '$HOME/count_rmw.py' $SKIP $COUNT > '$OUT/$name.txt' 2>&1" < /dev/null > /dev/null 2>&1 & )
      echo "   counting $name"
    done
  done
  echo "   results: bash ~/verify_b3.sh rmw   (about 10 minutes)"
fi
