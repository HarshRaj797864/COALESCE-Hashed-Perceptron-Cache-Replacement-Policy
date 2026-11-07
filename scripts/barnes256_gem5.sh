#!/usr/bin/env bash
# gem5 on the program the barnes_4t traces hold: BARNES with 256-body leaves.
# Detached, one step at a time, stopping at the first failure. Pre-registered
# in bench/policy_sanity/b3_barnes256_design_2026-10-12.md.
#
#   bash ~/barnes256_gem5.sh go        # (scripts/barnes256_all.sh does this)
#   bash ~/barnes256_gem5.sh status
#   bash ~/barnes256_gem5.sh probe     # steps 1-3 only: build and compare, launch nothing
#
# WHY. The barnes_4t traces came from a BARNES built on 2026-06-12 with
# MAX_BODIES_PER_LEAF 256; SPLASH-3's source, and the static binary gem5 ran,
# use 10 (b3_barnes_stream_2026-10-12.md). So every barnes comparison so far
# divided one program's rate by another's. This builds a static BARNES with
# that one constant at 256, checks it against the traced binary, and runs
# gem5 on it to the same two stops as before.
#
#   1. traced    the traced binary's loadtree compares a leaf's body count
#                with 0x100 (256), not 0xa (10) -- else STOP: the diagnosis
#                is wrong
#   2. build     a COPY of apps/barnes (the tree is not touched), defs.h.in
#                with the one constant changed, the tree's own flags, static,
#                no stack protector and no fortify (the traced binary has
#                neither)
#   3. compare   static; loadtree compares with 0x100; every force-phase
#                function has the traced binary's instruction count and
#                constants -- else STOP
#   4. native    it runs natively on the traced input (rc 0, or still going
#                at 120 s)
#   5. launch    WL=barnes VARIANT=leaf256 launch_b3_gem5.sh go: LLC 2MB, stop
#                at 50M and at 150M -> ~/gem5_b3/barnes_leaf256/
#
# It does not use bin/champsim or run_phase_a.sh, so it can run beside a
# ChampSim sweep. gem5 runs at nice 19.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
SPLASH="${SPLASH:-$R/simulator/tracer/splash-3/codes}"
TRACED="$SPLASH/apps/barnes/BARNES"
STD_BINS="${STD_BINS:-$HOME/splash-static}"
BINS256="$HOME/splash-static-leaf256"
BUILD="$HOME/barnes_leaf256_build"
W="$HOME/gem5_b3/barnes_leaf256"
LOG="$W/pipeline.log"
PIDF="$W/.pipeline.pid"
# The functions the measured window runs: it lies inside the first force phase.
FORCE="gravsub walksub hackgrav hackwalk subdivp ComputeForces stepsystem"
alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }
step() { echo; echo "=== $(date '+%F %T')  $* ==="; }
fail() { echo "STOPPED: $*"; rm -f "$PIDF"; exit 1; }

