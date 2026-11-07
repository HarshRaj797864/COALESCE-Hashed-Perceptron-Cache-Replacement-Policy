#!/usr/bin/env bash
# A4 -- single-core baseline validation.
#
#   scp -P 2222 scripts/run_a4.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh plan'
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh go'
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh status'
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh results'
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh check'
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh rows' > a4_rows.txt
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh inflation'
#
# WHY THIS EXISTS. Both HiPC reviewers disbelieved the Hawkeye and Mockingjay
# numbers, and the filed rebuttal promised single-core baseline validation for
# the camera-ready. The Sept rebuttal validated on ONE usable trace: the other,
# 600.perlbench, returned byte-identical results for all four policies because
# it never touches the LLC. n=1 is not a validation harness.
#
# It is also the only real test that the nine rewritten policies are correct.
# The three guards in bench/policy_sanity check STRUCTURE -- that a fill hook
# exists, that find_victim matches a dispatchable overload, that headers come
# from this tree. A policy can pass all three and implement the wrong algorithm.
# That is exactly what happened: Hawkeye was byte-identical to SRRIP, same IPC
# to four figures and the same cycle count, and every structural check passed.
#
# REPORT LOAD HIT RATE, NOT TOTAL. On 429.mcf the total LLC hit rate reads
# LRU 28.1% against Hawkeye 8.7% -- inverted -- purely because LRU hits 99.9%
# of L2 writebacks while everyone else hits ~2%. Load hit rate tells the true
# story (LRU 1.7%, SRRIP 12.6%, Hawkeye 12.4%). A reviewer pulling total hit
# rate out of our logs would conclude the validation is broken.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"
TRACES="$S/traces/spec"

# ARM=A|B selects one arm of the COALESCE A/B built by ab_build.sh: its binary,
# the three COALESCE policies, and a state and results tree of its own. Rows it
# prints are labelled policy@ARM, the form `run_a4.sh.py ab` reads. Anything set
# explicitly still wins. Without this every A/B command was a line of four
# hand-typed paths, which is where a copy-paste slip lands silently.
if [ -n "${ARM:-}" ]; then
  case "$ARM" in A|B) ;; *) echo "ERROR: ARM must be A or B" >&2; exit 1 ;; esac
  : "${STATE:=$HOME/.a4_arm$ARM}" "${RESULTS:=$S/results/a4_arm$ARM}" "${BIN:=$S/bin/champsim_arm$ARM}"
  : "${POLICIES:=coalesce coalesce_no_mesi coalesce_no_sharer}"
fi
STATE="${STATE:-$HOME/.a4}"
QUEUE="${QUEUE:-$STATE/queue.txt}"
RUNLOG="${RUNLOG:-$STATE/run.log}"
LOCK="${LOCK:-$STATE/driver.pid}"
RESULTS="${RESULTS:-$S/results/a4}"
# Which binary to run. Overridable so an A/B can run two builds side by side
# into separate RESULTS trees without touching bin/champsim -- see ab_build.sh.
BIN="${BIN:-$S/bin/champsim}"

# Long enough to warm a 2 MB LLC and measure steady state; short enough that
# 132 runs finish. Override for a publication-grade pass.
WARMUP="${WARMUP:-50000000}"
SIM="${SIM:-50000000}"
# The machine is shared and already running the Phase A sweep. Keep this low
# and raise it once the sweep drains.
MAXJOBS="${MAXJOBS:-6}"

DONE_MARKER="ChampSim completed all CPUs"

POLICIES="${POLICIES:-lru srrip drrip ship hawkeye mockingjay srrip_bias random coalesce coalesce_no_mesi coalesce_no_sharer}"

die() { echo "ERROR: $*" >&2; exit 1; }

trace_list() { find "$TRACES" -maxdepth 1 -name '*.champsimtrace.xz' 2>/dev/null | sort; }
short_name() { basename "$1" | sed 's/\.champsimtrace\.xz$//'; }

job_dir() { echo "$RESULTS/$2/$1"; }          # $1=policy $2=trace
job_log() { echo "$(job_dir "$1" "$2")/run.log"; }
job_done() { [ -s "$(job_log "$1" "$2")" ] && grep -q "$DONE_MARKER" "$(job_log "$1" "$2")" 2>/dev/null; }

build_queue() {
  mkdir -p "$STATE"; : > "$QUEUE"
  local t p
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    for p in $POLICIES; do echo "$p|$(short_name "$t")|$t" >> "$QUEUE"; done
  done < <(trace_list)
}

