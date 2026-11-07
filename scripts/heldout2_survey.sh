#!/usr/bin/env bash
# Held-out set 2 (bench/policy_sanity/heldout2_design_2026-11-04.md): a READ-ONLY
# survey of the server for eligibility E1 (source, inputs, build dependencies)
# and E2 (how each candidate synchronises). Builds nothing, runs no program;
# reads files, prints versions. Writes only under ~/heldout2_survey.
#   1. the PARSEC trees: which packages, libraries and input tarballs they hold
#   2. each candidate, in the design's order: source, run configurations,
#      inputs, build configuration, and its synchronisation in the source
#   3. SPLASH-3 ocean non-contiguous
#   4. the toolchain: static libraries for gem5's binaries, autotools, yasm
#   5. what the runs would use: gem5, gem5's CPUID file, the tracer, the counter
#   6. the machine: disk, load, our processes
#
#   bash ~/heldout2_survey.sh      (scripts/heldout2_all.sh survey does this)
set -uo pipefail
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
SPLASH="${SPLASH:-$S/tracer/splash-3/codes}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
W="$HOME/heldout2_survey"
mkdir -p "$W"
CANDS="fluidanimate bodytrack facesim vips x264 ferret"
SRCX=(--include='*.c' --include='*.cc' --include='*.cpp' --include='*.C' --include='*.h' --include='*.hpp' --include='*.H')

echo "== 1. PARSEC trees"
TREES=""
for t in "$S/tracer/pin/parsec-full" "$S/tracer/pin/parsec-3.0" "$HOME/parsec-3.0" "$HOME/parsec-benchmark" "$HOME/parsec"; do
  [ -d "$t/pkgs" ] || continue
  TREES="$TREES $t"
  echo "-- $t"
  for k in apps kernels libs tools; do
    [ -d "$t/pkgs/$k" ] && echo "   pkgs/$k: $(ls "$t/pkgs/$k" | tr '\n' ' ')"
  done
  for l in glib libxml2 zlib gsl libjpeg; do
    [ -d "$t/pkgs/libs/$l" ] && echo "   lib $l: src $([ -d "$t/pkgs/libs/$l/src" ] && echo yes || echo no), built (inst/) $(ls -d "$t/pkgs/libs/$l/inst"/* 2>/dev/null | head -1 || true)"
  done
done
[ -n "$TREES" ] || echo "   no PARSEC tree with pkgs/ found"
echo "-- input tarballs (PARSEC's input sets)"
CRE=$(echo "$CANDS" | tr ' ' '|')
find "$S/tracer" "$HOME" -maxdepth 4 \( -type f -o -type l \) \( -name 'parsec-3.0-input-*.tar.gz' -o -name 'parsec-*input*.tar*' \) 2>/dev/null \
  | head -10 | while read -r f; do
    echo "   $f ($(du -hL "$f" | cut -f1)); the candidates' input sets in it:"
    timeout 900 tar -tzf "$f" 2>/dev/null | grep -E "pkgs/apps/($CRE)/inputs/.+" | sed 's/^/      /'
  done

echo
echo "== 2. the candidates, in the design's order"
for p in $CANDS; do
  echo "-- $p"
  found=0
  for t in $TREES; do
    d="$t/pkgs/apps/$p"
    [ -d "$d" ] || continue
    found=1
    echo "   tree: $t"
    if [ -d "$d/src" ]; then
      echo "   src: $(find "$d/src" -type f | wc -l) files; top: $(ls "$d/src" | head -15 | tr '\n' ' ')"
    else
      echo "   src: ABSENT"
    fi
    for c in simsmall simmedium simlarge native; do
      f="$d/parsec/$c.runconf"
      [ -f "$f" ] && echo "   $c.runconf: $(grep -E '^run_args' "$f" | cut -c1-200)"
    done
    if [ -d "$d/inputs" ]; then
      echo "   inputs/: $(ls -la "$d/inputs" | awk 'NR > 1 && $9 !~ /^\.\.?$/ { printf "%s (%s) ", $9, $5 }')"
    else
      echo "   inputs/: ABSENT"
    fi
    f="$d/parsec/gcc-pthreads.bldconf"
    [ -f "$f" ] && grep -E '^(build_deps|build_conf|build_env)=' "$f" | cut -c1-200 | sed 's/^/   pthreads bldconf: /'
    [ -d "$d/src" ] || continue
    # E2: how it synchronises (counts per kind, then the files)
    for k in pthread_create pthread_join pthread_mutex_lock pthread_cond_wait pthread_cond_broadcast pthread_barrier_wait \
             parsec_barrier ENABLE_AUTOMATIC_DROPIN '#pragma omp' __sync_ __atomic_ 'std::atomic' cmpxchg xchg futex sched_yield; do
      n=$(grep -rF "${SRCX[@]}" -- "$k" "$d/src" 2>/dev/null | wc -l)
      [ "$n" -gt 0 ] || continue
      fl=$(grep -rlF "${SRCX[@]}" -- "$k" "$d/src" 2>/dev/null | sed "s|$d/src/||" | head -6 | tr '\n' ' ')
      echo "   E2 $k: $n lines; $fl"
    done
    case "$p" in
      x264)
        echo "   x264: where threads are created (encoder.c):"
        grep -n -B2 -A2 'pthread_create' "$d/src/encoder/encoder.c" 2>/dev/null | head -24 | sed 's/^/      /' ;;
      ferret)
        echo "   ferret: thread pools created:"
        grep -rn "${SRCX[@]}" 'tpool_create\|pthread_create' "$d/src" 2>/dev/null | grep -v '^.*tpool\.[ch]:' | head -12 | sed "s|$d/src/||; s/^/      /" ;;
      vips)
        g="$t/pkgs/libs/glib/src"
        echo "   vips: the bundled GLib: $(grep -h -E 'glib_(major|minor|micro)_version' "$g/configure.in" "$g/configure.ac" 2>/dev/null | head -3 | tr -s ' \n' ' ')"
        for f in "$g/gthread/gthread-posix.c" "$g/glib/gthread-posix.c"; do
          [ -f "$f" ] && echo "   $f: pthread_mutex_lock $(grep -c pthread_mutex_lock "$f"), futex $(grep -c futex "$f"), pthread_cond_wait $(grep -c pthread_cond_wait "$f")"
        done ;;
      bodytrack)
        echo "   bodytrack: files that include the atomic headers: $(grep -rl "${SRCX[@]}" 'atomic/atomic.h' "$d/src" 2>/dev/null | grep -v '/threads/atomic/' | sed "s|$d/src/||" | tr '\n' ' ')(none listed = never included)"
        [ -x "$d/src/configure" ] && echo "   bodytrack: ships its own configure script" ;;
    esac
  done
  [ "$found" = 1 ] || echo "   ABSENT from every PARSEC tree"
