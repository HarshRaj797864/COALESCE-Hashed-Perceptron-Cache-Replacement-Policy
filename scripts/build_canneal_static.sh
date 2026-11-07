#!/usr/bin/env bash
# Build a STATIC canneal for gem5 SE mode, from the exact code the canneal
# traces came from, and prove it. Runs on the LAPTOP; the PARSEC tree and the
# 2026-04-25 build live there.
#
#   scripts/build_canneal_static.sh          # -> simulator/bin/CANNEAL.static (gitignored)
#
# The traced binary (simulator/tracer/canneal) is dynamic, which gem5 SE mode
# cannot run reliably. Its DWARF producer names the compiler and flags (GNU
# C++17 11.4.0, -O3 ... -O0 -g -funroll-loops -fprefetch-loop-arrays
# -fpermissive -fno-exceptions), and its comp_dir names the PARSEC build
# directory, which still holds that build's objects. So:
#   1. the build directory's canneal must be byte-identical to the traced one;
#   2. each object rebuilt here with the PARSEC flags must have machine code
#      identical to that build's object (objdump -d, raw bytes included);
#   3. only then are the objects linked with -static. The program code is the
#      traced code; only libc/libstdc++ linkage differs;
#   4. both binaries run natively on the traced arguments, as a sanity check.
#      canneal's result depends on thread interleaving, so the two routing
#      costs are compared to each other and to the trace's, not required to
#      be equal.
set -uo pipefail
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
PB="${PARSEC_CANNEAL:-/home/rajharsh/programming-playground/repos/parsec-benchmark/pkgs/kernels/canneal/obj/amd64-linux.gcc}"
TRACED="$LROOT/simulator/tracer/canneal"
NETS="${CANNEAL_NETS:-$LROOT/simulator/tracer/pin/100000.nets}"
OUT="$LROOT/simulator/bin/CANNEAL.static"
# PARSEC's gcc.bldconf CXXFLAGS, its -DPARSEC_VERSION, the pthreads version's
# -DENABLE_THREADS -pthread, then canneal's own Makefile's -O0 -g.
FL="-O3 -g -funroll-loops -fprefetch-loop-arrays -fpermissive -fno-exceptions -DPARSEC_VERSION=2.2 -DENABLE_THREADS -pthread -O0 -g"
OBJS="annealer_thread rng netlist main netlist_elem"
die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$TRACED" ] || die "no traced binary at $TRACED"
[ -d "$PB" ] || die "no PARSEC canneal build directory at $PB"
[ -f "$NETS" ] || die "no netlist at $NETS"
[ "$(g++ -dumpfullversion)" = 11.4.0 ] || die "g++ is $(g++ -dumpfullversion); the traced build used 11.4.0"

echo "== 1. the build directory's canneal is the traced binary =="
cmp -s "$PB/canneal" "$TRACED" || die "$PB/canneal differs from $TRACED"
echo "   byte-identical"

echo "== 2. rebuilt objects match that build's, machine code and bytes =="
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$PB"/*.cpp "$PB"/*.h "$W"/ && cp -r "$PB"/atomic "$W"/ || die "cannot copy sources"
for f in $OBJS; do
  ( cd "$W" && g++ $FL "$f.cpp" -c -o "$f.o" ) 2>/dev/null || die "compile failed: $f.cpp"
  a=$(objdump -d "$PB/$f.o" | tail -n +4 | md5sum); b=$(objdump -d "$W/$f.o" | tail -n +4 | md5sum)
  [ "$a" = "$b" ] || die "$f.o: machine code differs from the traced build's"
  echo "   $f.o identical"
done

echo "== 3. static link =="
( cd "$W" && g++ $FL -static $(for f in $OBJS; do echo "$f.o"; done) -lm -o canneal ) || die "static link failed"
file -b "$W/canneal" | grep -q 'statically linked' || die "the link is not static: $(file -b "$W/canneal")"
mkdir -p "$(dirname "$OUT")" && cp "$W/canneal" "$OUT" || die "cannot write $OUT"
echo "   $OUT  $(stat -c %s "$OUT") bytes  md5 $(md5sum < "$OUT" | cut -c1-32)"

echo "== 4. native runs, the traced arguments (4 15000 2000 100000.nets 128) =="
for b in "$TRACED" "$OUT"; do
  r=$(cd "$W" && timeout 600 "$b" 4 15000 2000 "$NETS" 128 2>&1 | grep -m1 'Final routing is'); rc=$?
  printf '   %-22s %s\n' "$(basename "$b")" "${r:-<no result, rc=$rc>}"
done
echo "   (the canneal_4t trace's own run printed: Final routing is: 8.05058e+07)"