phase_plan() {
  build_queue
  echo "== A4 single-core baseline validation =="
  echo "   traces:   $TRACES"
  echo "   policies: $POLICIES"
  echo "   $WARMUP warmup + $SIM simulation, single core"
  echo
  local n_tr n_jobs n_done=0 p tn t
  n_tr=$(trace_list | wc -l)
  n_jobs=$(wc -l < "$QUEUE")
  while IFS='|' read -r p tn t; do job_done "$p" "$tn" && n_done=$((n_done + 1)); done < "$QUEUE"
  echo "   traces found: $n_tr"
  echo "   jobs:         $n_jobs   already complete: $n_done   to run: $((n_jobs - n_done))"
  echo
  trace_list | while IFS= read -r t; do printf '     %-40s %s\n' "$(short_name "$t")" "$(du -h "$t" | cut -f1)"; done
  [ "$n_tr" -eq 0 ] && echo "   no traces -- run get_spec_traces.sh first"
  echo
  echo "   at $MAXJOBS concurrent, expect roughly $(( (n_jobs - n_done) * 25 / MAXJOBS / 60 )) h"
}

worker() {
  echo $$ > "$LOCK"
  local p tn t cfg out log
  while IFS='|' read -r p tn t; do
    if job_done "$p" "$tn"; then
      echo "$(date '+%F %T') DONE  $p $tn (already complete)" >> "$RUNLOG"; continue
    fi
    while [ "$(jobs -rp | wc -l)" -ge "$MAXJOBS" ]; do sleep 20; done
    out=$(job_dir "$p" "$tn"); mkdir -p "$out"; log="$out/run.log"
    cfg="$STATE/cfg_$p.json"
    if ! "$S/scripts/make_config.py" --policy "$p" --cores 1 --regime private -o "$cfg"; then
      echo "$(date '+%F %T') CFGFAIL $p" >> "$RUNLOG"; continue
    fi
    echo "$(date '+%F %T') START $p $tn" >> "$RUNLOG"
    (
      started=$(date +%s)
      cd "$S" && nice -n 19 "$BIN" --config "$cfg" \
        --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$t" > "$log" 2>&1
      rc=$?
      printf '%s END   %s %s rc=%s elapsed=%sm\n' "$(date '+%F %T')" "$p" "$tn" "$rc" \
        "$(( ($(date +%s) - started) / 60 ))" >> "$RUNLOG"
    ) &
    sleep 1
  done < "$QUEUE"
  wait
  echo "$(date '+%F %T') A4 QUEUE COMPLETE" >> "$RUNLOG"
  rm -f "$LOCK"
}

