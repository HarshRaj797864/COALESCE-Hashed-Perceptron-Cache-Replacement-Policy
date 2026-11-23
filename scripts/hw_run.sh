#!/usr/bin/env bash
# D (bench/policy_sanity/hw_direction_design_2026-11-18.md): runs on the i7, not on the laptop or the server.
#
#   bash hw_run.sh record                 # the machine, before any count: lscpu, cpuinfo, kernel, perf, perf list, paranoid, SMT, caches, governor, libc
#   bash hw_run.sh cpus                   # which logical CPUs the runs use (one per physical core, P-cores only, SMT siblings left idle)
#   bash hw_run.sh qh EVENTS              # QH: the micro program (BARRIER_STEPS) under perf stat, cases x {20000, 40000} rounds x 5
#   bash hw_run.sh progs EVENTS PROGS     # only after QH holds (out/QH_HELD, written by hw_score.py qh): each program x 10, shuffled once
#
# EVENTS (written in part 2 for the model, nothing chosen by values):  key=perf-event   one a line, keys
#   inst  rfo_hitm  rfo_clean  ld_hitm         e.g.  rfo_hitm=cpu_core/ocr.demand_rfo.l3_hit.snoop_hitm/u
# PROGS:  name|anchor_n|dir|stdin|command...   run in dir (relative to this script's directory unless absolute), stdin from
#         the file named (empty: /dev/null); anchor_n = the pthread_create after which counting starts, which must be the last
#
# Everything goes under OUT (default ./hw_out), plain text, brought back as it is.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUT="${OUT:-$PWD/hw_out}"
NT=4
SEED=20261118
die() { echo "STOPPED: $*" >&2; exit 1; }
mkdir -p "$OUT"

record() {
  local m="$OUT/machine"; mkdir -p "$m"
  lscpu > "$m/lscpu.txt" 2>&1
  lscpu -p=CPU,CORE,SOCKET,NODE > "$m/lscpu_p.txt" 2>&1
  grep -m1 -E '^model name' /proc/cpuinfo > "$m/model.txt"
  grep -m1 -E '^(cpu family|model|stepping|microcode)' /proc/cpuinfo > /dev/null
  awk -F': ' '/^(cpu family|model|stepping|microcode)[[:space:]]*:/ && !seen[$1]++ { print $1 ": " $2 }' /proc/cpuinfo >> "$m/model.txt"
  uname -a > "$m/kernel.txt"
  perf --version > "$m/perf_version.txt" 2>&1
  perf list --no-desc > "$m/perf_list.txt" 2>&1
  perf list > "$m/perf_list_desc.txt" 2>&1
  cat /proc/sys/kernel/perf_event_paranoid > "$m/paranoid.txt" 2>&1
  cat /sys/devices/system/cpu/smt/control > "$m/smt.txt" 2>&1
  for c in /sys/devices/system/cpu/cpu0/cache/index*; do echo "$(cat "$c/level") $(cat "$c/type") $(cat "$c/size") $(cat "$c/ways_of_associativity")-way"; done > "$m/caches.txt" 2>&1
  [ -r /sys/devices/cpu_core/cpus ] && echo "cpu_core $(cat /sys/devices/cpu_core/cpus)" > "$m/hybrid.txt"
  [ -r /sys/devices/cpu_atom/cpus ] && echo "cpu_atom $(cat /sys/devices/cpu_atom/cpus)" >> "$m/hybrid.txt"
  cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c > "$m/governor.txt"
  ldd --version 2>&1 | head -1 > "$m/libc.txt"
  gcc --version 2>&1 | head -1 > "$m/gcc.txt"
  uptime > "$m/uptime.txt"
  echo "recorded: $m ($(cat "$m/model.txt" | head -1))"
}

expand() {   # "0-3,8,10-11" -> one a line
  echo "$1" | tr ',' '\n' | while IFS=- read -r a b; do [ -n "$a" ] || continue; seq "$a" "${b:-$a}"; done
}