done

echo
echo "== 3. SPLASH-3 ocean non-contiguous"
d="$SPLASH/apps/ocean/non_contiguous_partitions"
if [ -d "$d" ]; then
  grep -E '^\s*TARGET\s*[:+]?=' "$d/Makefile" 2>/dev/null | head -1 | sed 's/^/   /'
  echo "   files: $(ls "$d" | head -25 | tr '\n' ' ')"
  for k in pthread_create pthread_mutex_lock pthread_cond_wait pthread_barrier_wait BARRIER LOCK; do
    n=$(grep -rF "${SRCX[@]}" --include='*.in' --include='*.U' -- "$k" "$d" 2>/dev/null | wc -l)
    echo "   E2 $k: $n lines"
  done
  grep -E '^\s*(CC|CFLAGS|LDFLAGS)\s*[:+]?=' "$SPLASH/Makefile.config" 2>/dev/null | sed 's/^/   Makefile.config: /'
else
  echo "   ABSENT ($d)"
fi

echo
echo "== 4. the toolchain"
echo "   gcc: $(gcc --version 2>/dev/null | head -1); g++: $(g++ --version 2>/dev/null | head -1)"
for a in libstdc++.a libc.a libm.a libpthread.a libgcc_eh.a; do
  f=$(gcc -print-file-name="$a" 2>/dev/null)
  if [ -f "$f" ]; then echo "   static $a: $f"; else echo "   static $a: NOT FOUND"; fi
done
for c in autoconf automake libtool yasm nasm pkg-config make python3; do
  echo "   $c: $(command -v "$c" > /dev/null 2>&1 && ("$c" --version 2>/dev/null | head -1) || echo 'not installed')"
done
echo "   glibc: $(ldd --version 2>/dev/null | head -1)"

echo
echo "== 5. what the runs would use"
ls -la "$GEM5_DIR"/build/*/gem5.opt 2>/dev/null | awk '{print "   gem5:", $9, $6, $7, $8}' | grep . || echo "   gem5: NOT FOUND under $GEM5_DIR/build"
echo "   gem5 CPUID file: $(md5sum "$HOME/sync_nc/gem5.cpuid" 2>/dev/null | cut -c1-12 || echo 'none') ~/sync_nc/gem5.cpuid; QS $([ -f "$HOME/sync_nc/QS_PASSED" ] && echo passed || echo 'not passed'); QK $([ -f "$HOME/sync_nc/QK_PASSED" ] && echo passed || echo 'not passed'); void note $([ -f "$HOME/sync_nc/VOID" ] && echo present || echo absent)"
t="$HOME/sync_nc_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so"
echo "   tracer (gem5's CPUID): $([ -f "$t" ] && md5sum "$t" | cut -c1-12 || echo ABSENT) $t"
c="$HOME/streamfix/build/obj-intel64/stream_count.so"
echo "   counter: $([ -f "$c" ] && md5sum "$c" | cut -c1-12 || echo ABSENT) $c; COUNTER_MD5 $(cut -c1-12 "$HOME/streamfix/COUNTER_MD5" 2>/dev/null || echo none)"
echo "   ChampSim binary: $(cat "$HOME/sync_g6/BIN" 2>/dev/null || echo 'no ~/sync_g6/BIN'); Q0 $([ -f "$HOME/sync_g6/Q0_PASSED" ] && echo passed || echo 'not passed'); Q0m $([ -f "$HOME/sync_g6/Q0M_PASSED" ] && echo passed || echo 'not passed')"

echo
echo "== 6. the machine"
echo "   disk: $(df -h "$HOME" | tail -1 | awk '{print $4}') free; load: $(cut -d' ' -f1-3 /proc/loadavg); cores: $(nproc)"
me=$(id -u)
echo "   our processes: champsim $(pgrep -u "$me" -f 'bin/champsim' | wc -l), pin $(pgrep -u "$me" -f 'pin.* -t ' | wc -l), gem5 $(pgrep -u "$me" -f 'gem5.opt' | wc -l)"
