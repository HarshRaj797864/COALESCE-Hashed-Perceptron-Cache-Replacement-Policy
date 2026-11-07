#!/usr/bin/env bash
# Cancel not-yet-started jobs in a LIVE run_phase_a.sh queue, without stopping
# or confusing its driver.
#
#   scp -P 2222 scripts/trim_queue.sh user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/trim_queue.sh plan'
#   ssh -n -p 2222 user@your-server 'EXPECT=12 bash ~/trim_queue.sh go'
#
# Defaults cancel the pre-fix COALESCE family at 4 and 16 cores in ~/.phase_a:
#   CANCEL_POLICIES="coalesce coalesce_no_mesi coalesce_no_sharer"  CANCEL_CORES="4 16"
#   KEEP_POLICIES   the policies a reboot-resume may run (default: the eight baselines)
#   FROZEN          where the sweep's binary is frozen
#   EXPECT          REQUIRED for go: how many jobs you mean to cancel. A wrong
#                   CANCEL_* setting would otherwise cancel the wrong jobs with
#                   nothing to say so -- the first test run of this script did
#                   exactly that, cancelling six not-yet-started 8-core jobs.
#
# WHY IN PLACE. The driver reads the queue file line by line through a file
# descriptor it holds open. Rewriting the file with a new length moves every
# byte after the edit, so the driver's next read lands mid-line. So each
# cancelled line keeps its exact length: its workload `canneal` becomes
# `skipped` (7 bytes each). The driver reaches the line, traces_for rejects an
# unknown workload, and it logs `SKIP ... unknown workload skipped` -- the
# cancellation is recorded in the run log by the driver itself. Only bytes past
# the driver's position change, and each edit is one small write.
#
# WHY IT ALSO FREEZES THE BINARY AND WRITES queue.env. Once the last job has
# launched, bin/champsim is rebuilt for the COALESCE relaunch. A reboot after
# that would resume this queue on the NEW binary, and the resume rebuilds the
# queue from scratch -- bringing the cancelled jobs back. So the binary the
# sweep is actually running is copied out of /proc/<pid>/exe of a live job (not
# from bin/champsim, which may already differ), and queue.env pins the resume to
# that copy and to KEEP_POLICIES. Read by run_phase_a.sh >= ce95b08, which must
# be installed with `mv` (see CLAUDE.md), never scp'd over the live file.
set -uo pipefail

R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
STATE="${STATE:-$HOME/.phase_a}"
Q="$STATE/queue.txt"
RUNLOG="$STATE/run.log"
CANCEL_POLICIES="${CANCEL_POLICIES:-coalesce coalesce_no_mesi coalesce_no_sharer}"
CANCEL_CORES="${CANCEL_CORES:-4 16}"
KEEP_POLICIES="${KEEP_POLICIES:-lru srrip drrip ship hawkeye mockingjay srrip_bias random}"
FROZEN="${FROZEN:-$S/bin/champsim_phaseA_20260923}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -s "$Q" ] || die "no queue at $Q"
[ -s "$RUNLOG" ] || die "no run log at $RUNLOG"

# The current queue's section of the run log: everything after the last QUEUE START.
cur_log() { local n; n=$(awk '/ QUEUE START/ {n = NR} END {print n + 0}' "$RUNLOG"); tail -n +"$((n > 0 ? n : 1))" "$RUNLOG"; }

# Targets: "lineno|offset_of_workload|pol|wl|cores|rg", computed on the bytes.
targets() {
  python3 - "$Q" "$CANCEL_POLICIES" "$CANCEL_CORES" << 'PY'
import sys
q, pols, cores = sys.argv[1], set(sys.argv[2].split()), set(sys.argv[3].split())
off = 0
with open(q, "rb") as f:
    for i, raw in enumerate(f, 1):
        line = raw.decode()
        f4 = line.rstrip("\n").split("|")
        if len(f4) == 4 and f4[0] in pols and f4[2] in cores and f4[1] == "canneal":
            print(f"{i}|{off + len(f4[0]) + 1}|{f4[0]}|{f4[1]}|{f4[2]}|{f4[3]}")
        off += len(raw)
PY
}