cpus() {   # the first logical CPU of each physical core, P-cores only, core 0 left out when there are more than NT cores
  local allowed
  if [ -r /sys/devices/cpu_core/cpus ]; then allowed=$(expand "$(cat /sys/devices/cpu_core/cpus)"); else allowed=$(lscpu -p=CPU | grep -v '^#'); fi
  local pick
  pick=$(lscpu -p=CPU,CORE,SOCKET | grep -v '^#' | awk -F, -v a="$(echo $allowed)" '
    BEGIN { n = split(a, x, " "); for (i = 1; i <= n; i++) ok[x[i]] = 1 }
    ok[$1] && $3 == 0 && !(($2) in seen) { seen[$2] = $1; order[++k] = $2 }
    END { for (i = 1; i <= k; i++) print seen[order[i]] }')
  local n; n=$(echo "$pick" | grep -c .)
  [ "$n" -ge "$NT" ] || die "only $n physical P-cores on socket 0; $NT needed"
  if [ "$n" -gt "$NT" ]; then pick=$(echo "$pick" | tail -n +2); fi
  echo "$pick" | head -n "$NT" | paste -sd, -
}

events_arg() {   # EVENTS file -> "-e a -e b ..." in key order inst rfo_hitm rfo_clean ld_hitm (missing keys are skipped)
  local f="$1" k v
  for k in inst rfo_hitm rfo_clean ld_hitm; do
    v=$(awk -F= -v k="$k" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$f")
    [ -n "$v" ] && printf -- '-e %s ' "$v"
  done
}

check_perf() {
  local p; p=$(cat "${HW_PARANOID_FILE:-/proc/sys/kernel/perf_event_paranoid}")   # HW_PARANOID_FILE: rehearsals only
  [ "$p" -le 0 ] || die "perf_event_paranoid is $p: offcore events need <= 0 (sudo sysctl kernel.perf_event_paranoid=0, for the session)"
  perf stat -x, -e instructions:u -- true > /dev/null 2>&1 || die "perf stat does not run"
}

qh() {
  local ev="$1"; [ -s "$ev" ] || die "no EVENTS file $ev"
  check_perf
  local cpu; cpu=$(cpus) || exit 1
  local d="$OUT/qh"; mkdir -p "$d"
  cp "$ev" "$d/EVENTS"; echo "$cpu" > "$d/CPUS"
  gcc -O2 -DBARRIER_STEPS -o "$d/coherence_micro" "$HERE/coherence_micro.c" -lpthread || die "the micro does not build"
  md5sum "$HERE/coherence_micro.c" "$d/coherence_micro" > "$d/MD5"
  local args; args=$(events_arg "$ev")
  local c r k
  for k in 1 2 3 4 5; do
    for c in pp_store pp_lock pp_rmw readers ctl none4 none3; do
      for r in 20000 40000; do
        perf stat -x, $args -o "$d/${c}_r${r}_${k}.csv" -- taskset -c "$cpu" "$d/coherence_micro" "$c" "$r" > "$d/${c}_r${r}_${k}.out" 2>&1 \
          || echo "FAILED $c $r $k" >> "$d/FAILURES"
      done
    done
    echo "$(date '+%F %T') QH repeat $k of 5 done"
  done
  echo "QH runs done: $d. Judge: python3 hw_score.py qh $d   (it writes $OUT/QH_HELD if QH holds)"
}

progs() {
  local ev="$1" pf="$2"; [ -s "$ev" ] && [ -s "$pf" ] || die "usage: progs EVENTS PROGS"
  [ -f "$OUT/QH_HELD" ] || die "QH has not held (no $OUT/QH_HELD): no program is counted"
  check_perf
  local cpu; cpu=$(cpus) || exit 1
  local d="$OUT/progs"; mkdir -p "$d"
  cp "$ev" "$d/EVENTS"; cp "$pf" "$d/PROGS"; echo "$cpu" > "$d/CPUS"
  local shim="$d/hw_anchor_shim.so"
  gcc -O2 -fPIC -shared -Wl,--as-needed -o "$shim" "$HERE/hw_anchor_shim.c" -ldl -lpthread || die "the shim does not build"
  # the programs run on the libraries they were traced with (libs/: the server's loader and libraries), through that loader
  local pre=()
  if [ -e "$HERE/libs/ld-linux-x86-64.so.2" ]; then pre=("$HERE/libs/ld-linux-x86-64.so.2" --library-path "$HERE/libs"); fi
  echo "${pre[*]:-system loader and libraries}" > "$d/LOADER"
  local args; args=$(events_arg "$ev")
  # the order: every (program, repeat) pair, shuffled once with the fixed seed, written down before the first run
  if [ ! -s "$d/ORDER" ]; then
    awk -F'|' '!/^#/ && NF >= 5 { for (k = 1; k <= 10; k++) print $1 "|" k }' "$pf" | shuf --random-source=<(yes "$SEED") > "$d/ORDER"
  fi
  local name k line n dir in cmd o
  while IFS='|' read -r name k; do
    o="$d/${name}_${k}"
    [ -s "$o.csv" ] && grep -q 'HW_ANCHOR enabled' "$o.err" 2>/dev/null && continue
    line=$(awk -F'|' -v n="$name" '$1 == n { print; exit }' "$pf")
    n=$(echo "$line" | cut -d'|' -f2); dir=$(echo "$line" | cut -d'|' -f3); in=$(echo "$line" | cut -d'|' -f4); cmd=$(echo "$line" | cut -d'|' -f5-)
    case "$dir" in /*) ;; *) dir="$HERE/$dir" ;; esac
    rm -f "$d/ctl" "$d/ack"; mkfifo "$d/ctl" "$d/ack"
    # the shim goes to the program only (through env), never to perf or taskset
    ( cd "$dir" && perf stat -x, $args --delay=-1 --control="fifo:$d/ctl,$d/ack" -o "$o.csv" -- \
        taskset -c "$cpu" env HW_CTL_FIFO="$d/ctl" HW_ACK_FIFO="$d/ack" HW_ANCHOR_N="$n" LD_PRELOAD="$shim" ${pre[@]+"${pre[@]}"} $cmd < "${in:-/dev/null}" > "$o.out" 2> "$o.err" ) \
      || echo "FAILED $name $k" >> "$d/FAILURES"
    grep -q 'HW_ANCHOR enabled' "$o.err" || echo "NO ANCHOR $name $k" >> "$d/FAILURES"
    echo "$(date '+%F %T') $name repeat $k done"
  done < "$d/ORDER"
  echo "program runs done: $d. Score on the laptop: python3 scripts/hw_score.py progs $d"
}

case "${1:-}" in
  record) record ;;
  cpus) cpus ;;
  qh) qh "${2:-}" ;;
  progs) progs "${2:-}" "${3:-}" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
