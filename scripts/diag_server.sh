#!/usr/bin/env bash
# The bounded-view diagnosis on the server: build the binary in its own tree
# (bin/champsim is never touched), check it, and rerun every B3 configuration
# at level 2 with the extra, records-only counters.
# Pre-registered in bench/policy_sanity/b3_bounded_design_2026-10-17.md.
#
#   bash ~/diag_server.sh build    # ~/diag_build -> bin/champsim_diag_<md5>; guards; Q0
#   bash ~/diag_server.sh go       # the 12 runs, detached ($JOBS at a time)
#   bash ~/diag_server.sh status
#
# build: compiles the sources scripts/diag_all.sh uploaded to ~/diag_build,
#   against the main tree's vcpkg_installed (a symlink made here); runs the
#   three policy guards in that tree; copies the binary to the main tree as
#   bin/champsim_diag_<first 8 of md5>, named in ~/diag/BIN. Q0: it and
#   champsim_b3v4_69ebdcce print the same log on canneal_4t (1 M + 2 M; lru and
#   hawkeye; shared and private; levels 0 and 2), apart from the wall-clock
#   text and the two new BOUNDED-PROTOCOL lines. Nothing runs otherwise.
# go: LRU, shared, level 2, each B3 configuration as first run (same traces,
#   geometry and lengths) -> results/phaseA_b3_d2_<suffix>, which b3_rows.sh
#   and run_phase_a.sh rows read as they are.
set -uo pipefail
SELF="$(readlink -f "$0")"

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
CB="${CB:-$HOME/diag_build}"
W="${W:-$HOME/diag}"
REF="${REF:-$S/bin/champsim_b3v4_69ebdcce}"
JOBS="${JOBS:-12}"
DONE_MARKER="ChampSim completed all CPUs"
LOG="$W/driver.log"
PIDF="$W/.driver.pid"
MC="$CB/simulator/scripts/make_config.py"

# suffix | workload | cores | scaled (2 MB per core) | warm-up | measured | traces
JOBS_SPEC="${JOBS_SPEC:-ocean4|ocean|4|0|50000000|100000000|ocean
ocean4_scaled|ocean|4|1|50000000|100000000|ocean
canneal4|canneal|4|0|50000000|100000000|canneal
canneal4_scaled|canneal|4|1|50000000|100000000|canneal
canneal8|canneal|8|0|50000000|100000000|canneal
barnes4|barnes|4|0|50000000|100000000|barnes256
barnesstd4_start|barnes|4|0|0|37900000|barnesstd
barnesstd4_force|barnes|4|0|37900000|50000000|barnesstd
barnesstd4|barnes|4|0|37900000|100000000|barnesstd
radix4|radix|4|0|50000000|100000000|radix
waternsq4|waternsq|4|0|50000000|100000000|waternsq
fmm4|fmm|4|0|50000000|100000000|fmm}"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
die() { echo "ERROR: $*" >&2; exit 1; }
bin_diag() { cat "$W/BIN" 2>/dev/null; }

resolve_trace() {
  if [ -f "$1.champsimtrace" ]; then echo "$1.champsimtrace"; return 0; fi
  if [ -f "$1.champsimtrace.xz" ]; then echo "$1.champsimtrace.xz"; return 0; fi
  return 1
}
# the traces each B3 configuration was first run with
traces_for() {   # kind cores
  local k="$1" n="$2" i f out="" list=""
  case "$k" in
    ocean)     for i in 0 1 2 3; do list="$list $S/traces/ocean_4t/ocean$i"; done ;;
    canneal)   for ((i = 1; i <= n; i++)); do list="$list $S/traces/canneal_${n}t/canneal$i"; done ;;   # thread 0 loads the netlist
    barnes256) for i in 0 1 2 3; do list="$list $S/traces/barnes_4t$i"; done ;;
    barnesstd) list="$S/traces/barnes_std_4t/barnes0_aligned"; for i in 1 2 3; do list="$list $S/traces/barnes_std_4t/barnes$i"; done ;;
    radix|waternsq|fmm) list="$S/traces/${k}_4t/${k}0_aligned"; for i in 1 2 3; do list="$list $S/traces/${k}_4t/$k$i"; done ;;
    *) echo "MISSING:unknown kind $k"; return 1 ;;
  esac
  for f in $list; do out="$out $(resolve_trace "$f")" || { echo "MISSING:$f"; return 1; }; done
  echo "${out# }"
}
tree_of() { echo "phaseA_b3_d2_$1"; }
run_log() { echo "$S/results/$(tree_of "$1")/regime_shared/$2_$3core/lru/run.log"; }   # suffix wl cores
cfg_of() { echo "$W/cfg/$1.json"; }
is_done() { grep -q "$DONE_MARKER" "$(run_log "$1" "$2" "$3")" 2>/dev/null; }
count_done() { local n=0 suf wl c sc wu si k; while IFS='|' read -r suf wl c sc wu si k; do is_done "$suf" "$wl" "$c" && n=$((n + 1)); done <<< "$JOBS_SPEC"; echo "$n"; }