driver_pid() { local p; p=$(cat "$STATE/driver.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; }

check() {
  local t bad=0 n=0 ln off p w c r
  echo "== queue $Q ($(wc -l < "$Q") lines, $(stat -c %s "$Q") bytes) =="
  if [ -n "$(driver_pid)" ]; then echo "   driver alive (pid $(driver_pid))"; else echo "   !! no live driver -- nothing is reading this queue"; fi
  echo "== jobs to cancel =="
  while IFS='|' read -r ln off p w c r; do
    n=$((n + 1))
    local log="$S/results/phaseA$( [ "$STATE" = "$HOME/.phase_a" ] || echo "${STATE##*/.phase_a}")/regime_$r/${w}_${c}core/$p/run.log"
    # grep -c, not -q: under pipefail an early -q exit on a long log SIGPIPEs
    # the producer and would read an already-started job as not started.
    if [ "$(cur_log | grep -c " START $p $w ${c}c $r\$")" -gt 0 ]; then
      echo "   !! $p $w ${c}c $r -- ALREADY STARTED; cannot cancel"; bad=1
    elif [ -e "$log" ]; then
      echo "   !! $p $w ${c}c $r -- a log already exists ($log)"; bad=1
    else
      echo "   line $ln  $p $w ${c}c $r"
    fi
  done < <(targets)
  [ "$n" -gt 0 ] || { echo "   none -- already cancelled, or nothing matches"; return 2; }
  echo "   $n job(s)"
  return "$bad"
}

freeze() {
  local pid
  if [ -x "$FROZEN" ]; then echo "   frozen binary already present: $FROZEN"; return 0; fi
  # Any running job will do, but it can exit between being found and being
  # read, so try each until one copies AND still matches afterwards. Copy to a
  # temporary name and rename, so a half-written copy is never left as $FROZEN.
  local tmp="$FROZEN.part" got=""
  for pid in $(pgrep -u "$(id -u)" '^champsim$'); do
    cp "/proc/$pid/exe" "$tmp" 2>/dev/null && cmp -s "/proc/$pid/exe" "$tmp" && { got=$pid; break; }
  done
  [ -n "$got" ] || { rm -f "$tmp"; die "could not read the binary of any running champsim"; }
  chmod 755 "$tmp" && mv -f "$tmp" "$FROZEN" || die "cannot install $FROZEN"
  echo "   froze the running binary (pid $got) -> $FROZEN"
  if cmp -s "$FROZEN" "$S/bin/champsim"; then echo "   (identical to bin/champsim today)"
  else echo "   !! bin/champsim already DIFFERS from what the sweep runs -- the frozen copy is the right one"; fi
}

phase_plan() { check; echo; echo "plan only -- nothing changed. 'go' to apply."; }

phase_go() {
  [ -n "${EXPECT:-}" ] || die "set EXPECT=<number of jobs to cancel> -- run 'plan' first and read the list"
  check; local rc=$?
  [ "$rc" -eq 2 ] && return 0
  [ "$rc" -eq 0 ] || die "refusing: some target jobs have already started"
  local n; n=$(targets | wc -l)
  [ "$n" = "$EXPECT" ] || die "the plan lists $n job(s) but EXPECT=$EXPECT -- nothing changed"
  local before; before=$(stat -c %s "$Q")
  echo "== freezing the sweep's binary =="
  freeze
  echo "== cancelling in place =="
  local ln off p w c r
  while IFS='|' read -r ln off p w c r; do
    printf 'skipped' | dd of="$Q" bs=1 seek="$off" conv=notrunc status=none || die "write failed at line $ln"
  done < <(targets)
  [ "$(stat -c %s "$Q")" = "$before" ] || die "queue size changed ($before -> $(stat -c %s "$Q")) -- investigate before anything else"
  echo "   done; size unchanged ($before bytes). Now in the queue:"
  grep -n '|skipped|' "$Q" | sed 's/^/     /'
  echo "== pinning what a reboot-resume runs =="
  [ -f "$STATE/queue.env" ] && cp -p "$STATE/queue.env" "$STATE/queue.env.before_trim"
  local wl rg
  wl=$(awk -F'|' '$2 != "skipped" {print $2}' "$Q" | sort -u | tr '\n' ' ' | sed 's/ $//')
  rg=$(awk -F'|' '{print $4}' "$Q" | sort -u | tr '\n' ' ' | sed 's/ $//')
  {
    echo "WORKLOADS='$wl'"
    echo "REGIMES='$rg'"
    echo "PAPER_REPRO='1'"
    echo "ONLY_POLICIES='$KEEP_POLICIES'"
    echo "BIN='$FROZEN'"
    echo "MAKE_CONFIG_EXTRA=''"
  } > "$STATE/queue.env"
  sed 's/^/     /' "$STATE/queue.env"
  echo
  echo "The driver will log 'SKIP ... unknown workload skipped' when it reaches each line."
}

case "${1:-}" in
  plan) phase_plan ;;
  go)   phase_go ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
