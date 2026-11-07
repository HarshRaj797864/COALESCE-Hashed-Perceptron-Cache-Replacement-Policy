#!/usr/bin/env bash
# Are the BARNES that was traced and the BARNES gem5 ran the same program?
# Read-only: it changes nothing and starts nothing.
#
#   scp -P 2222 scripts/check_barnes_build.sh user@your-server:~/ && ssh -n -p 2222 user@your-server 'bash ~/check_barnes_build.sh'
#
# WHY (2026-10-12). Per 1,000 instructions in the 50-150 M window, the barnes
# traces hold 26.8 read-modify-write instructions, 10.5 of them a pthread
# mutex's lock word; gem5's barnes run executed 10.6, 1.7 of them locked
# (its Sequencer's RMW_Read and Locked_RMW_Read counts). canneal agrees to
# 0.1% on the same measure (11.67 against 11.66). SPLASH-3 barnes takes a
# mutex on every body-body interaction unless it is compiled with
# -DWITH_NO_OPTIONAL_LOCKS, so the two binaries look like different builds.
# This prints what each binary contains.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
SPLASH="${SPLASH:-$R/simulator/tracer/splash-3/codes}"
TRACED="$SPLASH/apps/barnes/BARNES"
STATIC="${STATIC:-$HOME/splash-static/BARNES}"

# Calls to pthread_mutex_lock, by the function that makes them, for barnes's
# own functions only (a static binary also carries glibc's).
OWN='gravsub|walksub|hackgrav|hackwalk|stepsystem|ComputeForces|loadtree|hackcofm|maketree|SlaveStart|find_my_bodies|Housekeep|diagnostics|output|main'
lock_calls() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk -v own="^($OWN)$" '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn) }
    /call/ && /pthread_mutex_lock/ { if (fn ~ own) n[fn]++ ; t++ }
    END { for (f in n) printf "      %-16s %d\n", f, n[f]; printf "      (every function in the file: %d)\n", t + 0 }' | sort
}

echo "== the two binaries =="
shopt -s nullglob
for b in "$TRACED" "$STATIC" "$STATIC".prev_*; do
  [ -e "$b" ] || { echo "   MISSING: $b"; continue; }
  echo "   $b"
  echo "      $(ls -l --time-style=long-iso "$b" | awk '{print $5, $6, $7}')  md5 $(md5sum < "$b" | cut -c1-12)  $(file -b "$b" | grep -oE 'statically linked|dynamically linked')"
  echo "      calls to pthread_mutex_lock, by barnes function:"
  lock_calls "$b"
done

