#!/usr/bin/env bash
# Step 2 on the server: synchronised replay (bench/policy_sanity/sync_replay_design_2026-10-18.md).
# Builds in its own tree; bin/champsim, its runners and every existing trace
# are left as they are. New traces go to traces/sync/, new runs to
# results/phaseA_b3_s2_*.
#
#   bash ~/sync_server.sh build    # ~/sync_build: ChampSim -> bin/champsim_sync_<md5>; the tracer; guards; Q0
#   bash ~/sync_server.sh chain    # detached: trace every B3 program with -sync 1, then the 12 runs
#   bash ~/sync_server.sh status
#
# VARIANT=mx (bench/policy_sanity/sync_mutex_design_2026-10-19.md): the same
# steps for mutex order by simulated timing, in their own places -- build
# ~/sync_mx_build, state ~/sync_mx, traces traces/sync_mx/, binary
# bin/champsim_syncmx_<md5>, runs results/phaseA_b3_m2_*. Its build adds Q0b:
# on the s2 traces (sync records without mutex addresses) the new binary prints
# every line champsim_sync_06f98fcb prints. Unset, everything is as before.
#
# VARIANT=g5 (bench/policy_sanity/b3_g5rule_design_2026-10-19.md): step 3, the
# gem5-rule view, records only. No tracing: it waits for the mx variant's
# traces (traces/sync_mx/), then Q0m -- on them the new binary prints every
# line champsim_syncmx_cc45d6f5 prints, apart from the new GEM5-RULE and
# VIEW-ORDER lines -- then the 12 runs -> results/phaseA_b3_g2_*, then Q0-full
# against the m2 runs (bash ~/sync_server.sh q0full, any time). Build
# ~/sync_g5_build, state ~/sync_g5, binary bin/champsim_g5_<md5>.
#
# VARIANT=g6 (amendment 2 of b3_g5rule_design_2026-10-19.md, 2026-10-27): the
# gem5-rule view with the view-order violations split into silent re-listings
# and unexplained ones; records only. Build ~/sync_g6_build, state ~/sync_g6,
# binary bin/champsim_g6_<md5>. Q0 and Q0m are against champsim_g5_034cd735,
# with only the three new lines filtered; the build runs both. The chain reruns
# the 12 configurations -> results/phaseA_b3_g3_*, then Q0-full against the g2
# runs and Q3 (unexplained 0, raw = by silent re-listing, in every run).
#
# VARIANT=nb (bench/policy_sanity/newbench_design_2026-10-19.md): the new
# benchmarks on the final tool. No build: the binary that passed Q0 and Q0m in
# the g6 variant (NB_BIN; it was champsim_g5_034cd735 until 2026-10-27) and the
# g5 tree's tracer. Programs and runs from ~/newbench/PROGS and ~/newbench/JOBS
# (newbench_server.sh size). Traces traces/sync_nb/, runs phaseA_b3_n2_*.
#
# VARIANT=nc (F2 of bench/policy_sanity/stream_fix_design_2026-11-02.md): step
# 4's programs traced again as on gem5's CPU. Builds only the tracer (with
# -cpuid; sources in ~/sync_nc_build), then QS and QK under gem5's CPUID
# (~/streamfix/gem5.cpuid, which passed QE, frozen in ~/sync_nc). Programs and
# runs are nb's lines (~/newbench/PROGS, JOBS) for NC_PROGS; the first trace has
# amendment 2's length, and if it is too short the rule is applied once (the
# anchor + 215 M, rounded up to 5 M; no anchor: the whole run). Runs on the g6
# binary, as nb. Traces traces/sync_nc/, runs phaseA_b3_n3_*.
#
# VARIANT=h2 (bench/policy_sanity/heldout2_design_2026-11-04.md, Note 4): held-out
# set 2. Uploaded as ~/sync_server_h2.sh, so the chains running from
# ~/sync_server.sh keep their file. build: only facesim's tracer (with -start0;
# sources in ~/sync_h2_build), under gem5's CPUID frozen in ~/sync_nc (md5
# checked), then QS, QK and QZ (start0_micro: -start0 broadcast exact, and its
# replay on the g6 binary). The other four programs keep nc's tracer.
# count (Note 7): QE-h2, then 24 counter runs (the five and streamcluster;
# gem5's CPUID x3, host x1) into ~/sync_h2/count/runs/, detached. sc (newbench
# amendment 3): writes streamcluster's lines (step 4's) so the next chain
# traces and runs it as a sixth program; refused while the chain runs.
#
# build: compiles ChampSim and the Pin tracer from the sources scripts/sync_all.sh
#   uploaded to ~/sync_build; the three policy guards; the binary is copied to
#   the main tree as bin/champsim_sync_<md5>, named in ~/sync/BIN. Q0: on traces
#   without sync records it prints what champsim_b3v4_69ebdcce prints (canneal
#   4c, 1 M + 2 M, lru and hawkeye, shared and private, levels 0 and 2), apart
#   from the wall clock and the bounded-view lines. Nothing runs otherwise.
# trace: each program as first traced (same binary, input, threads, skip),
#   with -sync 1, each thread written through a FIFO to xz (no raw trace ever
#   touches the disk); thread 0's serial start cut where the anchor cut it
#   before (sync_cut.py keeps the cut releases' meaning). Checks: every sync
#   call returned (no thread UNBALANCED), every expected thread traced.
# go: LRU, shared, level 2, the 12 B3 configurations (geometry and lengths as
#   first run) on the new traces -> results/phaseA_b3_s2_<suffix>.
set -uo pipefail
SELF="$(readlink -f "$0")"
# A stop that is not a clean exit says so (2026-10-19: a build stopped in Q0
# printing nothing, most likely the connection dropping).
trap 'rc=$?; [ "$rc" = 0 ] || echo "sync_server.sh ${1:-}: stopped, exit code $rc ($(date "+%F %T"))" >&2' EXIT

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
VARIANT="${VARIANT:-}"
case "$VARIANT" in
  "") CB_D="$HOME/sync_build";    W_D="$HOME/sync";    TDIR_D="$S/traces/sync";    TAG=s2; BINPFX=champsim_sync;   NEED='SYNC REPLAY' ;;
  mx) CB_D="$HOME/sync_mx_build"; W_D="$HOME/sync_mx"; TDIR_D="$S/traces/sync_mx"; TAG=m2; BINPFX=champsim_syncmx; NEED='SYNC MUTEX ORDER' ;;
  g5) CB_D="$HOME/sync_g5_build"; W_D="$HOME/sync_g5"; TDIR_D="$S/traces/sync_mx"; TAG=g2; BINPFX=champsim_g5;     NEED='GEM5-RULE' ;;
  g6) CB_D="$HOME/sync_g6_build"; W_D="$HOME/sync_g6"; TDIR_D="$S/traces/sync_mx"; TAG=g3; BINPFX=champsim_g6;     NEED='VIEW-ORDER VIOLATIONS UNEXPLAINED' ;;
  nb) CB_D="$HOME/sync_g5_build"; W_D="$HOME/sync_nb"; TDIR_D="$S/traces/sync_nb"; TAG=n2; BINPFX=champsim_g6;     NEED='VIEW-ORDER VIOLATIONS UNEXPLAINED'
      # the binary that passed Q0 and Q0m in the g6 variant (2026-10-27,
      # amendment 2); the tracer stays the g5 tree's, which passed QS
      NB_BIN="${NB_BIN:-$(cat "$HOME/sync_g6/BIN" 2>/dev/null)}"
      [ -n "${PROGS:-}" ] || PROGS="$(cat "$HOME/newbench/PROGS" 2>/dev/null)"
      [ -n "${JOBS_SPEC:-}" ] || JOBS_SPEC="$(cat "$HOME/newbench/JOBS" 2>/dev/null)" ;;
  # step 5 (policy_rerun_design_2026-10-19.md): the 9 policies on the m2
  # traces with the final binary, no build; canneal 16 is traced first if
  # missing; the 171 job lines in ~/sync_pol/JOBS (scripts/policy_jobs.py)
  pol) CB_D="$HOME/sync_g5_build"; W_D="$HOME/sync_pol"; TDIR_D="$S/traces/sync_mx"; TAG=p2; BINPFX=champsim_g6;   NEED='VIEW-ORDER VIOLATIONS UNEXPLAINED'
      NB_BIN="${NB_BIN:-$(cat "$HOME/sync_g6/BIN" 2>/dev/null)}"   # as for nb
      [ -n "${JOBS_SPEC:-}" ] || JOBS_SPEC="$(cat "$HOME/sync_pol/JOBS" 2>/dev/null)" ;;
  nc) CB_D="$HOME/sync_nc_build"; W_D="$HOME/sync_nc"; TDIR_D="$S/traces/sync_nc"; TAG=n3; BINPFX=champsim_g6;   NEED='VIEW-ORDER VIOLATIONS UNEXPLAINED'
      NB_BIN="${NB_BIN:-$(cat "$HOME/sync_g6/BIN" 2>/dev/null)}"         # as for nb
      NC_PROGS="${NC_PROGS:-fft volrend lu raytrace streamcluster lunc}"  # the longest first
      NC_CPUID_SRC="${NC_CPUID_SRC:-$HOME/streamfix/gem5.cpuid}"
      if [ -z "${PROGS:-}" ]; then
        for x in $NC_PROGS; do y=$(awk -F'|' -v n="$x" '$1 == n' "$HOME/newbench/PROGS" 2>/dev/null | head -1); [ -z "$y" ] || PROGS="${PROGS:+$PROGS
}$y"; done
      fi
      if [ -z "${JOBS_SPEC:-}" ]; then
        for x in $NC_PROGS; do y=$(awk -F'|' -v n="$x" '$7 == n' "$HOME/newbench/JOBS" 2>/dev/null); [ -z "$y" ] || JOBS_SPEC="${JOBS_SPEC:+$JOBS_SPEC
}$y"; done
      fi ;;
  h2) CB_D="$HOME/sync_h2_build"; W_D="$HOME/sync_h2"; TDIR_D="$S/traces/sync_h2"; TAG=h2; BINPFX=champsim_g6;   NEED='VIEW-ORDER VIOLATIONS UNEXPLAINED'
      NB_BIN="${NB_BIN:-$(cat "$HOME/sync_g6/BIN" 2>/dev/null)}"         # as for nb
      H2_CPUID_SRC="${H2_CPUID_SRC:-$HOME/sync_nc/gem5.cpuid}"            # QE held 2026-11-04; nc's QS and QK passed under it
      H2_CPUID_MD5="${H2_CPUID_MD5:-74d72229d62c92e4ce627b5298375a23}"   # the file Note 1 read
      NC_TRACER="${NC_TRACER:-$HOME/sync_nc_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so}"     # the four other programs' tracer
      # Note 6: the builds that passed (h2: QS, QK, QZ; nc: QS, QK under gem5's CPUID)
      H2_TRACER_MD5="${H2_TRACER_MD5:-02ff8f48654b81f6f277cdac8a13d60b}"
      NC_TRACER_MD5="${NC_TRACER_MD5:-f39707f3e4e197c409b362706a69e268}"
      H2_NAMES="fluidanimate bodytrack facesim vips oceannc"
      # the lines sizing wrote (heldout2_server.sh record)
      [ -n "${PROGS:-}" ] || PROGS="$(cat "$HOME/heldout2/PROGS" 2>/dev/null)"
      [ -n "${JOBS_SPEC:-}" ] || JOBS_SPEC="$(cat "$HOME/heldout2/JOBS" 2>/dev/null)"
      # newbench amendment 3: streamcluster joins as a sixth program once
      # 'sc' has written its lines (step 4's, unchanged); once only, since a
      # child of the chain may inherit them already appended
      if [ -f "$HOME/heldout2/streamcluster.PROGS" ] && ! echo "$PROGS" | grep -q '^streamcluster|'; then PROGS="$PROGS
$(cat "$HOME/heldout2/streamcluster.PROGS")"; fi
      if [ -f "$HOME/heldout2/streamcluster.JOBS" ] && ! echo "$JOBS_SPEC" | grep -q '|streamcluster$'; then JOBS_SPEC="$JOBS_SPEC
