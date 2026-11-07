#!/usr/bin/env bash
# Step 4, the new benchmarks: a READ-ONLY survey of the server before anything
# is designed (2026-10-19). Writes only under ~/newbench_survey. Prints:
#   1. each candidate SPLASH-3 program: its directory, Makefile target, input
#      files and usage text;
#   2. PARSEC's streamcluster: where its source is, how canneal was built;
#   3. tools to size an input: perf, Pin's instruction counter;
#   4. the new alignment (sync_anchor.py: thread 0's last pthread_create)
#      against the old anchors on the three programs they aligned, on the m2
#      traces. Tolerance set before any number was seen: within 50,000
#      instructions of the old anchor;
#   5. disk.
#
#   bash ~/newbench_survey.sh      (scripts/newbench_all.sh survey does this)
set -uo pipefail
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
SPLASH="${SPLASH:-$S/tracer/splash-3/codes}"
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
W="$HOME/newbench_survey"
mkdir -p "$W"

echo "== 1. SPLASH-3 at $SPLASH"
grep -E '^\s*(CC|CFLAGS|LDFLAGS)\s*[:+]?=' "$SPLASH/Makefile.config" 2>/dev/null | sed 's/^/   Makefile.config: /'
for d in kernels/fft kernels/lu/contiguous_blocks kernels/lu/non_contiguous_blocks kernels/cholesky kernels/radix \
         apps/water-spatial apps/water-nsquared apps/raytrace apps/volrend apps/radiosity apps/barnes apps/fmm apps/ocean/contiguous_partitions; do
  p="$SPLASH/$d"
  if [ ! -d "$p" ]; then echo "   $d: ABSENT"; continue; fi
  echo "-- $d"
  grep -E '^\s*TARGET\s*[:+]?=' "$p/Makefile" 2>/dev/null | head -1 | sed 's/^/   /'
  [ -d "$p/inputs" ] && echo "   inputs: $(ls "$p/inputs" | head -30 | tr '\n' ' ')"
  ls "$p" | grep -v -E '\.(o|C|c|h|H|U)$' | head -20 | tr '\n' ' ' | sed 's/^/   files: /'; echo
  grep -h -i -E -A8 'usage' "$p"/*.C "$p"/*.c "$p"/*.H 2>/dev/null | grep -E 'printf|fprintf|"' | head -14 | sed 's/^/   | /'
done

echo
echo "== 2. PARSEC (streamcluster) and how canneal was built"
for base in "$S/tracer/pin" "$S/tracer" "$HOME"; do
  find "$base" -maxdepth 7 -type d -iname streamcluster 2>/dev/null | head -5 | sed 's/^/   dir: /'
done
for f in $(find "$S/tracer/pin" "$HOME" -maxdepth 8 -type f -iname 'streamcluster*' 2>/dev/null | head -12); do
  echo "   file: $f ($(file -b "$f" | cut -c1-60))"
done
ls -la "$S/tracer/pin/canneal" 2>/dev/null | sed 's/^/   canneal binary: /'
file -b "$S/tracer/pin/canneal" 2>/dev/null | cut -c1-90 | sed 's/^/   /'
ls -d "$S"/tracer/pin/parsec* "$HOME"/parsec* 2>/dev/null | sed 's/^/   parsec tree: /'
ls "$HOME"/splash-static "$HOME"/splash-heldout 2>/dev/null | tr '\n' ' ' | sed 's/^/   static binaries for gem5: /'; echo

echo
echo "== 3. tools to size an input"
if command -v perf > /dev/null 2>&1; then
  perf stat -e instructions:u -x, true 2>&1 | tail -1 | sed 's/^/   perf: /'
else
  echo "   perf: not installed"
fi
ls "$PIN_ROOT"/source/tools/ManualExamples/obj-intel64/inscount*.so 2>/dev/null | sed 's/^/   Pin counter built: /' || true
[ -f "$PIN_ROOT/source/tools/ManualExamples/inscount_tls.cpp" ] && echo "   Pin counter source: inscount_tls.cpp (per thread)"

echo
echo "== 4. the new alignment against the old anchors (m2 traces; tolerance 50,000 instructions)"
for pa in barnesstd:10570006 waternsq:12952793 fmm:12773531; do
  p=${pa%%:*}; old=${pa#*:}; d="$S/traces/sync_mx/$p"
  if [ ! -f "$d/raw0.champsimtrace.xz" ]; then echo "   $p: no m2 traces yet"; continue; fi
  out=$(python3 "$HOME/sync_anchor.py" "$d/raw0.champsimtrace.xz" "$d/raw1.champsimtrace.xz" "$d/raw2.champsimtrace.xz" "$d/raw3.champsimtrace.xz" 2>&1)
  cut=$(echo "$out" | awk '$1 == "CUT" { print $2 }')
  if [ -z "$cut" ]; then echo "   $p: FAILED -- $out"; continue; fi
  diff=$((cut - old)); ad=${diff#-}
  echo "   $p: last pthread_create at $cut instructions; old anchor $old; difference $diff -- $([ "$ad" -le 50000 ] && echo within || echo OUTSIDE) the tolerance"
done

echo
echo "== 5. disk: $(df -h "$HOME" | tail -1 | awk '{print $4}') free"