# One line per instruction of the application's own functions: "fn<TAB>text".
disasm() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next }
    /^ +[0-9a-f]+:/ { sub(/^ +[0-9a-f]+:[ \t]+/, ""); sub(/[ \t]+#.*$/, ""); print fn "\t" $0 }'
}
# The immediates loadtree compares with: a leaf is full at MAX_BODIES_PER_LEAF.
leaf_cmp() { disasm "$1" | awk -F'\t' '$1 == "loadtree" && $2 ~ /^cmp[a-z]* +\$0x(a|100),/ { match($2, /\$0x[0-9a-f]+/); print substr($2, RSTART + 1, RLENGTH - 1) }' | sort -u | tr '\n' ' '; }
# SubdivideLeaf keeps a leaf's body pointers on its stack: 8 bytes a body.
leaf_frame() { disasm "$1" | awk -F'\t' '$1 == "SubdivideLeaf" && $2 ~ /^sub +\$0x[0-9a-f]+,%rsp/ { match($2, /\$0x[0-9a-f]+/); print substr($2, RSTART + 1, RLENGTH - 1); exit }'; }
# 256 if the binary was built with 256-body leaves, 10 if with the source's
# 10, else "?". The compare is the test; the stack frame decides only when
# the compiler wrote the compare some other way.
leaf_capacity() {
  local c f; c=$(leaf_cmp "$1"); f=$(leaf_frame "$1")
  case "$c" in
    "0x100 ") echo 256 ;;
    "0xa ")   echo 10 ;;
    "")       if [ -n "$f" ] && [ $((f)) -ge $((0x850)) ] && [ $((f)) -le $((0x880)) ]; then echo 256
              elif [ -n "$f" ] && [ $((f)) -ge $((0x90)) ] && [ $((f)) -le $((0xd0)) ]; then echo 10
              else echo '?'; fi ;;
    *)        echo '?' ;;
  esac
}
# "fn count" for every function.
fn_sizes() { disasm "$1" | awk -F'\t' '{ n[$1]++ } END { for (f in n) print f, n[f] }' | LC_ALL=C sort; }
# "fn kind value" for each constant: immediates and structure offsets. Left
# out: rip-relative displacements, stack offsets, branch targets, and values
# of 0x100000 and up (a non-PIE static binary holds absolute addresses).
fn_consts() {
  disasm "$1" | awk -F'\t' '
    { fn = $1; line = $2; split(line, w, " ")
      if (w[1] ~ /^(j|call|nop|data16|cs|endbr)/) next
      gsub(/-?0x[0-9a-f]+\(%rip\)/, "", line)
      while (match(line, /\$0x[0-9a-f]+|-?0x[0-9a-f]+\(%r[a-z0-9]+/)) {
        c = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        if (c ~ /\(%rsp$|\(%rbp$/) continue
        kind = (c ~ /^\$/) ? "imm" : "off"; sub(/\(%r[a-z0-9]+$/, "", c); sub(/^\$/, "", c)
        v = c; sub(/^-/, "", v); if (length(v) > 7) continue
        print fn, kind, c } }' | LC_ALL=C sort -u
}

build_and_compare() {
  local n cf ld base_cf base_ld

  step "1/5 the traced binary"
  [ -x "$TRACED" ] || fail "no traced binary at $TRACED"
  echo "   $TRACED"
  echo "   $(ls -l --time-style=long-iso "$TRACED" | awk '{print $5, $6, $7}')  md5 $(md5sum < "$TRACED" | cut -c1-12)"
  echo "   loadtree compares a leaf's body count with: $(leaf_cmp "$TRACED")(0x100 = 256, 0xa = 10); SubdivideLeaf's stack frame: $(leaf_frame "$TRACED")"
  n=$(leaf_capacity "$TRACED")
  [ "$n" = 256 ] || fail "the traced binary does not read as a 256-body-leaf build (reads as '$n') -- the diagnosis is wrong or incomplete; nothing built"
  echo "   -> the traced binary has 256-body leaves"
  echo "   the static binary gem5 ran: compares with $(leaf_cmp "$STD_BINS/BARNES"), frame $(leaf_frame "$STD_BINS/BARNES") -> $(leaf_capacity "$STD_BINS/BARNES")-body leaves"

  step "2/5 build a 256-body-leaf static BARNES in a copy"
  rm -rf "$BUILD"; mkdir -p "$BUILD/codes/apps" || fail "cannot create $BUILD"
  cp -p "$SPLASH/Makefile.config" "$BUILD/codes/" && cp -rp "$SPLASH/pthread_macros" "$BUILD/codes/" && cp -rp "$SPLASH/apps/barnes" "$BUILD/codes/apps/" \
    || fail "could not copy the barnes source"
  cd "$BUILD/codes/apps/barnes" || fail "no build directory"
  make clean > /dev/null 2>&1
  [ "$(grep -c '^#define MAX_BODIES_PER_LEAF 10$' defs.h.in)" = 1 ] || fail "defs.h.in has no single '#define MAX_BODIES_PER_LEAF 10' line -- the source is not as expected"
  sed -i 's/^#define MAX_BODIES_PER_LEAF 10$/#define MAX_BODIES_PER_LEAF 256/' defs.h.in
  [ "$(grep -c '^#define MAX_BODIES_PER_LEAF 256$' defs.h.in)" = 1 ] || fail "the edit did not take"
  n=$(diff <(sed 's/MAX_BODIES_PER_LEAF 256$/MAX_BODIES_PER_LEAF 10/' defs.h.in) "$SPLASH/apps/barnes/defs.h.in" | grep -c '^[<>]')
  [ "$n" = 0 ] || fail "the copy's defs.h.in differs from the tree's in more than that constant"
  echo "   defs.h.in: MAX_BODIES_PER_LEAF 10 -> 256, nothing else changed"
  base_cf=$(grep -E '^\s*CFLAGS\s*[:+]?=' "$BUILD/codes/Makefile.config" | head -1 | sed 's/^[^=]*=//')
  base_ld=$(grep -E '^\s*LDFLAGS\s*[:+]?=' "$BUILD/codes/Makefile.config" | head -1 | sed 's/^[^=]*=//')
  cf="-static -pthread $base_cf -fno-stack-protector -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
  ld="-static -pthread $base_ld -lm"
  echo "   CFLAGS=\"$cf\""
  make CFLAGS="$cf" LDFLAGS="$ld" > "$BUILD/build.log" 2>&1 || { tail -8 "$BUILD/build.log" | sed 's/^/      /'; fail "the build failed ($BUILD/build.log)"; }
  [ -x BARNES ] || fail "the build produced no BARNES"
  cd "$HOME" || true

  step "3/5 compare it with the traced binary"
  local new="$BUILD/codes/apps/barnes/BARNES" own diffs f a b
  file -b "$new" | grep -c 'statically linked' > /dev/null || fail "the new BARNES is not statically linked"
  echo "   new binary: $(ls -l "$new" | awk '{print $5}') bytes, md5 $(md5sum < "$new" | cut -c1-12), static; loadtree compares with: $(leaf_cmp "$new"); frame $(leaf_frame "$new")"
  [ "$(leaf_capacity "$new")" = 256 ] || fail "the new binary does not read as a 256-body-leaf build"
  own=$(nm --defined-only "$TRACED" 2>/dev/null | awk '$2 ~ /^[Tt]$/ && $3 !~ /^(_|frame_dummy|register_tm_clones|deregister_tm_clones)/ { print $3 }' | LC_ALL=C sort -u)
  [ -n "$own" ] || fail "the traced binary has no symbols to compare by"
  # instruction counts, every own function
  diffs=$(LC_ALL=C join <(fn_sizes "$TRACED") <(fn_sizes "$new") | awk -v ownlist="$own" 'BEGIN { n = split(ownlist, o, "\n"); for (i = 1; i <= n; i++) own[o[i]] = 1 }
      ($1 in own) { c++; if ($2 != $3) printf "      %-18s traced %4d   new %4d\n", $1, $2, $3 }
      END { printf "   %d own functions compared by instruction count\n", c }')
  echo "$diffs" | tail -1
  n=$(echo "$diffs" | grep -c 'traced')
  if [ "$n" -gt 0 ]; then echo "   $n differ:"; echo "$diffs" | grep 'traced'; else echo "   none differs"; fi
  # the force phase must match exactly: count and constants
  for f in $FORCE; do
    a=$(fn_sizes "$TRACED" | awk -v f="$f" '$1 == f { print $2 }'); b=$(fn_sizes "$new" | awk -v f="$f" '$1 == f { print $2 }')
    [ -n "$a" ] && [ -n "$b" ] || { echo "   $f: not a separate function in both (traced '${a:-none}', new '${b:-none}')"; continue; }
    [ "$a" = "$b" ] || fail "$f has $a instructions in the traced binary and $b in the new one -- not the same code"
    n=$(diff <(fn_consts "$TRACED" | awk -v f="$f" '$1 == f') <(fn_consts "$new" | awk -v f="$f" '$1 == f') | grep -c '^[<>]')
    if [ "$n" != 0 ]; then
      diff <(fn_consts "$TRACED" | awk -v f="$f" '$1 == f') <(fn_consts "$new" | awk -v f="$f" '$1 == f') | grep '^[<>]' | head -6 | sed 's/^/      /'
      fail "$f differs from the traced binary in $n constant(s) (< traced, > new)"
    fi
    echo "   $f: $a instructions, same constants"
  done
  echo "   the force-phase functions match the traced binary"
}

pipeline() {
  echo $$ > "$PIDF"
  local in="$W/barnes.in" rc new="$BUILD/codes/apps/barnes/BARNES" t
  for f in "$HOME/run_gem5_splash.sh" "$HOME/launch_b3_gem5.sh"; do [ -f "$f" ] || fail "no $f"; done
  grep -c 'VARIANT' "$HOME/launch_b3_gem5.sh" > /dev/null || fail "~/launch_b3_gem5.sh predates VARIANT -- upload it first"
  [ -x "$STD_BINS/OCEAN" ] || fail "no $STD_BINS/OCEAN (run_gem5_splash.sh's preflight wants it beside BARNES)"
  build_and_compare

  step "4/5 native run on the traced input"
  bash "$HOME/run_gem5_splash.sh" barnes-input "$in" 4 > /dev/null || fail "could not write the barnes input"
  ( cd "$W" && timeout 120 "$new" < "$in" ) > "$W/native_check.log" 2>&1; rc=$?
  grep -v '^\s*$' "$W/native_check.log" | sed -n '1,4p' | sed 's/^/   /'
  [ "$rc" = 0 ] || [ "$rc" = 124 ] || fail "the new BARNES fails natively (rc=$rc; $W/native_check.log)"
  echo "   native ok (rc=$rc)"

  step "5/5 install it and launch gem5"
  mkdir -p "$BINS256" || fail "cannot create $BINS256"
  if [ -e "$BINS256/BARNES" ] && ! cmp -s "$BINS256/BARNES" "$new"; then
    t="$BINS256/BARNES.prev_$(date +%Y%m%d_%H%M%S)"; mv -f "$BINS256/BARNES" "$t" && echo "   kept the previous one as $(basename "$t")"
  fi
  cp -p "$new" "$BINS256/BARNES" && cmp -s "$new" "$BINS256/BARNES" || fail "could not install the new BARNES"
  cp -p "$STD_BINS/OCEAN" "$BINS256/OCEAN" || fail "could not copy OCEAN"
  echo "   $BINS256/BARNES  md5 $(md5sum < "$BINS256/BARNES" | cut -c1-12)"
  WL=barnes VARIANT=leaf256 BINS="$BINS256" bash "$HOME/launch_b3_gem5.sh" go || fail "the gem5 launch failed"
  rm -f "$PIDF"
  echo; echo "=== pipeline done $(date '+%F %T') -- the gem5 launcher continues in the background ==="
}

case "${1:-}" in
  go)
    mkdir -p "$W"
    if alive; then echo "the pipeline is already running (pid $(cat "$PIDF")) -- 'status'"; exit 0; fi
    setsid bash "$0" __pipeline > "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null
    echo "started in the background; log: $LOG"
    echo "check: bash $0 status" ;;
  __pipeline) pipeline ;;
  probe)
    mkdir -p "$W"
    build_and_compare ;;
  status)
    if alive; then echo "(pipeline still working)"; fi
    [ -f "$LOG" ] && sed 's/^/ /' "$LOG" || echo "not started"
    [ -f "$HOME/launch_b3_gem5.sh" ] && { echo; WL=barnes VARIANT=leaf256 bash "$HOME/launch_b3_gem5.sh" status 2>&1 | sed 's/^/ /'; } ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