$(cat "$HOME/heldout2/streamcluster.JOBS")"; fi
      echo "$PROGS" | grep -q '^streamcluster|' && H2_NAMES="$H2_NAMES streamcluster"
      # Note 7: the counter runs (24: the five and streamcluster, gem5's CPUID x3 + host x1)
      NB_PROGS_FILE="${NB_PROGS_FILE:-$HOME/newbench/PROGS}"        # streamcluster's line, as step 4 traced it
      NB_JOBS_FILE="${NB_JOBS_FILE:-$HOME/newbench/JOBS}"
      SF_BUILD="${SF_BUILD:-$HOME/streamfix/build}"                 # cpuid_dump and cpuid_qe.py (QE)
      COUNT_PAR="${COUNT_PAR:-4}"
      COUNT_TIMEOUT="${COUNT_TIMEOUT:-12h}" ;;
  *) echo "VARIANT must be empty, mx, g5, g6, nb, nc, h2 or pol"; exit 1 ;;
esac
CB="${CB:-$CB_D}"
W="${W:-$W_D}"
REF="${REF:-$S/bin/champsim_b3v4_69ebdcce}"
REF_SYNC="${REF_SYNC:-$S/bin/champsim_sync_06f98fcb}"   # Q0b (VARIANT=mx): the first synchronised build
S2_TDIR="$S/traces/sync"                                  # its traces: sync records, no mutex addresses
REF_MX="${REF_MX:-$S/bin/champsim_syncmx_cc45d6f5}"     # Q0m and Q0-full (VARIANT=g5): the mutex-order build
MX_BIN="${MX_BIN:-$S/bin/champsim_syncmx_cc45d6f5}"     # VARIANT=mx: the binary its runs use (pre-registered 2026-10-19)
NEWLINES='BOUNDED-PROTOCOL|GEM5-RULE|VIEW-ORDER'           # lines a newer build adds; filtered where an older one is the reference
Q0FULL_REF=m2                                             # Q0-full: the runs each new run must equal
if [ "$VARIANT" = g6 ]; then
  # amendment 2: the reference is the g5 binary itself, so only the three new lines are filtered
  G5_BIN="${G5_BIN:-$S/bin/champsim_g5_034cd735}"
  REF="${REF_G6:-$G5_BIN}"; REF_MX="$G5_BIN"
  NEWLINES='SILENT RE-LISTING|VIOLATIONS UNEXPLAINED'
  Q0FULL_REF=g2
fi
WAIT_TRACES_H="${WAIT_TRACES_H:-48}"                      # VARIANT=g5: hours to wait for the mx traces
Q0M_PROGS="${Q0M_PROGS:-barnesstd ocean4}"                # VARIANT=g5: Q0m's programs
JOBS="${JOBS:-12}"
TPAR="${TPAR:-2}"                     # programs traced at once (each: a Pin thread and an xz per program thread)
PIN_ROOT="${PIN_ROOT:-$S/tracer/pin/pin-external-3.31-98869-gfa6f126a8-gcc-linux}"
TRACER="$CB/simulator/tracer/pin/obj-intel64/champsim_tracer.so"
TDIR="${TDIR:-$TDIR_D}"
MAX_INSTR="${MAX_INSTR:-215000000}"   # 200 M as before, plus the thread-0 cuts
MIN_FREE_GB="${MIN_FREE_GB:-6}"
MIN_TRACE="${MIN_TRACE:-172500000}"   # QT: instructions a traced thread holds after its cut (50 M + 100 M and the 15% margin)
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"
case "$VARIANT" in nc|h2) MC="${NC_MC:-$HOME/sync_g6_build/simulator/scripts/make_config.py}" ;; esac   # their trees hold only the tracer
SPLASH_APPS="$S/tracer/splash-3/codes/apps"

# name | binary | arguments | stdin | files the program opens in its directory | threads traced | skip | cut thread 0
#   [| instructions traced per thread: optional, MAX_INSTR when absent, 0 = the whole run
#    (newbench_design_2026-10-19.md, amendment 2: thread 0's set-up decides it)]
PROGS="${PROGS:-ocean4|$SPLASH_APPS/ocean/contiguous_partitions/OCEAN|-n514 -p4 -e1e-7 -r20000 -t28800|||0 1 2 3|0|0
canneal4|$S/tracer/pin/canneal|4 15000 2000 $S/tracer/pin/100000.nets 128|||1 2 3 4|0|0
canneal8|$S/tracer/pin/canneal|8 15000 2000 $S/tracer/pin/100000.nets 128|||1 2 3 4 5 6 7 8|0|0
barnes256|$SPLASH_APPS/barnes/BARNES||$SPLASH_APPS/barnes/inputs/n16384-p4||0 1 2 3|0|0
barnesstd|$HOME/barnes_std_build/codes/apps/barnes/BARNES||$SPLASH_APPS/barnes/inputs/n16384-p4||0 1 2 3|0|10570006
radix|$HOME/b3_heldout_build/radix/codes/kernels/radix/RADIX.dyn|-p4 -n16777216 -r1024|||0 1 2 3|780000000|0
waternsq|$HOME/b3_heldout_build/waternsq/codes/apps/water-nsquared/WATER-NSQUARED.dyn||$HOME/b3_heldout/inputs/waternsq.in|$HOME/b3_heldout/inputs/random.in|0 1 2 3|0|12952793
fmm|$HOME/b3_heldout_build/fmm/codes/apps/fmm/FMM.dyn||$HOME/b3_heldout/inputs/fmm.in||0 1 2 3|0|12773531}"
# step 5 adds canneal with 16 workers (policy_rerun_design_2026-10-19.md)
# (once: a child of the chain may inherit PROGS with it already appended)
if [ "$VARIANT" = pol ] && ! echo "$PROGS" | grep -q '^canneal16|'; then PROGS="$PROGS
canneal16|$S/tracer/pin/canneal|16 15000 2000 $S/tracer/pin/100000.nets 128|||$(seq -s ' ' 1 16)|0|0"; fi

# suffix | workload | cores | scaled (2 MB per core) | warm-up | measured | traces
JOBS_SPEC="${JOBS_SPEC:-ocean4|ocean|4|0|50000000|100000000|ocean4
ocean4_scaled|ocean|4|1|50000000|100000000|ocean4
canneal4|canneal|4|0|50000000|100000000|canneal4
canneal4_scaled|canneal|4|1|50000000|100000000|canneal4
canneal8|canneal|8|0|50000000|100000000|canneal8
barnes4|barnes|4|0|50000000|100000000|barnes256
barnesstd4_start|barnes|4|0|0|37900000|barnesstd
barnesstd4_force|barnes|4|0|37900000|50000000|barnesstd
barnesstd4|barnes|4|0|37900000|100000000|barnesstd
radix4|radix|4|0|50000000|100000000|radix
waternsq4|waternsq|4|0|50000000|100000000|waternsq
fmm4|fmm|4|0|50000000|100000000|fmm}"
NJOBS=$(echo "$JOBS_SPEC" | grep -c '|')

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_sync() { cat "$W/BIN" 2>/dev/null; }
free_gb() { df -BG --output=avail "$S/traces" | tail -1 | tr -dc 0-9; }

prog_field() {   # name field-number
  echo "$PROGS" | awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f }'
}

# the traces of a program, in core order
traces_for() {   # program
  local p="$1" tids cut0 t out="" f
  tids=$(prog_field "$p" 6); cut0=$(prog_field "$p" 8)
  [ -n "$tids" ] || { echo "MISSING:unknown program $p"; return 1; }
  for t in $tids; do
    # thread 0 cut (a number, or auto) -> the aligned trace; start0:broadcast
    # (VARIANT=h2, facesim) is no cut: the tracer started thread 0 there
    case "${cut0:-0}" in 0|start0:*) f="$TDIR/$p/raw$t.champsimtrace.xz" ;; *) if [ "$t" = 0 ]; then f="$TDIR/$p/raw0_aligned.champsimtrace.xz"; else f="$TDIR/$p/raw$t.champsimtrace.xz"; fi ;; esac
    [ -s "$f" ] || { echo "MISSING:$f"; return 1; }
    out="$out $f"
  done
  echo "${out# }"
}
tree_of() { echo "phaseA_b3_${TAG}_$1"; }
run_log() { echo "$S/results/$(tree_of "$1")/regime_${4:-shared}/$2_$3core/${5:-lru}/run.log"; }   # suffix wl cores [regime policy]
cfg_of() { echo "$W/cfg/$1.json"; }
is_done() { grep -q "$DONE_MARKER" "$(run_log "$1" "$2" "$3" "${4:-}" "${5:-}")" 2>/dev/null; }   # suffix wl cores [regime policy]
count_done() { local n=0 suf wl c sc wu si k pol rg mshr; while IFS='|' read -r suf wl c sc wu si k pol rg mshr; do is_done "$suf" "$wl" "$c" "$rg" "$pol" && n=$((n + 1)); done <<< "$JOBS_SPEC"; echo "$n"; }
# g5 and pol read the mx variant's traces: only a set whose DONE names the
# tracer that made it counts (sets from before 2026-10-20 have an empty DONE)
count_traced() { local n=0 p; for p in $(echo "$PROGS" | cut -d'|' -f1); do
  case "$VARIANT" in g5|g6|pol) [ -s "$TDIR/$p/DONE" ] && n=$((n + 1)) ;; *) [ -f "$TDIR/$p/DONE" ] && n=$((n + 1)) ;; esac
done; echo "$n"; }
NPROGS=$(echo "$PROGS" | grep -c '|')

build() {
  mkdir -p "$W"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/sync_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== ChampSim, in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  local n m
  n=$(strings -a "$CB/simulator/bin/champsim" | grep -c "$NEED")
  [ "${n:-0}" -gt 0 ] || die "the new binary does not print '$NEED' -- not the build this variant needs"
  echo "== the three policy guards, in that tree"
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/${BINPFX}_$m.tmp" && mv -f "$S/bin/${BINPFX}_$m.tmp" "$S/bin/${BINPFX}_$m"
  echo "$S/bin/${BINPFX}_$m" > "$W/BIN"
  echo "   frozen as bin/${BINPFX}_$m"
  # VARIANT=mx (2026-10-20): the runs use the binary pre-registered and
  # checked on 2026-10-19, which has no gem5-rule view; only the tracer needed
  # rebuilding. Q0 and Q0b below check that binary again.
  if [ "$VARIANT" = mx ] && [ -x "$MX_BIN" ]; then
    echo "$MX_BIN" > "$W/BIN"
    echo "   the runs use the pre-registered $(basename "$MX_BIN") (this build is used for its tracer)"
  fi
  echo "== the tracer, -sync 1 (Pin at $PIN_ROOT)"
  [ -x "$PIN_ROOT/pin" ] || die "no Pin at $PIN_ROOT"
  ( cd "$CB/simulator/tracer/pin" && rm -rf obj-intel64 && make PIN_ROOT="$PIN_ROOT" obj-intel64/champsim_tracer.so > "$W/tracer_build.log" 2>&1 ) \
    || { tail -15 "$W/tracer_build.log"; die "the tracer build failed"; }
  n=$(strings -a "$TRACER" | grep -c 'sync = ')
  [ "${n:-0}" -gt 0 ] || die "the tracer has no -sync"
  echo "   built: $TRACER"
  qs
  gcc -O2 -o "$W/trace_mix" "$HOME/trace_mix.c" || die "trace_mix does not compile"
  q0
  if [ "$VARIANT" = mx ]; then q0b; fi
  # g6: the m2 traces exist, so Q0m is part of the build (nb and pol require it)
  if [ "$VARIANT" = g6 ]; then q0m || die "Q0m failed ($W/q0m) -- nothing is launched"; fi
}

