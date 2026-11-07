#!/usr/bin/env bash
# One read-only report of everything happening on the server.
#
#   scp -P 2222 scripts/server_status.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/server_status.sh'
#
# Completion is counted by grepping logs for ChampSim's end marker, never by
# counting launches. 'started: 15, finished: 0' looked like a queue failure on
# 2026-09-17 when it was a machine crash -- launches say nothing about survival.
#
# It also checks the three ways a run can be silently invalid:
#   vmem page-pool exhaustion  -> recycled pages fabricate aliasing
#   trace wrap                 -> a short trace is reopened, replaying itself
#   trace too short to start   -> would wrap, caught before launching
set +e

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
T="$S/traces"
DONE="ChampSim completed all CPUs"

hr() { printf '\n%s\n' "============================================================"; }
# pgrep -fc prints 0 AND exits 1 when nothing matches, so `|| echo 0` appends a
# second zero. Take the first line and nothing else.
n_proc() { pgrep -fc "$1" 2>/dev/null | head -1; }
# champsim is counted by process NAME. Matching the command line also counts any
# shell whose text mentions bin/champsim -- the relaunch commands name
# BIN=.../bin/champsim_armB -- and the arm binaries are champsim_armA/B, which a
# name match still catches.
n_champsim() { pgrep ${1:+-u "$1"} -c '^champsim' 2>/dev/null | head -1; }

echo "server_status  $(date '+%F %T')    up since $(uptime -s 2>/dev/null)"

hr
echo "PROCESSES"
printf '   champsim (ours/all) : %s / %s\n' "$(n_champsim "$(id -u)")" "$(n_champsim)"
printf '   phase-A workers     : %s  (1 driver + its job subshells, which share argv)\n' "$(n_proc '[r]un_phase_a.sh __worker')"
printf '   A4 workers          : %s\n' "$(n_proc '[r]un_a4.sh __worker')"
printf '   pin tracer          : %s\n' "$(n_proc '[c]hampsim_tracer')"
printf '   spec download       : %s\n' "$(n_proc '[g]et_spec_traces.sh __download')"
echo
# Who owns the champsim processes. This machine is shared -- another account was
# running its own champsim on 2026-09-22 -- and an unscoped count conflates
# theirs with ours, which matters both for reading load and because the sweep's
# busy-guard used to block on them.
echo "   champsim by user:"
ps -eo user=,comm= 2>/dev/null | awk '$2 ~ /^champsim/ {c[$1]++} END {
    n = 0
    for (u in c) { printf "     %-16s %s\n", u, c[u]; n++ }
    if (n == 0) print "     (none)"
}'
echo
echo "   our jobs, in detail:"
mypid=$(pgrep -u "$(id -u)" '^champsim' 2>/dev/null | head -20 | tr '\n' ',' | sed 's/,$//')
if [ -n "$mypid" ]; then
  ps -o etime=,pcpu=,rss=,args= -p "$mypid" 2>/dev/null \
    | sed 's#--config [^ ]*/cfg_#cfg #; s#--warmup-instructions#w#; s#--simulation-instructions#s#; s#[^ ]*/traces/#### ' \
    | awk '{rss=$3/1048576; $3=sprintf("%.1fGB", rss); print}' | cut -c1-140 | sed 's/^/     /'
else
  echo "     (none)"
fi
echo
echo "   longest-running jobs (all users):"
pids=$(pgrep '^champsim' 2>/dev/null | head -30 | tr '\n' ',' | sed 's/,$//')
[ -n "$pids" ] && ps -o etime=,pcpu=,args= -p "$pids" 2>/dev/null \
  | sed 's#.*--config [^ ]*/cfg_#cfg #; s#--warmup-instructions#w#; s#--simulation-instructions#s#' \
  | cut -c1-110 | sort -r | head -8 | sed 's/^/     /'
[ -z "$pids" ] && echo "     none"

# Every phaseA* tree, so a go-tag relaunch (phaseA_<tag>) shows up here.
for d in "$S/results/phaseA" "$S"/results/phaseA_*; do
  [ -d "$d" ] || continue
  variant="${d##*/phaseA}"
  hr
  echo "SWEEP: phaseA$variant"
  tot=$(find "$d" -name run.log 2>/dev/null | wc -l)
  fin=$(grep -rl "$DONE" "$d" --include=run.log 2>/dev/null | wc -l)
  printf '   whole tree -- logs: %-4s  verified complete: %s\n' "$tot" "$fin"
  # The tree holds every queue ever run into it; progress means the CURRENT
  # queue, read from its queue file (pol|wl|cores|regime) against the log layout.
  q="$HOME/.phase_a$variant/queue.txt"
  if [ -s "$q" ]; then
    qd=0; qt=0
    while IFS='|' read -r qp qw qc qr; do
      qt=$((qt + 1))
      grep -q "$DONE" "$d/regime_$qr/${qw}_${qc}core/$qp/run.log" 2>/dev/null && qd=$((qd + 1))
    done < "$q"
    lk="$HOME/.phase_a$variant/driver.pid"
    if [ -f "$lk" ] && kill -0 "$(cat "$lk" 2>/dev/null)" 2>/dev/null; then dr="driver alive"; else dr="no driver"; fi
    printf '   this queue -- verified complete: %s / %s   (%s)\n' "$qd" "$qt" "$dr"
  fi
  lp=$(grep -rl "Reached end of trace" "$d" --include=run.log 2>/dev/null | wc -l)
  ex=$(grep -rl "Out of physical memory" "$d" --include=run.log 2>/dev/null | wc -l)
  [ "$lp" -gt 0 ] && echo "   !! $lp run(s) WRAPPED their trace -- those results replay the same instructions:" \
    && grep -rl "Reached end of trace" "$d" --include=run.log 2>/dev/null | sed "s|$d/||;s|/run.log||" | sort | head -8 | sed 's/^/        /'
  [ "$ex" -gt 0 ] && echo "   !! $ex run(s) EXHAUSTED the page pool -- recycled pages fabricate aliasing"
  [ "$lp" -eq 0 ] && [ "$ex" -eq 0 ] && echo "   no wrapped traces, no page-pool exhaustion"
  sl="$HOME/.phase_a$variant/run.log"
  [ -f "$sl" ] && { echo "   last 3 events:"; tail -3 "$sl" | sed 's/^/     /'; }