driver_alive() { [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; }

phase_go() {
  driver_alive && die "an A4 driver is already running (pid $(cat "$LOCK"))"
  [ -x "$BIN" ] || die "no binary at $BIN"
  [ "$(trace_list | wc -l)" -gt 0 ] || die "no traces in $TRACES -- run get_spec_traces.sh"
  local g
  for g in check_include_path check_fill_hook check_signatures; do
    bash "$R/bench/policy_sanity/$g.sh" >/dev/null 2>&1 || die "$g failed -- not launching"
  done
  build_queue
  mkdir -p "$STATE" "$RESULTS"
  echo "$(date '+%F %T') A4 QUEUE START ($(wc -l < "$QUEUE") jobs, max $MAXJOBS)" >> "$RUNLOG"
  setsid env STATE="$STATE" QUEUE="$QUEUE" RUNLOG="$RUNLOG" LOCK="$LOCK" \
      RESULTS="$RESULTS" WARMUP="$WARMUP" SIM="$SIM" MAXJOBS="$MAXJOBS" BIN="$BIN" POLICIES="$POLICIES" \
      bash "$0" __worker < /dev/null >> "$RUNLOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
  echo "launched."; tail -4 "$RUNLOG"
}

# Resume after a reboot. Safe to call when already running; completed jobs are
# skipped by their log's end marker, so a resume costs only the runs that were
# actually in flight.
#
# tmux and nohup do not help here. setsid already detaches these jobs from the
# terminal session, which is what nohup approximates; what neither survives is
# the machine going down, and that is exactly what happened on 2026-09-17 --
# the sweep died at 07:51, the box came back at 09:49, and nothing restarted
# the queue, so it sat idle for 19 hours.
phase_resume() {
  driver_alive && { echo "driver already running (pid $(cat "$LOCK"))"; return 0; }
  rm -f "$LOCK"
  echo "$(date '+%F %T') A4 RESUME after reboot (up since $(uptime -s))" >> "$RUNLOG"
  phase_go
}

# One entry per STATE, carrying the settings that make it that run. The entry
# used to be fixed to the defaults, so it could only ever resume the original
# A4: an A/B arm would not restart at all, and one resumed with the defaults
# would have run bin/champsim into ~/.a4. Entries are keyed by a trailing
# comment naming the STATE, so installing one run leaves the others alone. The
# brackets matter: unbracketed, ~/.a4 is a prefix of ~/.a4_armA, and
# reinstalling the default run deleted both arms' entries (caught in testing).
phase_install_resume() {
  local tag="# a4-state[$STATE]"
  local line="@reboot sleep 240 && STATE='$STATE' RESULTS='$RESULTS' BIN='$BIN' POLICIES='$POLICIES' MAXJOBS='$MAXJOBS' WARMUP='$WARMUP' SIM='$SIM' /bin/bash $HOME/run_a4.sh resume >> '$STATE/reboot.log' 2>&1 $tag"
  mkdir -p "$STATE"
  # The pre-2026-09-23 default entry has no tag; replace it only when
  # (re)installing the default run it belongs to.
  (crontab -l 2>/dev/null | grep -vF -- "$tag" \
     | if [ "$STATE" = "$HOME/.a4" ]; then grep -v "run_a4.sh resume >> $HOME/.a4/reboot.log"; else cat; fi
   echo "$line") | crontab -
  echo "installed:"; crontab -l | grep run_a4
  echo
  echo "A4 now restarts itself ~4 min after any boot, skipping finished jobs."
  echo "(run_phase_a.sh has its own entry at +3 min; they stagger deliberately.)"
}

phase_status() {
  [ -f "$RUNLOG" ] || { echo "not started"; return 0; }
  local n_done=0 p tn t
  [ -f "$QUEUE" ] || build_queue
  while IFS='|' read -r p tn t; do job_done "$p" "$tn" && n_done=$((n_done + 1)); done < "$QUEUE"
  printf 'verified complete: %s / %s   running now: %s\n' \
    "$n_done" "$(wc -l < "$QUEUE")" "$(pgrep -u "$(id -u)" -c '^champsim' 2>/dev/null | head -1)"
  driver_alive && echo "driver: alive (pid $(cat "$LOCK"))" || echo "driver: NOT RUNNING"
  grep -q "A4 QUEUE COMPLETE" "$RUNLOG" 2>/dev/null && echo "*** COMPLETE ***"
  echo; tail -8 "$RUNLOG"
}

# Pull LOAD hit rate, total hit rate and IPC out of one log.
# Emits: policy trace load_acc load_hit total_acc total_hit ipc cycles
extract() {
  local log="$1" p="$2" tn="$3"
  grep -q "$DONE_MARKER" "$log" 2>/dev/null || return 1
  awk -v pol="$p${ARM:+@$ARM}" -v tr="$tn" '
    /^cpu0->LLC LOAD/  {for(i=1;i<=NF;i++){if($i=="ACCESS:")la=$(i+1); if($i=="HIT:")lh=$(i+1)}}
    /^cpu0->LLC TOTAL/ {for(i=1;i<=NF;i++){if($i=="ACCESS:")ta=$(i+1); if($i=="HIT:")th=$(i+1)}}
    /^Simulation complete CPU 0/ {for(i=1;i<=NF;i++){if($i=="IPC:")ipc=$(i+1); if($i=="cycles:")cy=$(i+1)}}
    END {printf "%s %s %d %d %d %d %s %s\n", pol, tr, la+0, lh+0, ta+0, th+0, (ipc==""?"0":ipc), (cy==""?"0":cy)}
  ' "$log"
}

collect() {
  local p tn t log
  [ -f "$QUEUE" ] || build_queue
  while IFS='|' read -r p tn t; do
    log=$(job_log "$p" "$tn")
    [ -s "$log" ] || continue
    extract "$log" "$p" "$tn"
  done < "$QUEUE"
}

phase_results() { collect | python3 "$0.py" table; }
phase_check()   { collect | python3 "$0.py" check; }
phase_inflation() { collect | python3 "$0.py" inflation; }

# Raw extracted rows, one per completed run, nothing interpreted.
#
# Every published A4 number traces back to these 132 lines, so they are worth
# having off the server as a file rather than re-deriving them from a summary
# each time. Pipe into run_a4.sh.py on any machine:
#
#   ssh -p 2222 user@your-server 'bash ~/run_a4.sh rows' > a4_rows.txt
#   python3 scripts/run_a4.sh.py inflation < a4_rows.txt
phase_rows() { collect; }

case "${1:-}" in
  plan)      phase_plan ;;
  go)             phase_go ;;
  resume)         phase_resume ;;
  install-resume) phase_install_resume ;;
  status)         phase_status ;;
  results)   phase_results ;;
  check)     phase_check ;;
  rows)      phase_rows ;;
  inflation) phase_inflation ;;
  __worker)  worker ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