# Q0b (sync_mutex_design_2026-10-19.md): on traces with sync records but no
# mutex addresses -- the s2 traces -- the new binary prints every line the
# first synchronised build prints: lock-heavy barnes std and barrier-only
# canneal, 1 M + 2 M, level 2, in both mutex-order settings.
q0b() {
  local B; B=$(bin_sync); [ -x "$B" ] || die "no binary yet -- 'build'"
  [ -x "$REF_SYNC" ] || die "no reference $REF_SYNC for Q0b"
  local Q="$W/q0b" p t f c mo bad=0 n=0
  rm -rf "$Q"; mkdir -p "$Q"
  "$MC" --policy lru --cores 4 --regime shared --private-coherence 2 -o "$Q/cfg_timing.json" > /dev/null 2>&1 || die "make_config failed"
  "$MC" --policy lru --cores 4 --regime shared --private-coherence 2 --sync-mutex-order recorded -o "$Q/cfg_recorded.json" > /dev/null 2>&1 || die "make_config failed"
  echo "== Q0b: the s2 traces (no mutex addresses), against $(basename "$REF_SYNC"), 1 M + 2 M"
  for p in barnesstd canneal4; do
    t=$(TDIR="$S2_TDIR" traces_for "$p") || die "Q0b: no s2 traces for $p (${t#MISSING:})"
    [ -s "${t%% *}" ] || die "Q0b: no s2 traces for $p"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF_SYNC" --config "$Q/cfg_timing.json" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${p}_ref.log" 2>&1 ) &
    for mo in timing recorded; do
      # shellcheck disable=SC2086
      ( cd "$S" && nice -n 19 "$B" --config "$Q/cfg_$mo.json" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${p}_$mo.log" 2>&1 ) &
    done
  done
  wait
  for p in barnesstd canneal4; do
    grep -q "$DONE_MARKER" "$Q/${p}_ref.log" || { echo "   $p: the reference did not complete"; bad=$((bad + 1)); continue; }
    grep -q 'SYNC REPLAY: on' "$Q/${p}_ref.log" || { echo "   $p: the reference saw no sync records -- not the s2 traces?"; bad=$((bad + 1)); continue; }
    for mo in timing recorded; do
      n=$((n + 1))
      f="$Q/${p}_$mo.log"
      if grep -q 'SYNC MUTEX ORDER' "$f"; then echo "   $p ($mo): printed a mutex line on traces without mutex records"; bad=$((bad + 1)); continue; fi
      if ! diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$Q/${p}_ref.log" | grep -v -E "$NEWLINES") <(sed -E 's/\(Simulation time: [^)]*\)//' "$f" | grep -v -E "$NEWLINES") > /dev/null; then
        echo "   DIFFERS: $p ($mo)"; bad=$((bad + 1))
      fi
    done
  done
  [ "$bad" = 0 ] || die "Q0b failed: $bad of $n differ -- nothing is launched"
  echo "   Q0b holds: $n of $n print every line the first synchronised build prints"
  echo ok > "$W/Q0B_PASSED"
}

# QS (2026-10-20): the tracer, on THIS machine's glibc, records what a real
# pthread program does. The m2 traces had lock 0 / unlock 0 on every thread
# -- the server's glibc names pthread_mutex_lock differently from the
# laptop's, which every local test used -- and every SPLASH-3 run deadlocked.
# mutex_micro mx_condbar, 8 rounds: every thread takes the mutex at least 8
# times, unlocks it at least 8 times, and waits on or broadcasts the condition
# 8 times between them.
qs() {
  local Q="$W/qs" bad=0 line tid lk ul cw bc
  rm -rf "$Q"; mkdir -p "$Q"
  [ -f "$HOME/mutex_micro.c" ] || die "QS: no ~/mutex_micro.c -- the launcher uploads it"
  gcc -O2 -pthread -o "$Q/mm" "$HOME/mutex_micro.c" || die "QS: mutex_micro does not compile"
  local cpu=()
  case "$VARIANT" in nc|h2) cpu=(-cpuid "$W/gem5.cpuid") ;; esac   # nc and h2 trace under gem5's CPUID, so QS runs under it
  ( cd "$Q" && TMPDIR="$HOME/.build_tmp" timeout 600 "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 1 -sync 1 ${cpu[@]+"${cpu[@]}"} -- ./mm mx_condbar 8 > out.txt 2> pin.err ) \
    || die "QS: Pin failed on mutex_micro ($Q/pin.err)"
  echo "== QS: the tracer on this machine's glibc (mutex_micro mx_condbar, 8 rounds${cpu[*]:+, under the gem5 CPUID})"
  grep -E 'sync: pthread_(mutex_lock|mutex_unlock|cond_wait|cond_broadcast|barrier_wait|create) ' "$Q/pin.err" | sed 's/.*sync: /   hooked: /' | sort -u
  while IFS= read -r line; do
    tid=$(echo "$line" | sed -E 's/.*thread ([0-9]+) calls:.*/\1/')
    lk=$(echo "$line" | sed -E 's/.* lock ([0-9]+) .*/\1/'); ul=$(echo "$line" | sed -E 's/.* unlock ([0-9]+) .*/\1/')
    cw=$(echo "$line" | sed -E 's/.* cond_wait ([0-9]+) .*/\1/'); bc=$(echo "$line" | sed -E 's/.* broadcast ([0-9]+) .*/\1/')
    echo "   thread $tid: lock $lk unlock $ul cond_wait $cw broadcast $bc"
    [ "$lk" -ge 8 ] && [ "$ul" -ge 8 ] && [ $((cw + bc)) -ge 8 ] || bad=$((bad + 1))
  done < <(grep 'calls:' "$Q/pin.err")
  [ "$(grep -c 'calls:' "$Q/pin.err")" -ge 4 ] || bad=$((bad + 1))
  [ "$bad" = 0 ] || die "QS failed: the tracer misses pthread calls on this machine -- nothing is traced"
  echo "   QS holds: every thread's locks, unlocks and condition calls are recorded"
  echo ok > "$W/QS_PASSED"
}