done

if [ -d "$S/results/bias_probe" ]; then
  hr
  echo "BIAS PROBE (coalesce victim-vs-candidate measurement)"
  bl="$S/results/bias_probe/run.log"
  if [ -s "$bl" ]; then
    if grep -q "$DONE" "$bl" 2>/dev/null; then
      echo "   complete"
      grep "BIAS EXPOSURE" "$bl" 2>/dev/null | sed 's/^/   /'
    else
      echo "   running or failed -- last line:"
      tail -1 "$bl" | cut -c1-100 | sed 's/^/     /'
    fi
  else
    echo "   not started"
  fi
fi

# results/a4 and the A/B arms (a4_armA, a4_armB), each against its own queue.
for d in "$S/results/a4" "$S"/results/a4_*; do
  [ -d "$d" ] || continue
  name=$(basename "$d"); q="$HOME/.$name/queue.txt"
  hr
  echo "A4 single-core validation: $name"
  printf '   logs started: %-4s  verified complete: %s / %s\n' \
    "$(find "$d" -name run.log 2>/dev/null | wc -l)" \
    "$(grep -rl "$DONE" "$d" --include=run.log 2>/dev/null | wc -l)" \
    "$([ -f "$q" ] && wc -l < "$q" || echo '?')"
done

hr
echo "TRACES  (50M+100M needs 150,000,000 records per core -- NECESSARY, NOT SUFFICIENT)"

# Report the SHORTEST file in each set, not a sample of one.
#
# This used to read one file and print its count as "records each". The files
# in a set are not equal, and it is the shortest that decides whether a job
# wraps, so a sampled figure could call a set ok while a member of it was too
# short to run.
#
# Even the minimum only settles the necessary condition. On 2026-09-21 water
# (200M records per file) and ocean (172M) both wrapped at 8 cores anyway:
# champsim.cc:141 keeps ticking a core that has hit its instruction target
# until every other core catches up, so the fastest core consumes far more than
# WARMUP+SIM. See scripts/diagnose_wraps.sh for the measured margin.
records_minmax() {   # $1 = glob-able file list on stdin; prints "min max"
  local f r lo="" hi=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *.xz) r=$(( $(xz --robot -l "$f" 2>/dev/null | awk -F'\t' '$1=="totals"{print $5}') / 64 )) ;;
      *)    r=$(( $(stat -c %s "$f" 2>/dev/null) / 64 )) ;;
    esac
    [ -z "$lo" ] && { lo=$r; hi=$r; }
    [ "$r" -lt "$lo" ] && lo=$r
    [ "$r" -gt "$hi" ] && hi=$r
  done
  echo "${lo:-0} ${hi:-0}"
}

for d in "$T"/*/ ; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  [ "$name" = "spec" ] && continue
  files=$(find "$d" -maxdepth 1 \( -name '*.champsimtrace' -o -name '*.champsimtrace.xz' \) 2>/dev/null | sort)
  [ -n "$files" ] || continue
  read -r lo hi <<< "$(echo "$files" | records_minmax)"
  cnt=$(echo "$files" | grep -c .)
  if [ "$lo" -ge 150000000 ]; then verdict="len ok"; else verdict="TOO SHORT -- would wrap $(( 150000000 / (lo > 0 ? lo : 1) ))x"; fi
  [ "$lo" != "$hi" ] && verdict="$verdict (uneven)"
  printf '   %-18s %2s files  min %12s  max %12s  %8s  %s\n' \
    "$name" "$cnt" "$lo" "$hi" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$verdict"
done
bfiles=$(find "$T" -maxdepth 1 -name 'barnes_4t*.champsimtrace*' 2>/dev/null | sort)
if [ -n "$bfiles" ]; then
  read -r lo hi <<< "$(echo "$bfiles" | records_minmax)"
  printf '   %-18s %2s files  min %12s  max %12s  %8s  %s\n' "barnes_4t" \
    "$(echo "$bfiles" | grep -c .)" "$lo" "$hi" \
    "$(du -ch "$T"/barnes_4t*.champsimtrace* 2>/dev/null | tail -1 | cut -f1)" \
    "$([ "$lo" -ge 150000000 ] && echo 'len ok' || echo 'TOO SHORT')"
fi
printf '   %-18s %2s files  %25s  %8s\n' "spec (A4)" \
  "$(find "$T/spec" -name '*.xz' 2>/dev/null | wc -l)" "single-core" "$(du -sh "$T/spec" 2>/dev/null | cut -f1)"

hr
echo "MACHINE"
uptime | sed 's/^/   /'
free -g | head -2 | sed 's/^/   /'
df -h /home | tail -1 | sed 's/^/   /'