# The constants in each of the application's own functions, traced binary
# against static: immediates and structure offsets, as sets. A changed #define
# changes these and leaves the number of instructions alone. (2026-10-12: the
# traced BARNES was built with MAX_BODIES_PER_LEAF 256, the static one with
# 10, and every function had the same instruction count.) Addresses are left
# out: rip-relative displacements, branch targets, and immediates of 0x400000
# and above (a non-PIE static binary holds absolute addresses).
fn_consts() {
  objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '
    /^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next }
    /^ +[0-9a-f]+:/ {
      sub(/^ +[0-9a-f]+:[ \t]+/, ""); sub(/[ \t]+#.*$/, "")
      if ($1 ~ /^(j|call|nop|data16|cs|lea$|endbr)/ && $1 != "lea") next
      gsub(/-?0x[0-9a-f]+\(%rip\)/, "")
      line = $0
      while (match(line, /\$0x[0-9a-f]+|-?0x[0-9a-f]+\(%r[a-z0-9]+/)) {
        c = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        sub(/\(%r[a-z0-9]+$/, "", c); kind = (c ~ /^\$/) ? "imm" : "off"; sub(/^\$/, "", c)
        if (c ~ /\(%rsp|\(%rbp/) continue
        v = c; sub(/^-/, "", v); if (length(v) > 7) continue          # 0x100000 and up
        print fn "\t" kind " " c
      } }' | LC_ALL=C sort -u
}
same_code() {   # $1 label  $2 traced  $3 static
  [ -e "$2" ] && [ -e "$3" ] || { echo "   $1: a binary is missing"; return 0; }
  echo "   $1: traced $(ls -l --time-style=long-iso "$2" | awk '{print $6}') md5 $(md5sum < "$2" | cut -c1-12)   static $(ls -l --time-style=long-iso "$3" | awk '{print $6}') md5 $(md5sum < "$3" | cut -c1-12)"
  local own; own=$(nm --defined-only "$2" 2>/dev/null | awk '$2 ~ /^[Tt]$/ && $3 !~ /^(_|frame_dummy|register_tm_clones|deregister_tm_clones)/ { print $3 }' | LC_ALL=C sort -u)
  [ -n "$own" ] || { echo "      no symbols in $2 (stripped?)"; return 0; }
  awk -F'\t' -v ownlist="$own" '
    BEGIN { n = split(ownlist, o, "\n"); for (i = 1; i <= n; i++) own[o[i]] = 1 }
    !($1 in own) { next }
    FNR == NR { a[$1 SUBSEP $2] = 1; fa[$1] = 1; next }
    { b[$1 SUBSEP $2] = 1; fb[$1] = 1 }
    END {
      for (k in a) if (!(k in b)) { split(k, q, SUBSEP); oa[q[1]] = oa[q[1]] " " q[2] ";" }
      for (k in b) if (!(k in a)) { split(k, q, SUBSEP); ob[q[1]] = ob[q[1]] " " q[2] ";" }
      for (f in fa) if (f in fb) { nf++; if (oa[f] != "" || ob[f] != "") { nd++; printf "      %-16s only in traced:%s   only in static:%s\n", f, substr(oa[f], 1, 90), substr(ob[f], 1, 90) } }
      printf "      = %d of its own functions compared; %d differ in a constant\n", nf, nd
    }' <(fn_consts "$2") <(fn_consts "$3") | LC_ALL=C sort
}
# barnes's leaf size, read directly: SubdivideLeaf keeps a copy of a leaf's
# body pointers on its stack, MAX_BODIES_PER_LEAF of them.
leaf_probe() {
  local fr; fr=$(objdump -d --no-show-raw-insn "$1" 2>/dev/null | awk '/^[0-9a-f]+ <SubdivideLeaf>:$/ { f = 1; next } f && /^$/ { exit } f && /sub +\$0x[0-9a-f]+,%rsp/ { match($0, /\$0x[0-9a-f]+/); print substr($0, RSTART + 1, RLENGTH - 1); exit }')
  [ -n "$fr" ] && echo "      SubdivideLeaf's stack frame: $fr = $((fr)) bytes  (it holds 8 bytes for each body a leaf can take: 10 -> about 0xb8, 256 -> about 0x868)" || echo "      SubdivideLeaf: no stack frame found"
}
echo
echo "== is the compiled code the same? (the constants in each function, traced against static) =="
same_code BARNES "$TRACED" "$STATIC"
echo "      traced:"; leaf_probe "$TRACED"
echo "      static:"; leaf_probe "$STATIC"
same_code OCEAN "$SPLASH/apps/ocean/contiguous_partitions/OCEAN" "$(dirname "$STATIC")/OCEAN"

echo
echo "== the source both were built from =="
for f in "$SPLASH/apps/barnes/grav.c.in" "$SPLASH/apps/barnes/code.c.in"; do
  [ -f "$f" ] || { echo "   MISSING: $f"; continue; }
  echo "   $(basename "$f"): $(grep -c 'WITH_NO_OPTIONAL_LOCKS' "$f") lines naming WITH_NO_OPTIONAL_LOCKS, $(grep -c 'ALOCK(' "$f") ALOCK calls, md5 $(md5sum < "$f" | cut -c1-12)"
done
for f in "$SPLASH/apps/barnes/defs.h.in" "$SPLASH/apps/ocean/contiguous_partitions/decs.h.in"; do
  [ -f "$f" ] && echo "   $(basename "$f"): $(ls -l --time-style=long-iso "$f" | awk '{print $6}')  md5 $(md5sum < "$f" | cut -c1-12)  $(grep -E '^#define (MAX_BODIES_PER_LEAF|MAXLOCK|IMAX|JMAX|MAX_LEVELS) ' "$f" | tr -s ' \t' ' ' | tr '\n' ';')"
done
echo "   Makefile.config, the lines that set flags:"
grep -nE '^\s*(CFLAGS|LDFLAGS|MACROS|CC)\s*[:+]?=' "$SPLASH/Makefile.config" 2>/dev/null | sed 's/^/      /'
echo "   WITH_NO_OPTIONAL_LOCKS anywhere in the build files:"
grep -rnE 'WITH_NO_OPTIONAL_LOCKS' "$SPLASH/Makefile.config" "$SPLASH/apps/barnes/Makefile" 2>/dev/null | sed 's/^/      /' || true
echo "   generated sources and objects now in apps/barnes (the last build left them):"
for f in "$SPLASH/apps/barnes"/grav.c "$SPLASH/apps/barnes"/grav.o; do
  [ -e "$f" ] && echo "      $(basename "$f")  $(ls -l --time-style=long-iso "$f" | awk '{print $6, $7}')"
done

echo
echo "== how the static BARNES was compiled (~/splash_static_build.log) =="
if [ -f "$HOME/splash_static_build.log" ]; then
  grep -nE 'gcc .*grav\.c|gcc .*-o BARNES' "$HOME/splash_static_build.log" | tail -4 | cut -c1-400 | sed 's/^/   /'
else
  echo "   no build log"
fi

echo
echo "== how the traces were made (~/trace_gen_barnes.log, first lines) =="
if [ -f "$HOME/trace_gen_barnes.log" ]; then head -5 "$HOME/trace_gen_barnes.log" | cut -c1-300 | sed 's/^/   /'; else echo "   no trace log"; fi
for f in "$R/simulator/traces"/barnes_4t0.champsimtrace*; do
  echo "   $(basename "$f")  $(ls -l --time-style=long-iso "$f" | awk '{print $6, $7}')"
done
exit 0