# refresh (VARIANT=mx, 2026-10-20): traces made by another tracer than the one
# now built are moved aside -- the whole set, never part of it -- with the runs
# made from them, so the chain traces and runs again. Nothing is deleted:
# traces/sync_mx.void_<stamp>, results/void_<stamp>/.
refresh() {
  local stamp t cur bad=0 d
  [ -x "$TRACER" ] || die "no tracer yet -- 'build'"
  cur=$(md5sum < "$TRACER" | cut -c1-32)
  [ -d "$TDIR" ] || { echo "   refresh: no traces at $TDIR"; return 0; }
  for d in "$TDIR"/*/; do
    [ -f "$d/DONE" ] || continue
    [ "$(cat "$d/DONE")" = "$cur" ] || bad=$((bad + 1))
  done
  [ "$bad" -gt 0 ] || { echo "   refresh: every trace set was made by this tracer -- kept"; return 0; }
  stamp=$(date +%Y%m%d_%H%M%S)
  mv "$TDIR" "$TDIR.void_$stamp" || die "could not move $TDIR aside"
  mkdir -p "$S/results/void_$stamp"
  for t in "$S/results/phaseA_b3_${TAG}_"*; do [ -e "$t" ] && mv "$t" "$S/results/void_$stamp/"; done
  [ -f "$LOG" ] && mv "$LOG" "$LOG.void_$stamp"
  echo "   refresh: $bad trace set(s) were made by another tracer: moved aside to $(basename "$TDIR").void_$stamp, with the phaseA_b3_${TAG}_* runs (results/void_$stamp/)"
}

q0() {
  local B; B=$(bin_sync); [ -x "$B" ] || die "no binary yet -- 'build'"
  [ -x "$REF" ] || die "no reference $REF"
  local Q="$W/q0" t="" c pol rg lv bad=0 n=0 i f
  rm -rf "$Q"; mkdir -p "$Q"
  for i in 1 2 3 4; do
    f="$S/traces/canneal_4t/canneal$i.champsimtrace.xz"; [ -f "$f" ] || f="$S/traces/canneal_4t/canneal$i.champsimtrace"
    [ -f "$f" ] || die "no canneal_4t trace $i for Q0"
    t="$t $f"
  done
  echo "== Q0: every older log line, against $(basename "$REF"), canneal 4c (no sync records), 1 M + 2 M"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$MC" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_sync.log" 2>&1 ) &
  done; done; done
  echo "   $(date +%T) 16 runs started (8 pairs); waiting"
  # a line a minute while they run: a long silence lost the connection twice
  # (2026-10-19, at this step; the build itself finished on the server)
  while [ -n "$(jobs -rp)" ]; do
    sleep 60
    [ -z "$(jobs -rp)" ] || echo "   $(date +%T) $(ls "$Q"/*.log 2>/dev/null | xargs grep -l "$DONE_MARKER" 2>/dev/null | wc -l) of 16 runs done"
  done
  wait
  echo "   $(date +%T) runs finished"
  for f in "$Q"/*_ref.log; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$f" || { echo "   $(basename "$f"): did not complete"; bad=$((bad + 1)); continue; }
    if grep -q 'SYNC' "${f%_ref.log}_sync.log"; then echo "   $(basename "${f%_ref.log}"): printed SYNC lines on a trace without sync records"; bad=$((bad + 1)); continue; fi
    # the bounded-view lines are removed from both sides: a reference with or without them compares the same
    if ! diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$f" | grep -v -E "$NEWLINES") <(sed -E 's/\(Simulation time: [^)]*\)//' "${f%_ref.log}_sync.log" | grep -v -E "$NEWLINES") > /dev/null; then
      echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1))
    fi
  done
  [ "$bad" = 0 ] || die "Q0 failed: $bad of $n pairs differ -- nothing is launched"
  echo "   Q0 holds: $n of $n pairs print every older line the same"
  echo ok > "$W/Q0_PASSED"
}

trace_one() {   # program name
  local p="$1" bin args sin files tids skip cut0 len d t fpid pids=() fifo
  bin=$(prog_field "$p" 2); args=$(prog_field "$p" 3); sin=$(prog_field "$p" 4); files=$(prog_field "$p" 5)
  tids=$(prog_field "$p" 6); skip=$(prog_field "$p" 7); cut0=$(prog_field "$p" 8)
  len="${LEN_OVERRIDE:-$(prog_field "$p" 9)}"; len="${len:-$MAX_INSTR}"   # LEN_OVERRIDE: the length rule's second attempt (nc, nb)
  d="$TDIR/$p"
  if [ -f "$d/DONE" ]; then echo "$(date '+%F %T') $p: traced already"; return 0; fi
  [ -x "$bin" ] || { echo "$(date '+%F %T') $p: FAILED -- no binary $bin"; return 1; }
  [ "$(free_gb)" -ge "$MIN_FREE_GB" ] || { echo "$(date '+%F %T') $p: FAILED -- under $MIN_FREE_GB GB free"; return 1; }
  rm -rf "$d"; mkdir -p "$d" "$HOME/.build_tmp"
  echo "$len" > "$d/LEN"
  local cpu=() tr="$TRACER" s0=()
  case "$VARIANT" in nc|h2) cpu=(-cpuid "$W/gem5.cpuid") ;; esac
  # VARIANT=h2 (Note 6): facesim with h2's tracer from its first broadcast;
  # the other four with nc's tracer
  if [ "$VARIANT" = h2 ]; then
    case "$cut0" in start0:broadcast) s0=(-start0 broadcast); cut0=0 ;; 0|"") tr="$NC_TRACER" ;; *) echo "$p: FAILED -- thread 0's start '$cut0' is not one Note 6 knows"; return 1 ;; esac
  fi
  for f in $files; do cp -r "$f" "$d/" || { echo "$p: FAILED -- no $f"; return 1; }; done   # -r: an input may be a directory
  # Every thread Pin may start, 0-15 (or up to the highest thread traced, for
  # canneal's 16 workers and loader), gets a FIFO read by xz, so no raw trace
  # is ever written to disk.
  local maxt=15
  for t in $tids; do [ "$t" -le "$maxt" ] || maxt=$t; done
  for t in $(seq 0 "$maxt"); do
    fifo="$d/raw$t.champsimtrace"
    mkfifo "$fifo"
    ( xz -1 -T1 < "$fifo" > "$fifo.xz" ) &
    pids+=($!)
  done
  echo "$(date '+%F %T') $p: tracing (skip $skip, $([ "$len" = 0 ] && echo 'the whole run' || echo "$len per thread"), -sync 1${cpu[*]:+, under the gem5 CPUID}${s0[*]:+, thread 0 from its first broadcast}; tracer $(md5sum < "$tr" | cut -c1-8))"
  # shellcheck disable=SC2086 -- $args is the program's argument list
  ( cd "$d" && TMPDIR="$HOME/.build_tmp" nice -n 10 "$PIN_ROOT/pin" -t "$tr" -o raw -skip_instr "$skip" -max_instr "$len" -sync 1 ${cpu[@]+"${cpu[@]}"} ${s0[@]+"${s0[@]}"} \
      -- "$bin" $args < "${sin:-/dev/null}" > "$d/pin.out" 2> "$d/pin.err" )
  local rc=$?
  # FIFOs no thread opened: open each for writing once, so its reader sees EOF.
  for t in $(seq 0 "$maxt"); do
    fifo="$d/raw$t.champsimtrace"
    if kill -0 "${pids[$t]}" 2>/dev/null; then timeout 5 bash -c "exec 3>'$fifo'; exec 3>&-" 2>/dev/null || true; fi
  done
  wait "${pids[@]}" 2>/dev/null
  for t in $(seq 0 "$maxt"); do
    rm -f "$d/raw$t.champsimtrace"
    [ "$(xz -dc "$d/raw$t.champsimtrace.xz" 2>/dev/null | head -c 64 | wc -c)" = 64 ] || rm -f "$d/raw$t.champsimtrace.xz"
  done
  [ "$rc" = 0 ] || { echo "$(date '+%F %T') $p: FAILED -- Pin exited $rc ($d/pin.err)"; return 1; }
  if grep -q 'UNBALANCED' "$d/pin.err"; then echo "$(date '+%F %T') $p: FAILED -- a thread's sync calls did not all return"; grep UNBALANCED "$d/pin.err"; return 1; fi
  if [ ${#s0[@]} -gt 0 ]; then
    grep -q "start0: thread 0's window opens after" "$d/pin.err" && ! grep -q 'window NEVER opened' "$d/pin.err" \
      || { echo "$(date '+%F %T') $p: FAILED -- thread 0's window never opened (no pthread_cond_broadcast)"; return 1; }
    grep -E 'start0:' "$d/pin.err" | sed "s/^/   $p: /"
  fi
  for t in $tids; do
    [ -s "$d/raw$t.champsimtrace.xz" ] || { echo "$(date '+%F %T') $p: FAILED -- thread $t was not traced"; return 1; }
  done
  if [ "${cut0:-0}" = auto ]; then
    # thread 0's parallel section starts at its last pthread_create, which the
    # workers' first records name (sync_anchor.py; newbench_design_2026-10-19.md)
    local w=""
    for t in $tids; do [ "$t" = 0 ] || w="$w $d/raw$t.champsimtrace.xz"; done
    # shellcheck disable=SC2086 -- a list of traces
    cut0=$(python3 "$HOME/sync_anchor.py" "$d/raw0.champsimtrace.xz" $w 2> "$d/anchor.err" | tee "$d/anchor.txt" | awk '$1 == "CUT" { print $2 }')
    [ -n "$cut0" ] || { echo noanchor > "$d/FAILED"; echo "$(date '+%F %T') $p: FAILED -- no anchor ($d/anchor.err)"; return 1; }
    echo "$(date '+%F %T') $p: thread 0's last pthread_create after $cut0 instructions -- cut there"
  fi
  if [ "${cut0:-0}" != 0 ]; then
    python3 "$HOME/sync_cut.py" "$d/raw0.champsimtrace.xz" "$d/raw0_aligned.champsimtrace.xz" "$cut0" 2>> "$d/cut.log" \
      || { echo "$(date '+%F %T') $p: FAILED -- the cut ($d/cut.log)"; return 1; }
  fi
  # the instruction mix of every trace used, every 100,000 records (trace_mix.c)
  for f in $(traces_for "$p"); do
    xz -dc "$f" | nice -n 19 "$W/trace_mix" 100000 > "${f%.champsimtrace.xz}.mix"
  done
  # QT: every trace used holds enough instructions after its cut (records
  # minus sync records, from trace_mix's last line)
  local short=""
  for f in $(traces_for "$p"); do
    n=$(awk '$1 == "T" { print ($(NF - 1) == "sync") ? $2 - $NF : $2 }' "${f%.champsimtrace.xz}.mix")
    [ "${n:-0}" -ge "$MIN_TRACE" ] || short="$short $(basename "$f"):${n:-?}"
  done
  [ -z "$short" ] || { echo qt > "$d/FAILED"; echo "$(date '+%F %T') $p: FAILED -- traces shorter than $MIN_TRACE instructions:$short"; return 1; }
  grep -E 'sync: thread' "$d/pin.err" | sed "s/^/   $p: /"
  if [ "$VARIANT" = nc ] || [ "$VARIANT" = h2 ]; then
    grep -E 'cpuid' "$d/pin.err" | sed "s/^/   $p: /"
    md5sum < "$W/gem5.cpuid" | cut -c1-32 > "$d/CPUID"   # the CPUID these traces were recorded under
  fi
  md5sum < "$tr" | cut -c1-32 > "$d/DONE"   # which tracer made these traces
  echo "$(date '+%F %T') $p: traced ($(du -sh "$d" | cut -f1))"
}

# VARIANT=nc and nb: amendment 2's length rule (newbench_design_2026-10-19.md),
# applied once when the first trace fails for its length: the anchor found but
# QT short -> the anchor + 215 M, rounded up to 5 M; no anchor -> the whole run.
# nc: under gem5's CPUID thread 0's set-up is not the one the lengths were set
# for. nb (2026-11-04): LU non-contiguous, "traced by this amendment's length
# rule"; the other nb programs carry their length in PROGS field 9 already.
trace_nc() {
  local p="$1" d="$TDIR/$1" why first cut len
  trace_one "$p" && return 0
  why=$(cat "$d/FAILED" 2>/dev/null); first=$(cat "$d/LEN" 2>/dev/null)
  [ -n "$first" ] && [ "$first" != 0 ] || return 1    # the whole run already
  case "$why" in
    qt) if [ "$VARIANT" = h2 ]; then why=noanchor; len=0   # Note 6: no anchor in h2, so the whole run
        else
        cut=$(awk '$1 == "CUT" { print $2 }' "$d/anchor.txt" 2>/dev/null)
        [ -n "$cut" ] || return 1
        len=$(( (cut + 215000000 + 4999999) / 5000000 * 5000000 ))
        [ "$len" -gt "$first" ] || return 1
        fi ;;
    noanchor) len=0 ;;
    *) return 1 ;;
  esac
  echo "$(date '+%F %T') $p: amendment 2's length rule: $([ "$why" = qt ] && echo "anchor $cut, so $len a thread" || echo 'no anchor, so the whole run') -- traced again"
  LEN_OVERRIDE="$len" trace_one "$p"
}

# VARIANT=nc, the tracer alone: gem5's CPUID frozen (only one that passed QE),
# the tracer built, QS and QK under that CPUID
buildtracer() {
  mkdir -p "$W" "$HOME/.build_tmp"
  [ -f "$CB/simulator/tracer/pin/champsim_tracer.cpp" ] || die "no tracer sources in $CB -- scripts/syncnc_all.sh uploads them"
  local src="${NC_CPUID_SRC:-}"
  if [ "$VARIANT" = h2 ]; then
    # held-out set 2 (Note 4): the file nc froze after QE held, and no other (md5 as Note 1 read it)
    src="$H2_CPUID_SRC"
    [ -s "$src" ] && [ "$(md5sum < "$src" | cut -c1-32)" = "$H2_CPUID_MD5" ] \
      || die "no gem5 CPUID with md5 $H2_CPUID_MD5 at $src (the file nc froze after QE held)"
  else
    [ -s "$src" ] && grep -q 'QE holds' "$(dirname "$src")/driver.log" 2>/dev/null \
      || die "no gem5 CPUID that passed QE ($src; streamfix_server.sh's cpuid and qe steps)"
  fi
  if [ -f "$W/gem5.cpuid" ]; then
    cmp -s "$W/gem5.cpuid" "$src" || die "$W/gem5.cpuid differs from $src -- traces may exist under the first: nothing changed"
  else
    cp -p "$src" "$W/gem5.cpuid"
  fi
  echo "== gem5's CPUID (QE held): $W/gem5.cpuid, $(grep -c '^CPUID ' "$W/gem5.cpuid") lines, md5 $(md5sum < "$W/gem5.cpuid" | cut -c1-32); $(head -1 "$W/gem5.cpuid")"
  echo "== the tracer, -sync 1 and -cpuid$([ "$VARIANT" = h2 ] && echo ' and -start0') (Pin at $PIN_ROOT)"
  [ -x "$PIN_ROOT/pin" ] || die "no Pin at $PIN_ROOT"
  ( cd "$CB/simulator/tracer/pin" && rm -rf obj-intel64 && make PIN_ROOT="$PIN_ROOT" obj-intel64/champsim_tracer.so > "$W/tracer_build.log" 2>&1 ) \
    || { tail -15 "$W/tracer_build.log"; die "the tracer build failed"; }
  [ "$(strings -a "$TRACER" | grep -c 'cpuid = ')" -gt 0 ] || die "the tracer has no -cpuid"
  [ "$VARIANT" != h2 ] || [ "$(strings -a "$TRACER" | grep -c 'start0 = broadcast')" -gt 0 ] || die "the tracer has no -start0"
  echo "   built: $TRACER (md5 $(md5sum < "$TRACER" | cut -c1-32))"
  qs
  qk
  gcc -O2 -o "$W/trace_mix" "$HOME/trace_mix.c" || die "trace_mix does not compile"
  [ "$VARIANT" != h2 ] || qz
}

# QZ (VARIANT=h2; heldout2_design_2026-11-04.md, Note 4): -start0 broadcast,
# for facesim's thread 0. start0_micro has facesim's start: three workers wait
# on a condition, main runs a serial phase, then broadcasts inside the mutex.
# Under gem5's CPUID, as the programs are traced:
#   Z1-Z5 start0_check.py start0 (thread 0 begins with its base, then the first
#         instruction of the hooked broadcast; N - K records; each worker waits
#         for that broadcast once, after its release of the mutex);
#   Z6    without -start0 thread 0 starts at its beginning, base seq 1;
#   Z7    without -start0 this tracer writes what nc's tracer writes (stream_micro
#         1000, -sync 1): per thread equal records, loads, stores, RMWs,
#         branches and sync records (trace_mix); byte identity reported;
#   Z8    the -start0 traces replay on the g6 binary (level 2, 0 + 1 M): the run
#         completes, no SYNC DEADLOCK, and exactly 1 release of a mutex not held
#         (thread 0's unlock of the mutex taken before its window opened).
qz() {
  local Q="$W/qz" SB="${NC_SB:-$HOME/streamfix/build}" t a b n=0 ident=0 log
  rm -rf "$Q"; mkdir -p "$Q/s0" "$Q/plain" "$Q/z7new" "$Q/z7nc" "$Q/z8"
  [ -f "$HOME/start0_micro.c" ] && [ -f "$HOME/start0_check.py" ] || die "QZ: no ~/start0_micro.c or ~/start0_check.py -- heldout2_all.sh tracer uploads them"
  [ -x "$NC_TRACER" ] || die "QZ: no nc tracer at $NC_TRACER"
  [ -x "$SB/stream_micro" ] || die "QZ: no $SB/stream_micro -- the streamfix build first"
  [ -x "$NB_BIN" ] && [ "$(cat "$HOME/sync_g6/BIN" 2>/dev/null)" = "$NB_BIN" ] && [ -f "$HOME/sync_g6/Q0_PASSED" ] \
    || die "QZ: $NB_BIN is not the g6 binary that passed Q0 (scripts/syncg6_all.sh)"
  gcc -O2 -pthread -o "$Q/start0_micro" "$HOME/start0_micro.c" || die "QZ: start0_micro does not compile"
  echo "== QZ: -start0 broadcast on start0_micro (serial 2 M), under gem5's CPUID"
  ( cd "$Q/s0" && TMPDIR="$HOME/.build_tmp" timeout 600 "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 0 -sync 1 -start0 broadcast -cpuid "$W/gem5.cpuid" -- ../start0_micro 2000000 > out.txt 2> pin.err ) \
    || die "QZ: the tracer with -start0 failed ($Q/s0/pin.err)"
  python3 "$HOME/start0_check.py" start0 "$Q/s0" 3 || die "QZ FAILED (Z1-Z5)"
  ( cd "$Q/plain" && TMPDIR="$HOME/.build_tmp" timeout 600 "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 0 -sync 1 -cpuid "$W/gem5.cpuid" -- ../start0_micro 2000000 > out.txt 2> pin.err ) \
    || die "QZ: the tracer without -start0 failed ($Q/plain/pin.err)"
  python3 "$HOME/start0_check.py" plain "$Q/plain" || die "QZ FAILED (Z6)"
  rm -f "$Q"/plain/raw*.champsimtrace
  local nr=()   # Z7's two runs with address randomisation off, where the machine allows it
  setarch "$(uname -m)" -R true 2> /dev/null && nr=(setarch "$(uname -m)" -R)
  echo "   Z7: without -start0, this tracer against nc's ($(md5sum < "$NC_TRACER" | cut -c1-8)) on stream_micro 1000, -sync 1, gem5's CPUID$([ ${#nr[@]} -gt 0 ] && echo ', randomisation off' || echo ', randomisation on (no setarch -R)')"
  for t in z7new z7nc; do
    a="$TRACER"; [ "$t" = z7nc ] && a="$NC_TRACER"
    ( cd "$Q/$t" && TMPDIR="$HOME/.build_tmp" timeout 600 ${nr[@]+"${nr[@]}"} "$PIN_ROOT/pin" -t "$a" -o raw -max_instr 0 -sync 1 -cpuid "$W/gem5.cpuid" -- "$SB/stream_micro" 1000 > out.txt 2> pin.err ) \
      || die "QZ: Z7's run of $t failed ($Q/$t/pin.err)"
  done
  for a in "$Q"/z7nc/raw*.champsimtrace; do
    t=$(basename "$a"); b="$Q/z7new/$t"
    [ -f "$b" ] || die "QZ FAILED (Z7): this tracer wrote no $t"
    local x y
    x=$("$W/trace_mix" < "$a" | awk '$1 == "T" { $7 = ""; print }'); y=$("$W/trace_mix" < "$b" | awk '$1 == "T" { $7 = ""; print }')
    [ -n "$x" ] && [ "$x" = "$y" ] || die "QZ FAILED (Z7): $t differs: nc's '$x', this tracer's '$y'"
    cmp -s "$a" "$b" && ident=$((ident + 1))
    n=$((n + 1)); echo "   Z7 $t: $x (equal; byte for byte $(cmp -s "$a" "$b" && echo yes || echo no))"
  done
  [ "$n" -ge 2 ] && [ "$(ls "$Q"/z7new/raw*.champsimtrace | wc -l)" = "$n" ] || die "QZ FAILED (Z7): $n traces from nc's tracer, $(ls "$Q"/z7new/raw*.champsimtrace | wc -l) from this one"
  echo "   Z7 holds: $n of $n threads equal ($ident byte for byte)"
  rm -f "$Q"/z7*/raw*.champsimtrace
  "$MC" --policy lru --cores 4 --regime shared --private-coherence 2 -o "$Q/z8/cfg.json" > /dev/null 2>&1 || die "QZ: make_config failed"
  log="$Q/z8/champsim.log"
  ( cd "$Q/z8" && timeout 1800 "$NB_BIN" --config cfg.json --warmup-instructions 0 --simulation-instructions 1000000 \
      ../s0/raw0.champsimtrace ../s0/raw1.champsimtrace ../s0/raw2.champsimtrace ../s0/raw3.champsimtrace > champsim.log 2>&1 ) \
    || die "QZ FAILED (Z8): the replay exited non-zero ($log)"
  t=$(grep -m1 'SYNC MUTEX ORDER' "$log")
  echo "   Z8 replay on $(basename "$NB_BIN"): $(grep -c "$DONE_MARKER" "$log") complete; $(grep -c 'SYNC DEADLOCK' "$log") SYNC DEADLOCK; $(grep -m1 'SYNC REPLAY' "$log"); $t"
  grep -q "$DONE_MARKER" "$log" && ! grep -q 'SYNC DEADLOCK' "$log" && echo "$t" | grep -q 'releases of a mutex not held 1)' \
    || die "QZ FAILED (Z8): $log"
  rm -f "$Q"/s0/raw*.champsimtrace
  echo "   QZ holds"
  echo ok > "$W/QZ_PASSED"
}