build() {
  mkdir -p "$W"
  [ -d "$CB/simulator/src" ] || die "no sources in $CB/simulator -- scripts/diag_all.sh uploads them"
  [ -d "$S/vcpkg_installed" ] || die "no $S/vcpkg_installed to build against"
  [ -e "$CB/simulator/vcpkg_installed" ] || ln -s "$S/vcpkg_installed" "$CB/simulator/vcpkg_installed"
  echo "== build in $CB/simulator (bin/champsim of the main tree is not touched)"
  ( cd "$CB/simulator" && rm -f absolute.options && make -j"$(nproc)" > "$W/build.log" 2>&1 ) || { tail -15 "$W/build.log"; die "the build failed ($W/build.log)"; }
  local n m
  n=$(strings -a "$CB/simulator/bin/champsim" | grep -c 'BOUNDED-PROTOCOL')
  [ "${n:-0}" -gt 0 ] || die "the new binary has no bounded-view counters"
  echo "== the three policy guards, in that tree"
  for g in check_include_path check_fill_hook check_signatures; do
    ( cd "$CB" && bash "bench/policy_sanity/$g.sh" ) > "$W/guard_$g.log" 2>&1 || { tail -5 "$W/guard_$g.log"; die "guard $g failed"; }
    echo "   $g: $(tail -1 "$W/guard_$g.log" | cut -c1-90)"
  done
  m=$(md5sum < "$CB/simulator/bin/champsim" | cut -c1-8)
  cp -p "$CB/simulator/bin/champsim" "$S/bin/champsim_diag_$m.tmp" && mv -f "$S/bin/champsim_diag_$m.tmp" "$S/bin/champsim_diag_$m"
  echo "$S/bin/champsim_diag_$m" > "$W/BIN"
  echo "   frozen as bin/champsim_diag_$m"
  q0
}

