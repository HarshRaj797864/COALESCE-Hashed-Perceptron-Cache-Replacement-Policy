#!/usr/bin/env bash
# Why did runs wrap their traces when the preflight said the traces were long
# enough? Read-only; starts nothing.
#
#   scp -P 2222 scripts/diagnose_wraps.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/diagnose_wraps.sh traces'
#   ssh -p 2222 user@your-server 'bash ~/diagnose_wraps.sh runs'
#   ssh -p 2222 user@your-server 'bash ~/diagnose_wraps.sh' > wrap_diagnosis.txt
#
# THE PREFLIGHT IS NOT WRONG ABOUT THE FILES, IT IS WRONG ABOUT THE REQUIREMENT.
# run_phase_a.sh's check_trace_length refuses any trace with fewer than
# WARMUP+SIM = 150M records, and it checks every file, not a sample. Yet water
# (200M records) and ocean (172M) both wrapped at 8 cores.
#
# champsim.cc:141 sets a CPU's phase-complete flag when sim_instr() >= length,
# but the phase does not end until EVERY CPU's flag is set, and an already-
# finished CPU keeps being ticked in the meantime. So the fastest core keeps
# consuming trace while it waits for the slowest. The trace a core must supply
# is not WARMUP+SIM, it is WARMUP+SIM scaled by how far that core outruns the
# laggard -- which is a property of the workload, not something a file size can
# be checked against in advance.
#
# This script measures that scaling factor from logs that already exist, so the
# preflight can be given a real margin instead of a guessed one.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
T="$S/traces"
NOMINAL="${NOMINAL:-150000000}"     # what check_trace_length currently demands

# Per-file record counts for a set. The point is the SPREAD: a status line that
# samples one file and prints "records each" cannot show it.
phase_traces() {
  echo "== trace files, per file, not sampled =="
  printf '   %-16s %5s %14s %14s %14s\n' set files min max spread
  local d name files n lo hi r f
  for d in "$T"/*/ ; do
    [ -d "$d" ] || continue
    name=$(basename "$d"); [ "$name" = spec ] && continue
    files=$(find "$d" -maxdepth 1 \( -name '*.champsimtrace' -o -name '*.champsimtrace.xz' \) 2>/dev/null | sort)
    n=$(echo "$files" | grep -c .); [ "$n" -eq 0 ] && continue
    lo=""; hi=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        *.xz) r=$(( $(xz --robot -l "$f" 2>/dev/null | awk -F'\t' '$1=="totals"{print $5}') / 64 )) ;;
        *)    r=$(( $(stat -c %s "$f") / 64 )) ;;
      esac
      [ -z "$lo" ] && { lo=$r; hi=$r; }
      [ "$r" -lt "$lo" ] && lo=$r
      [ "$r" -gt "$hi" ] && hi=$r
    done <<< "$files"
    printf '   %-16s %5s %14s %14s %13s%%\n' "$name" "$n" "$lo" "$hi" \
      "$(( lo > 0 ? (hi - lo) * 100 / lo : 0 ))"
  done
  echo
  echo "   check_trace_length demands $NOMINAL per file."
}

# For one log: what each CPU actually consumed, warmup phase plus sim phase.
#
# champsim.cc prints "<phase> finished CPU n instructions: i ..." the cycle a
# core hits its target and "<phase> complete CPU n instructions: i ..." at the
# end of the phase. The second is the one that counts -- for a fast core it is
# larger, because it kept running while the slow cores caught up.
run_consumption() {
  local log="$1"
  awk '
    /complete CPU [0-9]+ instructions:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "CPU") cpu = $(i+1)
        if ($i == "instructions:") ins = $(i+1)
      }
      total[cpu] += ins
    }
    END {
      lo = -1; hi = 0; n = 0
      for (c in total) {
        n++
        if (lo < 0 || total[c] < lo) lo = total[c]
        if (total[c] > hi) hi = total[c]
      }
      if (n > 0) printf "%d %d %d\n", n, lo, hi
    }
  ' "$log"
}

phase_runs() {
  echo "== runs that wrapped, and what they actually consumed =="
  printf '   %-46s %4s %14s %14s %7s\n' run cpus 'min consumed' 'max consumed' 'vs 150M'
  local d log rel n lo hi worst=0 nwrap=0 ntot=0
  for d in "$S"/results/phaseA*/ ; do
    [ -d "$d" ] || continue
    while IFS= read -r log; do
      [ -s "$log" ] || continue
      ntot=$((ntot + 1))
      grep -q "Reached end of trace" "$log" || continue
      nwrap=$((nwrap + 1))
      rel=${log#"$S/results/"}; rel=${rel%/run.log}
      read -r n lo hi <<< "$(run_consumption "$log")"
      [ -z "${n:-}" ] && { printf '   %-46s %4s %14s\n' "$rel" "?" "(no phase lines -- died early)"; continue; }
      printf '   %-46s %4s %14s %14s %6s%%\n' "$rel" "$n" "$lo" "$hi" \
        "$(( hi * 100 / NOMINAL ))"
      [ "$hi" -gt "$worst" ] && worst=$hi
    done < <(find "$d" -name run.log 2>/dev/null | sort)
  done
  echo
  echo "   $nwrap of $ntot logs wrapped."
  if [ "$worst" -gt 0 ]; then
    echo "   Worst core consumed $worst records against the $NOMINAL demanded --"
    echo "   a margin of $(( worst * 100 / NOMINAL ))%, i.e. check_trace_length needs"
    echo "   roughly $(( (worst + 9999999) / 10000000 * 10000000 )) to be safe for this workload mix."
  fi
}

# The same measurement on runs that did NOT wrap: how far does the fastest core
# outrun the slowest when there is enough trace to absorb it? That ratio is the
# real margin the preflight is missing, and it can only be seen on healthy runs.
phase_margin() {
  echo "== core divergence on runs that did NOT wrap =="
  printf '   %-46s %4s %14s %14s %8s\n' run cpus 'min consumed' 'max consumed' 'max/min'
  local d log rel n lo hi
  for d in "$S"/results/phaseA*/ ; do
    [ -d "$d" ] || continue
    while IFS= read -r log; do
      [ -s "$log" ] || continue
      grep -q "ChampSim completed all CPUs" "$log" 2>/dev/null || continue
      grep -q "Reached end of trace" "$log" && continue
      read -r n lo hi <<< "$(run_consumption "$log")"
      [ -z "${n:-}" ] && continue
      [ "${n:-0}" -lt 2 ] && continue
      rel=${log#"$S/results/"}; rel=${rel%/run.log}
      printf '   %-46s %4s %14s %14s %7s.%02dx\n' "$rel" "$n" "$lo" "$hi" \
        "$(( hi / (lo > 0 ? lo : 1) ))" "$(( lo > 0 ? (hi * 100 / lo) % 100 : 0 ))"
    done < <(find "$d" -name run.log 2>/dev/null | sort)
  done
  echo
  echo "   max/min is how far the fastest core outruns the slowest. The trace"
  echo "   each core needs is WARMUP+SIM times that ratio, so this column is the"
  echo "   multiplier check_trace_length is currently missing."
}

case "${1:-all}" in
  traces) phase_traces ;;
  runs)   phase_runs ;;
  margin) phase_margin ;;
  all)    phase_traces; echo; phase_runs; echo; phase_margin ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
