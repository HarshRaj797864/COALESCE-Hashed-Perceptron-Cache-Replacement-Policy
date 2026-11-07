#!/usr/bin/env bash
# Report progress of a running or finished sweep.
#
#   scripts/check_progress.sh results/regime_shared/canneal/8core
#
# Also checks the thing that is easy to get silently wrong: whether the run
# actually used the regime it was supposed to. A shared-VMEM run must report a
# non-zero VMEM ALIASED FILLS; a private run must report zero.
set -uo pipefail

DIR="${1:-}"
[[ -n "$DIR" && -d "$DIR" ]] || { echo "usage: $0 <results-dir>" >&2; exit 2; }

want_shared=0
[[ "$DIR" == *regime_shared* ]] && want_shared=1

printf "%-24s %-12s %-14s %s\n" POLICY STATE PROGRESS "REGIME CHECK"
for log in "$DIR"/*.log; do
  [[ -f "$log" ]] || continue
  name=$(basename "$log" .log)

  if grep -q "ChampSim completed all CPUs" "$log" 2>/dev/null || grep -q "cumulative IPC" "$log" 2>/dev/null; then
    state="DONE"
    progress=$(grep -oP 'cumulative IPC: \K[0-9.]+' "$log" | tail -1)
    progress="IPC ${progress:-?}"
  elif grep -q "Heartbeat" "$log" 2>/dev/null; then
    state="RUNNING"
    instr=$(grep "Heartbeat" "$log" | tail -1 | grep -oP 'instructions: \K[0-9]+')
    progress="${instr:-0} instr"
  elif [[ -s "$log" ]]; then
    state="?"; progress=$(tail -c 60 "$log" | tr '\n' ' ')
  else
    state="PENDING"; progress="-"
  fi

  alias_line=$(grep -oP 'VMEM ALIASED FILLS.*?: \K[0-9]+' "$log" 2>/dev/null | tail -1)
  if [[ -z "$alias_line" ]]; then
    check="(not yet reported)"
  elif [[ $want_shared -eq 1 && "$alias_line" -gt 0 ]]; then
    check="ok: shared, ${alias_line} aliases"
  elif [[ $want_shared -eq 1 ]]; then
    check="!! WRONG REGIME: 0 aliases, overlay did not engage"
  elif [[ $want_shared -eq 0 && "$alias_line" -eq 0 ]]; then
    check="ok: private"
  else
    check="!! WRONG REGIME: ${alias_line} aliases in a private run"
  fi

  printf "%-24s %-12s %-14s %s\n" "$name" "$state" "$progress" "$check"
done