q0() {
  local B; B=$(bin_diag); [ -x "$B" ] || die "no diagnostic binary yet -- 'build'"
  [ -x "$REF" ] || die "no reference $REF"
  local Q="$W/q0" t c pol rg lv bad=0 n=0
  rm -rf "$Q"; mkdir -p "$Q"
  t=$(traces_for canneal 4) || die "${t#MISSING:}"
  echo "== Q0: every older log line, against $(basename "$REF"), canneal 4c, 1 M + 2 M"
  for pol in lru hawkeye; do for rg in shared private; do for lv in 0 2; do
    c="$Q/cfg_${pol}_${rg}_$lv.json"
    "$MC" --policy "$pol" --cores 4 --regime "$rg" --private-coherence "$lv" -o "$c" > /dev/null 2>&1 || die "make_config failed"
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$REF" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_ref.log" 2>&1 ) &
    # shellcheck disable=SC2086
    ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions 1000000 --simulation-instructions 2000000 $t > "$Q/${pol}_${rg}_${lv}_diag.log" 2>&1 ) &
  done; done; done
  wait
  for f in "$Q"/*_ref.log; do
    n=$((n + 1))
    grep -q "$DONE_MARKER" "$f" || { echo "   $(basename "$f"): did not complete"; bad=$((bad + 1)); continue; }
    # the lines that carry the wall clock also carry cycle counts: only the clock text goes
    if ! diff <(sed -E 's/\(Simulation time: [^)]*\)//' "$f") <(sed -E 's/\(Simulation time: [^)]*\)//' "${f%_ref.log}_diag.log" | grep -v 'BOUNDED-PROTOCOL') > /dev/null; then
      echo "   DIFFERS: $(basename "${f%_ref.log}")"; bad=$((bad + 1))
    fi
  done
  [ "$bad" = 0 ] || die "Q0 failed: $bad of $n pairs differ -- nothing is launched"
  echo "   Q0 holds: $n of $n pairs print every older line the same"
  echo ok > "$W/Q0_PASSED"
}

job() {   # suffix wl cores scaled warmup sim kind
  local suf="$1" wl="$2" n="$3" sc="$4" wu="$5" si="$6" k="$7" log t B c
  B=$(bin_diag); log=$(run_log "$suf" "$wl" "$n"); c=$(cfg_of "$suf")
  if is_done "$suf" "$wl" "$n"; then echo "$(date '+%F %T') SKIP  $suf (complete)"; return 0; fi
  t=$(traces_for "$k" "$n") || { echo "$(date '+%F %T') FAIL  $suf -- ${t#MISSING:}"; return 0; }
  mkdir -p "$(dirname "$log")" "$(dirname "$c")"
  # shellcheck disable=SC2046
  "$MC" --policy lru --cores "$n" --regime shared --private-coherence 2 $( [ "$sc" = 1 ] && echo --llc-per-core-mb 2 ) -o "$c" > /dev/null 2>&1 \
    || { echo "$(date '+%F %T') FAIL  $suf -- config"; return 0; }
  echo "$(date '+%F %T') START $suf ($wl ${n}c, $wu + $si)"
  # shellcheck disable=SC2086
  ( cd "$S" && nice -n 19 "$B" --config "$c" --warmup-instructions "$wu" --simulation-instructions "$si" $t > "$log" 2>&1 )
  echo "$(date '+%F %T') END   $suf rc=$? $(grep -c "$DONE_MARKER" "$log") complete"
}

driver() {
  echo $$ > "$PIDF"
  echo "$(date '+%F %T') QUEUE START (12 jobs, $(count_done) complete, $JOBS at a time, $(basename "$(bin_diag)"))"
  echo "$JOBS_SPEC" | tr '|' ' ' | xargs -P "$JOBS" -L 1 bash "$SELF" __job
  echo "$(date '+%F %T') QUEUE END: $(count_done) of 12 complete"
  rm -f "$PIDF"
}

case "${1:-}" in
  build) build ;;
  q0)    q0 ;;
  go)
    mkdir -p "$W"
    [ -f "$W/Q0_PASSED" ] || die "Q0 has not passed -- 'build' first"
    [ -x "$(bin_diag)" ] || die "no diagnostic binary"
    if alive "$PIDF"; then echo "already running (pid $(cat "$PIDF"))"; exit 0; fi
    while IFS='|' read -r suf wl c sc wu si k; do
      t=$(traces_for "$k" "$c") || die "$suf: ${t#MISSING:}"
    done <<< "$JOBS_SPEC"
    setsid bash "$SELF" __driver >> "$LOG" 2>&1 < /dev/null &
    disown 2>/dev/null; sleep 3
    alive "$PIDF" || [ "$(count_done)" = 12 ] || die "the driver did not start ($LOG)"
    echo "started: 12 jobs, $(count_done) complete, $JOBS at a time; log $LOG" ;;
  __driver) driver ;;
  __job)    shift; job "$@" ;;
  status)
    echo "== diag (bounded view): $(count_done) of 12 complete; binary $(basename "$(bin_diag)" 2>/dev/null); Q0 $([ -f "$W/Q0_PASSED" ] && echo passed || echo 'not passed'); driver $(alive "$PIDF" && echo alive || echo 'not running')"
    [ -f "$LOG" ] && tail -3 "$LOG" | sed 's/^/   /' ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