# The counter for held-out set 2 (VARIANT=h2; heldout2_design_2026-11-04.md,
# Note 5): stream_count with the BROADCAST line and -base0 broadcast, built in
# h2's tree ($CB/simulator/tracer/stream_count); the streamfix counter in
# ~/streamfix/build is left as it is. Then QR, under gem5's CPUID and the host's:
#   R1 bcast_micro (one thread): the counter's BROADCAST 0 and thread-0 total
#      equal this variant's tracer's K and N (-start0), the trace N - K records;
#   R2 -base0 broadcast: bcast_micro with a worker (threads 0 and 1 broadcast,
#      window 1 M - 11 M) and start0_micro (facesim's shape, only thread 0,
#      window 0 - 1 M): S = K, W exact, the late create inside the window;
#   R3 without -base0, against the streamfix counter, on stream_micro 1000 and
#      bcast_micro: every .cnt and .rtn file equal byte for byte, the summaries
#      apart from the BROADCAST / HOOK lines.
# R1 and R3 compare two runs, so both run with address randomisation off
# (setarch -R; QR stops without it). With it on, ld.so's strcmp before main
# varies by 45 instructions from run to run (Note 5 amendment 1: the server's
# first QR, 2026-11-05).
COUNTER="$CB/simulator/tracer/stream_count/obj-intel64/stream_count.so"
buildcounter() {
  local D="$CB/simulator/tracer/stream_count"
  [ "$VARIANT" = h2 ] || die "the h2 counter is VARIANT=h2's"
  [ -f "$D/stream_count.cpp" ] && [ -f "$D/Makefile" ] || die "no counter sources in $D -- heldout2_all.sh counter uploads them"
  [ -f "$W/QZ_PASSED" ] && [ -x "$TRACER" ] && [ -s "$W/gem5.cpuid" ] || die "the h2 tracer has not passed QZ -- 'build' first (heldout2_all.sh tracer)"
  rm -f "$W/QR_PASSED" "$W/COUNTER_MD5" "$W/COUNTER_SRC"   # a failed rebuild leaves no earlier pass behind
  echo "== the counter, with -base0 broadcast (Pin at $PIN_ROOT)"
  ( cd "$D" && rm -rf obj-intel64 && make PIN_ROOT="$PIN_ROOT" obj-intel64/stream_count.so > "$W/counter_build.log" 2>&1 ) \
    || { tail -15 "$W/counter_build.log"; die "the counter build failed"; }
  [ "$(strings -a "$COUNTER" | grep -c 'BASE0 broadcast')" -gt 0 ] || die "the counter has no -base0"
  echo "   built: $COUNTER (md5 $(md5sum < "$COUNTER" | cut -c1-32))"
  qr
}
qr() {
  local Q="$W/qr" SB="${NC_SB:-$HOME/streamfix/build}" OLD cpu d v t rc
  OLD="$SB/obj-intel64/stream_count.so"
  [ -x "$COUNTER" ] || die "QR: no h2 counter -- 'counter'"
  rm -f "$W/QR_PASSED" "$W/COUNTER_MD5"
  [ -f "$HOME/bcast_micro.c" ] && [ -f "$HOME/bcast_check.py" ] && [ -f "$HOME/start0_micro.c" ] || die "QR: no ~/bcast_micro.c, ~/bcast_check.py or ~/start0_micro.c -- heldout2_all.sh counter uploads them"
  [ -x "$OLD" ] && [ -x "$SB/stream_micro" ] || die "QR: no streamfix counter or stream_micro in $SB"
  # an earlier QR's files are kept beside it (its trace removed: ~1 GB)
  if [ -d "$Q" ]; then rm -f "$Q"/*/r1t/raw*.champsimtrace; mv "$Q" "$Q.prev_$(date +%Y%m%d_%H%M%S)"; fi
  mkdir -p "$Q"
  gcc -O2 -pthread -o "$Q/bcast_micro" "$HOME/bcast_micro.c" && gcc -O2 -pthread -o "$Q/start0_micro" "$HOME/start0_micro.c" || die "QR: the micro programs do not compile"
  local nr=(setarch "$(uname -m)" -R)
  "${nr[@]}" true 2> /dev/null || die "QR: setarch -R does not work here -- R1 and R3 compare two runs and need address randomisation off"
  echo "== QR: the counter (md5 $(md5sum < "$COUNTER" | cut -c1-8)) against the tracer ($(md5sum < "$TRACER" | cut -c1-8)) and the streamfix counter ($(md5sum < "$OLD" | cut -c1-8)); R1 and R3 with randomisation off"
  pin() { ( cd "$1" && shift && TMPDIR="$HOME/.build_tmp" timeout 900 "$@" > out.txt 2> pin.err ) || die "QR: a Pin run failed ($1/pin.err)"; }
  for cpu in gem5 host; do
    local c=(); [ "$cpu" = gem5 ] && c=(-cpuid "$W/gem5.cpuid")
    d="$Q/$cpu"; mkdir -p "$d"/{r1t,r1c,r2a,r2b,r3o,r3n,r3ob,r3nb}
    echo "   -- $cpu CPUID"
    pin "$d/r1t" "${nr[@]}" "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 0 -sync 1 -start0 broadcast ${c[@]+"${c[@]}"} -- "$Q/bcast_micro" 2000000
    pin "$d/r1c" "${nr[@]}" "$PIN_ROOT/pin" -t "$COUNTER" -o c ${c[@]+"${c[@]}"} -base0 broadcast -- "$Q/bcast_micro" 2000000
    python3 "$HOME/bcast_check.py" ident "$d/r1t" "$d/r1c/c"; rc=$?
    rm -f "$d"/r1t/raw*.champsimtrace   # pass or fail: the trace was only for counting
    [ "$rc" = 0 ] || die "QR FAILED (R1, $cpu CPUID)"
    pin "$d/r2a" "$PIN_ROOT/pin" -t "$COUNTER" -o c ${c[@]+"${c[@]}"} -base0 broadcast -from 1000000 -to 11000000 -- "$Q/bcast_micro" 2000000 create
    python3 "$HOME/bcast_check.py" base0 "$d/r2a/c" 1000000 11000000 0,1 || die "QR FAILED (R2, bcast_micro, $cpu CPUID)"
    pin "$d/r2b" "$PIN_ROOT/pin" -t "$COUNTER" -o c ${c[@]+"${c[@]}"} -base0 broadcast -from 0 -to 1000000 -- "$Q/start0_micro" 2000000
    python3 "$HOME/bcast_check.py" base0 "$d/r2b/c" 0 1000000 0 || die "QR FAILED (R2, start0_micro, $cpu CPUID)"
    for v in o n; do
      t="$OLD"; [ "$v" = n ] && t="$COUNTER"
      pin "$d/r3$v" "${nr[@]}" "$PIN_ROOT/pin" -t "$t" -o c ${c[@]+"${c[@]}"} -- "$SB/stream_micro" 1000
      pin "$d/r3${v}b" "${nr[@]}" "$PIN_ROOT/pin" -t "$t" -o c ${c[@]+"${c[@]}"} -- "$Q/bcast_micro" 2000000
    done
    python3 "$HOME/bcast_check.py" same "$d/r3o/c" "$d/r3n/c" || die "QR FAILED (R3, stream_micro, $cpu CPUID)"
    python3 "$HOME/bcast_check.py" same "$d/r3ob/c" "$d/r3nb/c" || die "QR FAILED (R3, bcast_micro, $cpu CPUID)"
  done
  echo "   QR holds"
  md5sum < "$COUNTER" | cut -c1-32 > "$W/COUNTER_MD5"
  echo ok > "$W/QR_PASSED"
}

# QK (VARIANT=nc): the tracer answers CPUID as the counter does. cpuid_dump
# under it prints every line of gem5.cpuid and nothing else but the pairs gem5
# aborts on (cpuid_qe.py, as QE; stream_fix_design amendment 2); on
# stream_micro 1000, both under gem5's
# CPUID, thread 1's records, loads, stores and RMWs in the trace equal the
# counter's (the streamfix build's programs and counter)
qk() {
  local Q="$W/qk" SB="${NC_SB:-$HOME/streamfix/build}" f t c
  rm -rf "$Q"; mkdir -p "$Q"
  for f in cpuid_dump cpuid_qe.py stream_micro trace_mix obj-intel64/stream_count.so; do [ -e "$SB/$f" ] || die "QK: no $SB/$f -- the streamfix build first"; done
  ( cd "$Q" && TMPDIR="$HOME/.build_tmp" timeout 600 "$PIN_ROOT/pin" -t "$TRACER" -o cd -max_instr 1 -cpuid "$W/gem5.cpuid" -- "$SB/cpuid_dump" > dump.txt 2> dump.err ) \
    || die "QK: cpuid_dump under the tracer failed ($Q/dump.err)"
  python3 "$SB/cpuid_qe.py" "$W/gem5.cpuid" "$Q/dump.txt" > "$Q/dump.diff" 2>&1 \
    || die "QK FAILED: cpuid_dump under the tracer: $(head -1 "$Q/dump.diff") ($Q/dump.diff)"
  echo "== QK: cpuid_dump under the tracer: $(head -1 "$Q/dump.diff") ($(grep 'cpuid: replaced' "$Q/dump.err" | sed 's/.*cpuid: //'))"
  ( cd "$Q" && TMPDIR="$HOME/.build_tmp" timeout 600 "$PIN_ROOT/pin" -t "$TRACER" -o raw -max_instr 0 -cpuid "$W/gem5.cpuid" -- "$SB/stream_micro" 1000 > sm.out 2> sm.err ) \
    || die "QK: the tracer on stream_micro failed ($Q/sm.err)"
  ( cd "$Q" && TMPDIR="$HOME/.build_tmp" timeout 600 "$PIN_ROOT/pin" -t "$SB/obj-intel64/stream_count.so" -o c -cpuid "$W/gem5.cpuid" -- "$SB/stream_micro" 1000 > c.out 2> c.err ) \
    || die "QK: the counter on stream_micro failed ($Q/c.err)"
  t=$("$SB/trace_mix" < "$Q/raw1.champsimtrace" | awk '$1 == "T" { print $2, $3, $4, $5 }')
  c=$(awk '$1 == "T" { print $2, $3, $4, $5 }' "$Q/c.t1.cnt" 2>/dev/null)
  rm -f "$Q"/raw*.champsimtrace "$Q"/cd*.champsimtrace
  echo "   stream_micro 1000, gem5's CPUID, thread 1, records loads stores RMWs: tracer + trace_mix $t; counter $c"
  [ -n "$t" ] && [ "$t" = "$c" ] || die "QK FAILED: under gem5's CPUID the tracer does not write what the counter counts"
  echo "   QK holds"
  echo ok > "$W/QK_PASSED"
}

# A JOBS_SPEC line: suffix | workload | cores | scaled | warm-up | measured |
# traces [| policy | regime | LLC MSHRs]. The last three are optional and
# default to lru, shared and 16, so every earlier line runs as it did.
# ---- Note 7 (heldout2_design_2026-11-04.md): the counter runs, VARIANT=h2 ----
CW="$W/count"            # its runs (CW/runs/<program>__<gem5|host>__<k>, as stream_check2.py rows reads), log, pid
count_progs() {          # the five programs' PROGS lines, then streamcluster's from step 4
  echo "$PROGS" | grep -v '^streamcluster|'
  grep '^streamcluster|' "$NB_PROGS_FILE"
}
count_guards() {
  [ "$VARIANT" = h2 ] || die "the counter runs are VARIANT=h2's (Note 7)"
  [ -f "$W/QR_PASSED" ] && [ -x "$COUNTER" ] || die "the h2 counter has not passed QR -- heldout2_all.sh counter first"
  [ "$(md5sum < "$COUNTER" | cut -c1-32)" = "$(cat "$W/COUNTER_MD5" 2>/dev/null)" ] || die "the counter is not the build that passed QR ($(cat "$W/COUNTER_MD5" 2>/dev/null))"
  [ "$(md5sum < "$W/gem5.cpuid" 2>/dev/null | cut -c1-32)" = "$H2_CPUID_MD5" ] || die "~/sync_h2/gem5.cpuid is not QE's file ($H2_CPUID_MD5)"
  [ -x "$SF_BUILD/cpuid_dump" ] && [ -f "$SF_BUILD/cpuid_qe.py" ] || die "no cpuid_dump / cpuid_qe.py in $SF_BUILD (QE-h2)"
  [ "$(grep -c '^streamcluster|' "$NB_PROGS_FILE" 2>/dev/null)" = 1 ] || die "$NB_PROGS_FILE does not hold exactly one streamcluster line"
  local p n=0 bin
  for p in fluidanimate bodytrack facesim vips oceannc streamcluster; do
    [ "$(count_progs | awk -F'|' -v n="$p" '$1 == n' | wc -l)" = 1 ] || die "no single PROGS line for $p"
    bin=$(count_progs | awk -F'|' -v n="$p" '$1 == n { print $2 }'); [ -x "$bin" ] || die "$p: no binary $bin"
    n=$((n + 1))
  done
  [ "$(count_progs | grep -c .)" = "$n" ] || die "the counter's program list holds lines other than the six"
  if [ -d "$CW/runs" ] && [ -n "$(ls -A "$CW/runs" 2>/dev/null)" ] && [ "$(cat "$CW/COUNTER_MD5" 2>/dev/null)" != "$(md5sum < "$COUNTER" | cut -c1-32)" ]; then
    die "counter runs exist from another counter ($(cat "$CW/COUNTER_MD5" 2>/dev/null || echo unrecorded)) -- one set of counts is never made by two counters"
  fi
}
cl() { echo "$(date '+%F %T') $*"; }
qeh2() {                 # QE on the counter that counts: cpuid_dump under -cpuid answers as gem5 does
  local d="$W/qeh2"
  rm -f "$W/QEH2_PASSED"; rm -rf "$d"; mkdir -p "$d"
  cl "== QE-h2: cpuid_dump under the h2 counter ($(md5sum < "$COUNTER" | cut -c1-8)) with gem5's CPUID ($(md5sum < "$W/gem5.cpuid" | cut -c1-8))"
  ( cd "$d" && "$PIN_ROOT/pin" -t "$COUNTER" -o c -cpuid "$W/gem5.cpuid" -- "$SF_BUILD/cpuid_dump" > dump.txt 2> err.txt ) || { cl "QE-h2 FAILED: the run ($d) -- nothing is counted"; return 1; }
  if python3 "$SF_BUILD/cpuid_qe.py" "$W/gem5.cpuid" "$d/dump.txt" > "$d/diff.txt" 2>&1; then
    cl "QE-h2 holds: $(head -1 "$d/diff.txt" | sed 's/^holds: //'); $(grep '^CPUID replaced' "$d/c.summary")"
    date '+%F %T' > "$W/QEH2_PASSED"
  else
    cl "QE-h2 FAILED: $(head -1 "$d/diff.txt") ($d/diff.txt) -- nothing is counted"; return 1
  fi
}
count_list() {           # program mode k, the longest first
  local p
  for p in facesim vips bodytrack fluidanimate oceannc streamcluster; do
    echo "$p gem5 1"; echo "$p gem5 2"; echo "$p gem5 3"; echo "$p host 1"
  done
}
count_job() {            # program mode k: Note 7's run, once more if it does not exit 0
  local p="$1" mode="$2" k="$3" line bin args sin files tids skip cut0 rest d f rc t0 a opt=()
  line=$(count_progs | awk -F'|' -v n="$p" '$1 == n' | head -1)
  IFS='|' read -r _ bin args sin files tids skip cut0 rest <<< "$line"
  d="$CW/runs/${p}__${mode}__$k"
  if [ -f "$d/STATUS" ] && grep -q '^exit 0 ' "$d/STATUS"; then cl "$p $mode $k: done already"; return 0; fi
  case "${cut0:-0}" in start0:broadcast) opt=(-base0 broadcast) ;; 0) opt=(-cut0 0) ;; *) cl "$p $mode $k: FAILED -- thread 0's start '$cut0' is not one Note 7 knows"; return 1 ;; esac
  [ "$mode" = gem5 ] && opt+=(-cpuid "$W/gem5.cpuid")
  for a in 1 2; do
    if [ -d "$d" ]; then mkdir -p "$CW/failed"; mv "$d" "$CW/failed/${p}__${mode}__${k}_$(date +%Y%m%d_%H%M%S)"; fi
    mkdir -p "$d" "$HOME/.build_tmp"
    echo "$line" > "$d/PROGS"
    for f in $files; do cp -r "$f" "$d/" || { echo "exit nofile $f" > "$d/STATUS"; cl "$p $mode $k: FAILED -- no $f"; return 1; }; done
    printf 'binary %s\ncounter %s\ncpuid %s\noptions -o c -skip %s %s\nattempt %s\n' "$(md5sum < "$bin" | cut -c1-32)" "$(md5sum < "$COUNTER" | cut -c1-32)" \
      "$( [ "$mode" = gem5 ] && md5sum < "$W/gem5.cpuid" | cut -c1-32 || echo host)" "${skip:-0}" "${opt[*]}" "$a" > "$d/RUN"
    cl "$p $mode $k: started (attempt $a; ${opt[*]})"
    t0=$(date +%s)
    # shellcheck disable=SC2086 -- $args is the program's argument list
    ( cd "$d" && TMPDIR="$HOME/.build_tmp" timeout "$COUNT_TIMEOUT" nice -n 10 "$PIN_ROOT/pin" -t "$COUNTER" -o c -skip "${skip:-0}" "${opt[@]}" \
        -- "$bin" $args < "${sin:-/dev/null}" > pin.out 2> pin.err )
    rc=$?
    echo "exit $rc seconds $(( $(date +%s) - t0 ))" > "$d/STATUS"
    cl "$p $mode $k: exit $rc after $(( ($(date +%s) - t0) / 60 )) min (attempt $a)"
    [ "$rc" = 0 ] && return 0
  done
  return 1
}
count_check() {          # structure only, no rate: exit 0, the options, facesim's base, every traced thread's file
  local bad=0 p mode k d line tids t nb nb0
  while read -r p mode k; do
    d="$CW/runs/${p}__${mode}__$k"
    line=$(count_progs | awk -F'|' -v n="$p" '$1 == n' | head -1); tids=$(echo "$line" | cut -d'|' -f6)
    grep -q '^exit 0 ' "$d/STATUS" 2>/dev/null || { cl "   $p $mode $k: did not exit 0 ($(cat "$d/STATUS" 2>/dev/null || echo 'no STATUS'))"; bad=$((bad + 1)); continue; }
    if [ "$p" = facesim ]; then
      grep -q '^KNOBS base0 broadcast' "$d/c.summary" || { cl "   $p $mode $k: no 'KNOBS base0 broadcast'"; bad=$((bad + 1)); }
      nb=$(grep -c '^BROADCAST 0 ' "$d/c.summary"); nb0=$(grep -c '^BASE0 broadcast' "$d/c.summary")
      [ "$nb" = 1 ] && [ "$nb0" = 1 ] || { cl "   $p $mode $k: BROADCAST 0 lines $nb, BASE0 lines $nb0 (1 each expected)"; bad=$((bad + 1)); }
    else
      grep -q '^KNOBS step .* cut0 0 cpuid ' "$d/c.summary" || { cl "   $p $mode $k: KNOBS do not show -cut0 0"; bad=$((bad + 1)); }
    fi
    grep -q '^KNOBS step [0-9]* skip [0-9]* from 50000000 to 150000000 ' "$d/c.summary" || { cl "   $p $mode $k: KNOBS do not show the window 50-150 M"; bad=$((bad + 1)); }
    if [ "$mode" = gem5 ]; then grep -qF "cpuid $W/gem5.cpuid (" "$d/c.summary" || { cl "   $p $mode $k: KNOBS do not show gem5's CPUID file"; bad=$((bad + 1)); }
    else grep -q '^KNOBS step .* cpuid host (' "$d/c.summary" || { cl "   $p $mode $k: KNOBS do not show the host's CPUID"; bad=$((bad + 1)); }; fi
    for t in $tids; do [ -s "$d/c.t$t.cnt" ] || { cl "   $p $mode $k: no c.t$t.cnt for traced thread $t"; bad=$((bad + 1)); }; done
  done < <(count_list)
  return "$bad"
}
count_drive() {
  echo $$ > "$CW/.pid"
  md5sum < "$COUNTER" | cut -c1-32 > "$CW/COUNTER_MD5"
  cl "== Note 7: 24 counter runs (six programs: gem5's CPUID x3, host x1), $COUNT_PAR at a time, $COUNT_TIMEOUT a run; counter $(md5sum < "$COUNTER" | cut -c1-8)"
  if ! qeh2; then rm -f "$CW/.pid"; exit 1; fi
  local running=0 p mode k
  while read -r p mode k; do
    count_job "$p" "$mode" "$k" &
    running=$((running + 1))
    if [ "$running" -ge "$COUNT_PAR" ]; then wait -n; running=$((running - 1)); fi
  done < <(count_list)
  wait
  cl "== the runs' structure (no rate is read)"
  if count_check; then cl "COUNT DONE: 24 of 24 exited 0 with the options, bases and thread files Note 7 names"; date '+%F %T' > "$CW/DONE"
  else cl "COUNT ENDED WITH FAILURES (above): their programs have no native range"; fi
  rm -f "$CW/.pid"
}

job() {   # suffix wl cores scaled warmup sim program [policy regime llc_mshr]
  local suf="$1" wl="$2" n="$3" sc="$4" wu="$5" si="$6" k="$7" pol="${8:-lru}" rg="${9:-shared}" mshr="${10:-}" log t B c
  B=$(bin_sync); log=$(run_log "$suf" "$wl" "$n" "$rg" "$pol"); c="$W/cfg/${suf}_${rg}_${pol}.json"   # one per job: jobs run at once
  if is_done "$suf" "$wl" "$n" "$rg" "$pol"; then echo "$(date '+%F %T') SKIP  $suf (complete)"; return 0; fi
  # VARIANT=nb (newbench amendment 2): only from traces that passed QT
  if { [ "$VARIANT" = nb ] || [ "$VARIANT" = nc ] || [ "$VARIANT" = h2 ]; } && [ ! -f "$TDIR/$k/DONE" ]; then echo "$(date '+%F %T') FAIL  $suf -- $k is not traced, or its traces failed QT (no $TDIR/$k/DONE)"; return 0; fi
  t=$(traces_for "$k") || { echo "$(date '+%F %T') FAIL  $suf -- ${t#MISSING:}"; return 0; }
  mkdir -p "$(dirname "$log")" "$(dirname "$c")"
  # shellcheck disable=SC2046
  "$MC" --policy "$pol" --cores "$n" --regime "$rg" --private-coherence 2 $( [ "$sc" = 1 ] && echo --llc-per-core-mb 2 ) ${mshr:+--llc-mshr "$mshr"} -o "$c" > /dev/null 2>&1 \
    || { echo "$(date '+%F %T') FAIL  $suf -- config"; return 0; }
  echo "$(date '+%F %T') START $suf ($wl ${n}c, $pol, $rg${mshr:+, LLC MSHRs $mshr}, $wu + $si)"
  # shellcheck disable=SC2086
  ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions "$wu" --simulation-instructions "$si" $t > "$log" 2>&1 )
  echo "$(date '+%F %T') END   $suf rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

# VARIANT=g5, Q0m: on the m2 traces (lock-heavy barnes std, barrier-driven
# ocean; 1 M + 2 M, level 2) the new binary prints every line the mutex-order
# build prints, apart from the lines it adds. VARIANT=g6: the same against the
# g5 binary, only the three new lines filtered.
q0m() {
  local B; B=$(bin_sync); [ -x "$B" ] || die "no binary yet -- 'build'"
  [ -x "$REF_MX" ] || die "no reference $REF_MX for Q0m"
  local Q="$W/q0m" p t bad=0 n=0
  rm -rf "$Q"; mkdir -p "$Q"
  "$MC" --policy lru --cores 4 --regime shared --private-coherence 2 -o "$Q/cfg.json" > /dev/null 2>&1 || die "make_config failed"
  echo "== Q0m: the m2 traces, against $(basename "$REF_MX"), 1 M + 2 M"
  for p in $Q0M_PROGS; do
    t=$(traces_for "$p") || die "Q0m: no m2 traces for $p (${t#MISSING:})"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF_MX" --config "$Q/cfg.json" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${p}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$Q/cfg.json" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${p}_new.log" 2>&1 ) &
  done
  wait
  for p in $Q0M_PROGS; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$Q/${p}_ref.log" || { echo "   $p: the reference did not complete"; bad=$((bad + 1)); continue; }
    grep -q 'GEM5-RULE' "$Q/${p}_new.log" || { echo "   $p: the new binary printed no GEM5-RULE line"; bad=$((bad + 1)); continue; }
    if ! diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$Q/${p}_ref.log" | grep -v -E "$NEWLINES") <(sed -E 's/\(Simulation time: [^)]*\)//' "$Q/${p}_new.log" | grep -v -E "$NEWLINES") > /dev/null; then
      echo "   DIFFERS: $p"; bad=$((bad + 1))
    fi
  done
  [ "$bad" = 0 ] || { echo "   Q0m FAILED: $bad of $n differ"; return 1; }
  echo "   Q0m holds: $n of $n print every line the mutex-order build prints"
  echo ok > "$W/Q0M_PASSED"
}

# VARIANT=g5, Q0-full: each g2 run against its m2 run, line by line, apart from
# the lines the new binary adds and the wall clock. The view changes no
# behaviour, so they must be identical. Pairs whose m2 run has not finished are
# counted as waiting.
q0full() {
  local suf wl c sc wu si k a b same=0 differ=0 waiting=0
  while IFS='|' read -r suf wl c sc wu si k; do
    a="$S/results/phaseA_b3_${Q0FULL_REF}_$suf/regime_shared/${wl}_${c}core/lru/run.log"
    b="$(run_log "$suf" "$wl" "$c")"
    if ! grep -q "$DONE_MARKER" "$a" 2>/dev/null || ! grep -q "$DONE_MARKER" "$b" 2>/dev/null; then waiting=$((waiting + 1)); continue; fi
    if diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$a" | grep -v -E "$NEWLINES") <(sed -E 's/\(Simulation time: [^)]*\)//' "$b" | grep -v -E "$NEWLINES") > /dev/null; then
      same=$((same + 1))
    else
      differ=$((differ + 1)); echo "   Q0-full DIFFERS: $suf"
    fi
  done <<< "$JOBS_SPEC"
  echo "   Q0-full: $same identical, $differ differ, $waiting waiting for a run (of $NJOBS)"
}

# VARIANT=g6, Q3 (amendment 2): in every run, VIEW-ORDER VIOLATIONS
# UNEXPLAINED reads 0 and the raw count equals the lines explained by silent
# re-listing. The g2 run's raw count is printed beside it (Q0-full requires
# them equal).
q3() {
  local suf wl c sc wu si k f g raw bys un sre graw bad=0 n=0
  while IFS='|' read -r suf wl c sc wu si k; do
    f="$(run_log "$suf" "$wl" "$c")"
    grep -q "$DONE_MARKER" "$f" 2>/dev/null || continue
    g="$S/results/phaseA_b3_g2_$suf/regime_shared/${wl}_${c}core/lru/run.log"
    roi() { awk '/^Region of Interest Statistics/ { r = 1 } r' "$1"; }
    raw=$(roi "$f" | awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS:/ { print $NF }')
    bys=$(roi "$f" | awk '/^LLC COHERENCE DIR VIEW-ORDER LINES BY SILENT RE-LISTING:/ { print $NF }')
    un=$(roi "$f" | awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:/ { print $NF }')
    sre=$(roi "$f" | awk '/^cpu[0-9]+_(L1I|L1D|L2C) COHERENCE DIR GEM5-RULE SILENT RE-LISTINGS:/ { s += $NF } END { print s + 0 }')
    graw=$(roi "$g" 2>/dev/null | awk '/^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS:/ { print $NF }')
    n=$((n + 1))
    echo "   Q3 $suf: raw $raw (g2 ${graw:-?}), by silent re-listing $bys, unexplained $un; silent re-listings $sre"
    [ "$un" = 0 ] && [ "$bys" = "$raw" ] || bad=$((bad + 1))
  done <<< "$JOBS_SPEC"
  if [ "$bad" = 0 ]; then echo "   Q3 holds in $n of $NJOBS runs: no unexplained violation"; else echo "   Q3 FAILS in $bad of $n runs"; fi
}

chain() {
  echo $$ > "$PIDF"
  if [ "$VARIANT" = g5 ] || [ "$VARIANT" = g6 ]; then
    # no tracing: the mx variant's traces, once all of them are done
    local waited=0
    echo "$(date '+%F %T') CHAIN START: wait for the m2 traces ($(count_traced) of $NPROGS done), Q0m, then $NJOBS runs ($JOBS at a time), $(basename "$(bin_sync)")"
    while [ "$(count_traced)" != "$NPROGS" ]; do
      [ "$waited" -lt $((WAIT_TRACES_H * 12)) ] || { echo "$(date '+%F %T') CHAIN STOPPED: the m2 traces are not done after $WAIT_TRACES_H h"; rm -f "$PIDF"; return 1; }
      sleep 300; waited=$((waited + 1))
    done
    echo "$(date '+%F %T') the m2 traces are done"
    if ! q0m; then echo "$(date '+%F %T') CHAIN STOPPED: Q0m failed ($W/q0m)"; rm -f "$PIDF"; return 1; fi
  else
    echo "$(date '+%F %T') CHAIN START: trace $NPROGS programs ($TPAR at a time), then $NJOBS runs ($JOBS at a time), $(basename "$(bin_sync)")"
    echo "$PROGS" | cut -d'|' -f1 | xargs -P "$TPAR" -I{} bash "$SELF" __trace {}
    if [ "$(count_traced)" != "$NPROGS" ]; then
      # VARIANT=nb (newbench amendment 2): one program's failure does not hold
      # back the runs of those whose traces passed QT; job() refuses the rest
      if { [ "$VARIANT" = nb ] || [ "$VARIANT" = nc ] || [ "$VARIANT" = h2 ]; } && [ "$(count_traced)" != 0 ]; then
        echo "$(date '+%F %T') $(count_traced) of $NPROGS programs traced: the runs of those traced go ahead"
      else
        echo "$(date '+%F %T') CHAIN STOPPED: $(count_traced) of $NPROGS programs traced"
        rm -f "$PIDF"; return 1
      fi
    fi
  fi
  echo "$JOBS_SPEC" | tr '|' ' ' | xargs -P "$JOBS" -L 1 bash "$SELF" __job
  echo "$(date '+%F %T') CHAIN END: $(count_done) of $NJOBS runs complete"
  [ "$VARIANT" != g5 ] && [ "$VARIANT" != g6 ] || q0full
  [ "$VARIANT" != g6 ] || q3
  rm -f "$PIDF"
}

case "${1:-}" in
  # The build's output is also kept on the server ($W/build_run.log). Run under
  # nohup (sync_all.sh does), it finishes even if the connection drops: tee -p
  # keeps writing the file when the pipe to ssh breaks.
  build) mkdir -p "$W"; case "$VARIANT" in nc|h2) buildtracer ;; *) build ;; esac 2>&1 | tee -p "$W/build_run.log"; exit "${PIPESTATUS[0]}" ;;
  qk)    qk ;;
  counter) [ "$VARIANT" = h2 ] || die "'counter' is VARIANT=h2's"; mkdir -p "$W"; buildcounter 2>&1 | tee -p "$W/counter_run.log"; exit "${PIPESTATUS[0]}" ;;
  qr)    [ "$VARIANT" = h2 ] || die "QR is VARIANT=h2's check"; qr ;;
  count)   # Note 7: guards here (the caller sees a refusal), then QE-h2 and the 24 runs, detached
    count_guards
    mkdir -p "$CW"
    if alive "$CW/.pid"; then echo "the counter runs are running already (pid $(cat "$CW/.pid"))"; exit 0; fi
    if [ -f "$CW/DONE" ]; then echo "the counter runs are done ($(cat "$CW/DONE")) -- nothing to do"; exit 0; fi
    setsid bash "$SELF" __count >> "$CW/driver.log" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$CW/.pid" || [ -f "$CW/DONE" ] || { tail -5 "$CW/driver.log"; die "the counter runs stopped (above; $CW/driver.log)"; }
    echo "started: QE-h2, then 24 counter runs, $COUNT_PAR at a time; log $CW/driver.log" ;;
  __count) count_drive ;;
  sc)      # newbench amendment 3: streamcluster's lines (step 4's, unchanged) for the chain's sixth program
    [ "$VARIANT" = h2 ] || die "'sc' is VARIANT=h2's"
    alive "$PIDF" && die "the h2 chain is running -- 'sc' waits until its runs have ended"
    [ "$(grep -c '^streamcluster|' "$NB_PROGS_FILE" 2>/dev/null)" = 1 ] && [ "$(grep -c '|streamcluster$' "$NB_JOBS_FILE" 2>/dev/null)" = 1 ] \
      || die "$NB_PROGS_FILE and $NB_JOBS_FILE must hold exactly one streamcluster line each"
    [ -f "$HOME/newbench/streamcluster/SIZED" ] || die "streamcluster is not sized by step 4 (~/newbench/streamcluster/SIZED)"
    grep '^streamcluster|' "$NB_PROGS_FILE" > "$HOME/heldout2/streamcluster.PROGS"
    grep '|streamcluster$' "$NB_JOBS_FILE" > "$HOME/heldout2/streamcluster.JOBS"
    echo "streamcluster's lines written (step 4's): $(cat "$HOME/heldout2/streamcluster.PROGS")"
    echo "   $(cat "$HOME/heldout2/streamcluster.JOBS")" ;;
  qz)    [ "$VARIANT" = h2 ] || die "QZ is VARIANT=h2's check"; [ -x "$TRACER" ] && [ -s "$W/gem5.cpuid" ] && [ -x "$W/trace_mix" ] || die "no h2 tracer yet -- 'build'"; qz ;;
  q0)    q0 ;;
  stop)
    # end this variant's chain and everything it started (its own session):
    # never another variant's, never anyone else's
    if alive "$PIDF"; then
      sid=$(cat "$PIDF")
      [ "$(ps -o sid= -p "$sid" | tr -d ' ')" = "$sid" ] || die "pid $sid is not a session leader -- stopping nothing"
      ps -o args= -p "$sid" | grep -q 'sync_server.sh __chain' || die "pid $sid is not a sync_server.sh chain -- stopping nothing"
      pkill -TERM -s "$sid"; sleep 2
      pgrep -s "$sid" > /dev/null && pkill -KILL -s "$sid"
      rm -f "$PIDF"
      echo "stopped the ${VARIANT:-s2} chain (session $sid) and its runs; $(date '+%F %T')" | tee -a "$LOG"
    else
      echo "no ${VARIANT:-s2} chain is running"
    fi ;;
  qs)    qs ;;
  refresh) refresh ;;
  q0b)   q0b ;;
  q0m)   q0m ;;
  q0full) q0full ;;
  q3)    q3 ;;
  chain)
    mkdir -p "$W" "$TDIR"
    if [ "$VARIANT" = h2 ]; then
      # Note 6's guards: the two tracers that passed, QE's CPUID file, the five sized programs
      [ -f "$W/QZ_PASSED" ] && [ -x "$TRACER" ] || die "h2's tracer has not passed QS, QK and QZ -- heldout2_all.sh tracer first"
      [ "$(md5sum < "$TRACER" | cut -c1-32)" = "$H2_TRACER_MD5" ] || die "h2's tracer is not the build that passed QZ ($H2_TRACER_MD5)"
      [ -f "$HOME/sync_nc/QS_PASSED" ] && [ -f "$HOME/sync_nc/QK_PASSED" ] && [ -x "$NC_TRACER" ] || die "nc's tracer has not passed QS and QK"
      [ "$(md5sum < "$NC_TRACER" | cut -c1-32)" = "$NC_TRACER_MD5" ] || die "nc's tracer is not the build that passed QS and QK ($NC_TRACER_MD5)"
      [ "$(md5sum < "$W/gem5.cpuid" 2>/dev/null | cut -c1-32)" = "$H2_CPUID_MD5" ] || die "~/sync_h2/gem5.cpuid is not QE's file ($H2_CPUID_MD5)"
      for x in $H2_NAMES; do
        # streamcluster (newbench amendment 3) was sized by step 4
        sz="$HOME/heldout2/$x/SIZED"; [ "$x" = streamcluster ] && sz="$HOME/newbench/streamcluster/SIZED"
        [ -f "$sz" ] || die "$x is not sized ($sz)"
        [ "$(echo "$PROGS" | awk -F'|' -v n="$x" '$1 == n' | wc -l)" = 1 ] || die "~/heldout2/PROGS does not hold exactly one line for $x"
        [ "$(echo "$JOBS_SPEC" | awk -F'|' -v n="$x" '$7 == n' | wc -l)" = 1 ] || die "~/heldout2/JOBS does not hold exactly one line for $x"
      done
      nn=$(echo "$H2_NAMES" | wc -w)
      [ "$(echo "$PROGS" | grep -c .)" = "$nn" ] && [ "$(echo "$JOBS_SPEC" | grep -c .)" = "$nn" ] || die "~/heldout2/PROGS and JOBS must hold the $nn programs' lines and nothing else"
      if [ "$nn" = 6 ]; then   # amendment 3: streamcluster's lines are step 4's, unchanged
        [ "$(cat "$HOME/heldout2/streamcluster.PROGS")" = "$(grep '^streamcluster|' "$NB_PROGS_FILE")" ] || die "~/heldout2/streamcluster.PROGS is not step 4's line ($NB_PROGS_FILE)"
        [ "$(cat "$HOME/heldout2/streamcluster.JOBS")" = "$(grep '|streamcluster$' "$NB_JOBS_FILE")" ] || die "~/heldout2/streamcluster.JOBS is not step 4's line ($NB_JOBS_FILE)"
      fi
    fi
    if [ "$VARIANT" = nc ]; then
      [ -f "$W/QS_PASSED" ] && [ -f "$W/QK_PASSED" ] || die "QS and QK have not passed -- 'build' first"
      [ -s "$W/gem5.cpuid" ] || die "no frozen gem5.cpuid -- 'build' first"
    fi
    if [ "$VARIANT" = nb ] || [ "$VARIANT" = nc ] || [ "$VARIANT" = h2 ] || [ "$VARIANT" = pol ]; then
      # no build: the binary that passed Q0 and Q0m in the g6 variant, and the g5 tree's tracer (nc: its own)
      [ -n "$PROGS" ] && [ -n "$JOBS_SPEC" ] || die "no programs or jobs (nb: newbench_server.sh size first; pol: ~/sync_pol/JOBS, from scripts/policy_all.sh)"
      [ -x "$NB_BIN" ] || die "no $NB_BIN -- the g6 build first (scripts/syncg6_all.sh)"
      [ "$(cat "$HOME/sync_g6/BIN" 2>/dev/null)" = "$NB_BIN" ] && [ -f "$HOME/sync_g6/Q0_PASSED" ] && [ -f "$HOME/sync_g6/Q0M_PASSED" ] \
        || die "$NB_BIN is not the g6 variant's binary that passed Q0 and Q0m (scripts/syncg6_all.sh)"
      echo "$NB_BIN" > "$W/BIN"; cp -p "$HOME/sync_g6/Q0_PASSED" "$W/Q0_PASSED"
      [ -x "$W/trace_mix" ] || gcc -O2 -o "$W/trace_mix" "$HOME/trace_mix.c" || die "trace_mix does not compile"
    fi
    [ -f "$W/Q0_PASSED" ] || die "Q0 has not passed -- 'build' first"
    [ "$VARIANT" != mx ] || [ -f "$W/Q0B_PASSED" ] || die "Q0b has not passed -- 'build' first"
    B=$(bin_sync); [ -x "$B" ] || die "no binary"
    [ "$(strings -a "$B" | grep -c "$NEED")" -gt 0 ] || die "$B does not print '$NEED': not the build this variant needs (an older one would misread the records)"
    [ -x "$TRACER" ] || die "no tracer"
    if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF"))"; exit 0; fi
    n0=$([ -f "$LOG" ] && wc -l < "$LOG" || echo 0)
    setsid bash "$SELF" __chain >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    if ! alive "$PIDF"; then   # a chain with nothing left to do ends within the 3 s
      e=$(tail -n +$((n0 + 1)) "$LOG" | grep 'CHAIN END' | tail -1)
      [ -n "$e" ] && { echo "nothing left to do: $e"; exit 0; }
      die "the chain did not start ($LOG)"
    fi
    if [ "$VARIANT" = g5 ] || [ "$VARIANT" = g6 ]; then echo "started: waits for the m2 traces ($(count_traced) of $NPROGS done), Q0m, then $NJOBS runs; log $LOG"
    else echo "started: $NPROGS programs to trace, then $NJOBS runs; log $LOG"; fi ;;
  __chain) chain ;;
  __trace) shift; if [ "$VARIANT" = nc ] || [ "$VARIANT" = nb ] || [ "$VARIANT" = h2 ]; then trace_nc "$1"; else trace_one "$1"; fi ;;
  __job)   shift; job "$@" ;;
  status)
    if [ "$VARIANT" = h2 ]; then
      echo "== sync h2 (held-out set 2: facesim's tracer, -start0): tracer $( [ -x "$TRACER" ] && md5sum < "$TRACER" | cut -c1-8 || echo 'not built'); gem5.cpuid $( [ -f "$W/gem5.cpuid" ] && md5sum < "$W/gem5.cpuid" | cut -c1-8 || echo none); QS $([ -f "$W/QS_PASSED" ] && echo passed || echo 'not passed'); QK $([ -f "$W/QK_PASSED" ] && echo passed || echo 'not passed'); QZ $([ -f "$W/QZ_PASSED" ] && echo passed || echo 'not passed'); counter $( [ -x "$COUNTER" ] && md5sum < "$COUNTER" | cut -c1-8 || echo 'not built'); QR $([ -f "$W/QR_PASSED" ] && echo passed || echo 'not passed')"
      if [ -d "$CW" ]; then      # Note 7's counter runs
        echo "== counter runs (Note 7): $(grep -l '^exit 0 ' "$CW"/runs/*/STATUS 2>/dev/null | wc -l) of 24 exited 0; running now $(pgrep -u "$(id -u)" -f "stream_count.so -o c" | wc -l); driver $(alive "$CW/.pid" && echo alive || echo 'not running')$([ -f "$CW/DONE" ] && echo "; DONE $(cat "$CW/DONE")")"
        grep -E 'QE-h2|FAILED|exit [1-9]|COUNT|did not|no c\.t|KNOBS|BROADCAST 0 lines' "$CW/driver.log" 2>/dev/null | tail -8 | sed 's/^/   /'
      fi
      if [ ! -f "$LOG" ]; then   # before Note 6's chain: the builds' checks; after it, the chain's lines below
        [ -f "$W/build_run.log" ] && grep -E 'FAILED|holds|QZ|Z[0-9]|built:|ERROR' "$W/build_run.log" | tail -20 | sed 's/^/   /'
        [ -f "$W/counter_run.log" ] && grep -E 'FAILED|holds|R[123] |built:|ERROR' "$W/counter_run.log" | tail -14 | sed 's/^/   /'
        echo "   tracing and runs (Note 6): not started -- heldout2_all.sh trace"; echo "   disk: $(free_gb) GB free"; exit 0
      fi
    fi
    case "$VARIANT" in "") what="synchronised replay" ;; mx) what="synchronised replay, mutex order by timing" ;; g5) what="step 3, the gem5-rule view, on the m2 traces" ;; g6) what="the gem5-rule view, amendment 2 (view-order split), on the m2 traces" ;; nb) what="the new benchmarks on the final tool" ;; nc) what="the new benchmarks traced with gem5's CPUID (F2)" ;; h2) what="held-out set 2 (Note 6)" ;; pol) what="step 5, the policy runs on the final tool" ;; esac
    echo "== sync${VARIANT:+ $VARIANT} ($what): traced $(count_traced) of $NPROGS programs; runs $(count_done) of $NJOBS complete; binary $(basename "$(bin_sync)" 2>/dev/null); Q0 $([ -f "$W/Q0_PASSED" ] && echo passed || echo 'not passed')$([ "$VARIANT" = mx ] && echo "; Q0b $([ -f "$W/Q0B_PASSED" ] && echo passed || echo 'not passed')")$( { [ "$VARIANT" = g5 ] || [ "$VARIANT" = g6 ]; } && echo "; Q0m $([ -f "$W/Q0M_PASSED" ] && echo passed || echo 'not yet')"); chain $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$LOG" ] && grep -E "FAILED|STOPPED|traced \(|CHAIN|Q0m|Q0-full|Q3|m2 traces|length rule" "$LOG" | tail -12 | sed 's/^/   /'
    echo "   disk: $(free_gb) GB free" ;;
  *) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
