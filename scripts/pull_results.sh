#!/usr/bin/env bash
# Pull every result the analysis needs, over one connection (one password).
#
#   scripts/pull_results.sh        # from the repo root, on the LAPTOP
#
# What it brings down, each to a NEW file so nothing is overwritten:
#   bench/policy_sanity/phasea_rows_v<N+1>.txt   run_phase_a.sh rows (every phaseA* tree)
#   bench/policy_sanity/b3_rows_v<K+1>.txt       b3_rows.sh (the store-time counters)
#   simulator/results/gem5_b3/                   stats.txt, run.log, config.ini of each
#                                                B3 gem5 run (gitignored)
#   simulator/results/heldout2/                  held-out set 2 and streamcluster (Note 8):
#                                                trace reports, run logs, sizing markers,
#                                                the chain's log (gitignored; copied, not read)
#   simulator/results/b3v4_chain/                what the B3 v4 chain decided on the
#                                                server: VERDICT, gate.txt, score.txt,
#                                                chain.log, the rows it scored (gitignored)
# It uploads b3_rows.sh first. That is a read-only report, never a running
# driver, so a plain copy is safe. It prints the queue and gem5 status first,
# so a pull taken before everything has finished says so; unfinished rows
# are marked INCOMPLETE in the files themselves.
set -uo pipefail

PORT=2222
SRV="user@your-server"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS="$LROOT/bench/policy_sanity"

next() {   # $1 prefix -> the next unused version number
  local n=0 f v
  for f in "$PS/$1"_v*.txt; do
    [ -e "$f" ] || continue
    v=${f##*_v}; v=${v%.txt}
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt "$n" ] && n=$v
  done
  echo $((n + 1))
}

CTL="$HOME/.ssh/cm-pull-$$"
GAVEUP="$CTL.gaveup"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL" "$GAVEUP"; }
trap cleanup EXIT
# Every connection gives up when the server stops answering for 2 minutes
# (4 x 30 s), or cannot be reached in 30 s. 2026-10-29: the shared connection
# dropped, the next step opened a connection of its own without these, that
# one died too, and the pull waited for ever with nothing running on the server.
KEEP=(-o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o ConnectTimeout=30)
RSH="ssh -p $PORT -o ControlPath=$CTL ${KEEP[*]}"   # rsync -e
open_master() {
  rm -f "$CTL"
  ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=20m "${KEEP[@]}" -fN "$SRV"
}
# Before each step: if the shared connection has dropped, open it again (the
# password once more). If that fails as well, every later step fails at once
# instead of asking again.
ensure_master() {
  [ -e "$GAVEUP" ] && return 1
  ssh -O check -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null && return 0
  echo "   (the connection dropped -- reconnecting: the password once more)" >&2
  open_master && return 0
  touch "$GAVEUP"
  echo "   (could not reconnect -- the rest of this pull is skipped; run it again later)" >&2
  return 1
}
echo "One connection -- the password is asked once (once more if the connection drops)."
open_master || { echo "could not connect"; exit 1; }
R() { ensure_master || return 1; ssh -n -p "$PORT" -o ControlPath="$CTL" "${KEEP[@]}" "$SRV" "$@"; }

echo; echo "== status =="
# Each queue's progress line is two lines below its SWEEP line, so pair them
# by state, not by position.
R 'bash ~/server_status.sh 2>&1' | awk '
  /^SWEEP: phaseA_(.*ocean4.*|b3_.*|l2_.*)$/ { name = $2; want = 1; next }
  /^SWEEP:/ { want = 0 }
  want && /this queue/ { sub(/.*verified complete: */, ""); printf "   %-28s %s\n", name, $0; want = 0 }'
R '[ -f ~/launch_b3_gem5.sh ] && bash ~/launch_b3_gem5.sh status' | sed 's/^/   /'
# gem5 on the 256-body-leaf barnes (b3_barnes256_design_2026-10-12.md). Says
# so when it has never been started: silence read as "don't know" (2026-10-13).
R 'if [ -d ~/gem5_b3/barnes_leaf256 ]; then
     echo "barnes256 (gem5 on the traced barnes): STARTED on $(ls -ld --time-style=long-iso ~/gem5_b3/barnes_leaf256 | awk "{print \$6, \$7}")"
     grep -E "STOPPED|pipeline done" ~/gem5_b3/barnes_leaf256/pipeline.log 2>/dev/null | tail -1
     WL=barnes VARIANT=leaf256 bash ~/launch_b3_gem5.sh status
   else
     echo "barnes256 (gem5 on the traced barnes): NOT RUN YET -- run scripts/barnes256_all.sh"
   fi' | sed 's/^/   /'
# The standard barnes (b3_barnes_std_design_2026-10-13.md): where its pipeline
# is, without the whole log.
R 'if [ -f ~/barnes_std/pipeline.log ]; then
     echo "barnes_std (the standard barnes for ChampSim): STARTED"
     grep -E "^=== |STOPPED|RESIDUAL|OFFSET|standard program|shift still left" ~/barnes_std/pipeline.log | tail -12
     bash ~/barnes_std.sh status 2>/dev/null | grep -E "ChampSim runs complete|stop at 100000000"
   else
     echo "barnes_std (the standard barnes for ChampSim): NOT RUN YET -- run scripts/barnes_std_all.sh"
   fi; true' | sed 's/^/   /'
R '[ -f ~/b3v4_chain.sh ] && bash ~/b3v4_chain.sh status' | sed 's/^/   /'
# The checks of 2026-10-14 (scripts/checks_all.sh): held-out programs, canneal
# at 8 cores, A6 (the LLC-size sweep). Each says when it has not been started.
R 'if [ -f ~/b3_heldout/pipeline.log ]; then
     echo "held-out (radix, waternsq, fmm): STARTED"
     grep -E "^=== .*(1/8|4/8|7/8|pipeline done)|STOPPED|OFFSET|QB:" ~/b3_heldout/pipeline.log | tail -14
     bash ~/b3_heldout.sh status 2>/dev/null | grep -E "ChampSim runs complete|stop at"
   else echo "held-out: NOT RUN YET -- scripts/checks_all.sh"; fi
   if [ -f ~/b3_canneal8/pipeline.log ]; then
     echo "canneal 8c (B3): STARTED"; grep -E "^=== |STOPPED" ~/b3_canneal8/pipeline.log | tail -5
     bash ~/b3_canneal8.sh status 2>/dev/null | grep -E "ChampSim runs complete|stop at"
   else echo "canneal 8c (B3): NOT RUN YET -- scripts/checks_all.sh"; fi
   if [ -f ~/a6_sweep.sh ]; then bash ~/a6_sweep.sh status 2>/dev/null | head -1; else echo "A6: NOT RUN YET -- scripts/checks_all.sh"; fi
   if [ -f ~/c0_server.sh ]; then bash ~/c0_server.sh status 2>/dev/null | head -1; else echo "C0: NOT RUN YET -- scripts/c0_all.sh"; fi
   if [ -f ~/diag_server.sh ]; then bash ~/diag_server.sh status 2>/dev/null | head -1; else echo "bounded-view diagnosis: NOT RUN YET -- scripts/diag_all.sh"; fi
   echo "disk: $(df -h ~ | tail -1 | awk "{print \$4}") free"
   echo "== 2026-10-18: step 1 (speed), step 2 (synchronised replay), the disk clean-up"
   if [ -f ~/speed_server.sh ]; then bash ~/speed_server.sh status 2>/dev/null | tail -1; else echo "speed: NOT RUN YET -- scripts/speed_all.sh"; fi
   if [ -f ~/sync_server.sh ]; then bash ~/sync_server.sh status 2>/dev/null; else echo "sync: NOT RUN YET -- scripts/sync_all.sh"; fi
   if [ -d ~/sync_mx ]; then VARIANT=mx bash ~/sync_server.sh status 2>/dev/null; else echo "sync mx (mutex order by timing): NOT RUN YET -- scripts/syncmx_all.sh"; fi
   if [ -d ~/sync_g5 ]; then VARIANT=g5 bash ~/sync_server.sh status 2>/dev/null; VARIANT=g5 bash ~/sync_server.sh q0full 2>/dev/null; else echo "sync g5 (step 3, the gem5-rule view): NOT RUN YET -- scripts/syncg5_all.sh"; fi
   if [ -d ~/sync_g6 ]; then VARIANT=g6 bash ~/sync_server.sh status 2>/dev/null; VARIANT=g6 bash ~/sync_server.sh q0full 2>/dev/null; VARIANT=g6 bash ~/sync_server.sh q3 2>/dev/null; else echo "sync g6 (amendment 2, the view-order split): NOT RUN YET -- scripts/syncg6_all.sh"; fi
   if [ -d ~/sync_pol ]; then VARIANT=pol bash ~/sync_server.sh status 2>/dev/null; else echo "== step 5 (the policy runs): NOT STARTED -- scripts/policy_all.sh"; fi
   echo "== step 4, the new benchmarks"
   if [ -f ~/newbench_server.sh ]; then bash ~/newbench_server.sh status 2>/dev/null | head -1; grep -h "CHOSEN\|STOPPED" ~/newbench/size.log 2>/dev/null | tail -8 | sed "s/^/   /"; else echo "   sizing: NOT RUN YET -- scripts/newbench_all.sh size"; fi
   if [ -d ~/sync_nb ]; then VARIANT=nb bash ~/sync_server.sh status 2>/dev/null; else echo "   tracing and ChampSim runs: NOT STARTED -- scripts/newbench_all.sh go"; fi
   if [ -d ~/sync_nb_r ]; then W=~/sync_nb_r PROGS="$(grep "^radiosity|" ~/newbench/PROGS)" JOBS_SPEC="$(grep "|radiosity\$" ~/newbench/JOBS)" VARIANT=nb bash ~/sync_server.sh status 2>/dev/null | sed "s/^== sync nb/== sync nb, radiosity alone (newbench amendment 2)/"; fi
   for p in fft lu raytrace streamcluster volrend radiosity lunc; do [ -d ~/gem5_b3/newbench/$p ] && WL=$p bash ~/launch_b3_gem5.sh status 2>/dev/null | sed "s/^/   /"; done
   echo "== step 4 fix: the same-stream diagnosis (streamfix) and the F2 retrace (nc)"
   if [ -f ~/streamfix_server.sh ]; then bash ~/streamfix_server.sh status 2>/dev/null; else echo "   streamfix: NOT RUN YET -- scripts/streamfix_all.sh"; fi
   if [ -d ~/sync_nc ]; then VARIANT=nc bash ~/sync_server.sh status 2>/dev/null; tail -n 3 ~/sync_nc/launch.log 2>/dev/null | sed "s/^/   launch.log: /"; else echo "   F2 retrace (nc): NOT STARTED -- scripts/syncnc_all.sh"; fi
   if [ -f ~/disk_server.sh ]; then bash ~/disk_server.sh status 2>/dev/null | head -1; grep -c -E "COMPRESSED|DELETED" ~/disk/go.log 2>/dev/null | sed "s/^/   items done: /"; grep -E "FAILED|SKIPPED" ~/disk/go.log 2>/dev/null | tail -5 | sed "s/^/   /"; fi
   true' | sed 's/^/   /'
# When the machine last booted, and every start and resume of the rerun's two
# queues: a queue restarted by a reboot counts "started" from that restart, so
# its line above can read "started: 7, finished: 0" beside 7 complete
# (2026-10-13).
# ours PATTERN: our processes whose command line holds PATTERN, leaving out
# shells and tools. This report is itself a "bash -c" whose text holds every
# pattern, so a plain pgrep -f counted it (and its subshells): "champsim 2,
# pin 2" with nothing running (2026-11-01).
R 'ours() { ps -u "$(id -u)" -o args= | grep -vE "^-?([^ ]*/)?(bash|sh|grep|ps|strings|awk|sed)( |\$)" | grep -c -- "$1"; }
   echo "== the machine =="; echo "booted: $(uptime -s)   now: $(date "+%F %T")   load: $(cut -d" " -f1-3 /proc/loadavg)"
   echo "account: $(chage -l "$(id -un)" 2>/dev/null | grep -i "account expires" | sed "s/.*: *//")   our processes now: champsim $(ours /bin/champsim), pin $(ours champsim_tracer), gem5 $(pgrep -u "$(id -u)" -c -x gem5.opt 2>/dev/null)"
   for t in l2_fixed l2_scaled; do f=~/.phase_a_$t/run.log; [ -f "$f" ] && grep -E " QUEUE START| RESUME" "$f" | sed "s/^/$t: /"; done
   # 2026-10-21: the m2 + g5 relaunch, run on the server (relaunch_m2g5.sh)
   [ -f ~/relaunch_m2g5.log ] && { echo "relaunch (m2 + g5):"; grep -E "^20[0-9-]+ [0-9:]+ " ~/relaunch_m2g5.log | tail -6 | sed "s/^/   /"; }
   # step 4 traces with the g5 build tree tracer: it must be the fixed one (QS, 13ad66f)
   echo "step-4 tracer: $(grep -h "QS holds" ~/sync_g5/build_run.log 2>/dev/null | tail -1 | sed "s/^ *//" || true) [fixed-tracer marker: $(strings -a ~/sync_g5_build/simulator/tracer/pin/obj-intel64/champsim_tracer.so 2>/dev/null | grep -c "(routine ")]"
   true' | sed 's/^/   /'

echo; echo "== pulling =="
{ ensure_master && scp -q -P "$PORT" -o ControlPath="$CTL" "${KEEP[@]}" "$LROOT/scripts/b3_rows.sh" "$SRV:~/"; } || { echo "upload of b3_rows.sh failed"; exit 1; }

# pull_to FILE COMMAND: the server's report into FILE. ssh exits 255 when the
# connection is lost, and a lost shared connection says nothing (its messages
# go to /dev/null), so that case is named and tried once more from the start
# (FILE rewritten, never appended). 2026-11-01: "rows failed" with no reason;
# the rows step is the longest (it reads every run log), so it is the one a
# drop or a sleeping laptop hits.
pull_to() {
  local out=$1 s; shift
  R "$@" > "$out"; s=$?
  if [ "$s" -eq 255 ]; then
    echo "   (the connection was lost during this step -- trying it once more)" >&2
    R "$@" > "$out"; s=$?
  fi
  return "$s"
}
why() { [ "$1" -eq 255 ] && echo "the connection was lost twice; keep the laptop awake and run the pull again" || echo "the server's command exited $1"; }

n=$(next phasea_rows); f="$PS/phasea_rows_v$n.txt"
pull_to "$f" 'bash ~/run_phase_a.sh rows' || { s=$?; rm -f "$f"; echo "rows failed: $(why "$s")"; exit 1; }
echo "   $(basename "$f"): $(wc -l < "$f") rows, $(grep -c ' INCOMPLETE ' "$f") incomplete"

k=$(next b3_rows); g="$PS/b3_rows_v$k.txt"
if pull_to "$g" 'bash ~/b3_rows.sh'; then
  echo "   $(basename "$g"): $(wc -l < "$g") rows"
else
  s=$?; rm -f "$g"
  if [ "$s" -eq 1 ]; then echo "   b3_rows: none yet (no B3 ChampSim run has a log)"; else echo "   b3_rows failed: $(why "$s")"; fi
fi

mkdir -p "$LROOT/simulator/results/gem5_b3"
rsync -a --copy-links --include='*/' --include='stats.txt' --include='run.log' --include='config.ini' \
      --exclude='*' -e "$RSH" \
      "$SRV:/home/harshraj/gem5_b3/" "$LROOT/simulator/results/gem5_b3/" \
  && echo "   gem5_b3/: $(find "$LROOT/simulator/results/gem5_b3" -name stats.txt | wc -l) run(s) with stats" \
  || echo "   gem5_b3: rsync failed"
if R '[ -d ~/barnes_std ]'; then
  mkdir -p "$LROOT/simulator/results/barnes_std"
  rsync -a --copy-links --include='*.log' --include='*.txt' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/barnes_std/" "$LROOT/simulator/results/barnes_std/" \
    && echo "   barnes_std/: $(ls "$LROOT/simulator/results/barnes_std" | tr '\n' ' ')" \
    || echo "   barnes_std: rsync failed"
fi
for d in b3_heldout b3_canneal8 a6 c0 diag; do
  if R "[ -d ~/$d ]"; then
    mkdir -p "$LROOT/simulator/results/$d"
    rsync -a --copy-links --include='*/' --include='*.log' --include='*.txt' --exclude='*' -e "$RSH" \
          "$SRV:/home/harshraj/$d/" "$LROOT/simulator/results/$d/" \
      && echo "   $d/: $(find "$LROOT/simulator/results/$d" -name trace_mix.txt | wc -l) mix file(s), $(find "$LROOT/simulator/results/$d" -name '*.log' | wc -l) log(s)" \
      || echo "   $d: rsync failed"
  fi
done
if R '[ -d ~/b3v4_chain ]'; then
  mkdir -p "$LROOT/simulator/results/b3v4_chain"
  rsync -a --copy-links -e "$RSH" \
        "$SRV:/home/harshraj/b3v4_chain/" "$LROOT/simulator/results/b3v4_chain/" \
    && echo "   b3v4_chain/: $(cat "$LROOT/simulator/results/b3v4_chain/VERDICT" 2>/dev/null || echo 'no verdict yet')" \
    || echo "   b3v4_chain: rsync failed"
fi
# 2026-10-18: the speed test, the synchronised-replay runs, the disk clean-up log
if R '[ -d ~/speed ]'; then
  mkdir -p "$LROOT/simulator/results/speed"
  R 'bash ~/speed_server.sh report 2>/dev/null' > "$LROOT/simulator/results/speed/report.txt"
  rsync -a --copy-links --include='*/' --include='time.txt' --include='run.log' --include='stats.txt' --include='o3_name.txt' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/speed/" "$LROOT/simulator/results/speed/" \
    && echo "   speed/: $(grep -c ' ok' "$LROOT/simulator/results/speed/report.txt") of 12 runs done (report.txt)" || echo "   speed: rsync failed"
fi
if R '[ -d ~/sync ]'; then
  mkdir -p "$LROOT/simulator/results/sync/logs" "$LROOT/simulator/results/sync/traces"
  rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_s2_*" "$LROOT/simulator/results/sync/logs/" 2>/dev/null
  rsync -a --copy-links --prune-empty-dirs --include='*/' --include='pin.err' --include='cut.log' --include='*.mix' --include='DONE' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/sync/" "$LROOT/simulator/results/sync/traces/" 2>/dev/null
  rsync -a --copy-links --include='driver.log' --exclude='*' -e "$RSH" "$SRV:/home/harshraj/sync/" "$LROOT/simulator/results/sync/" 2>/dev/null
  echo "   sync/: $(ls "$LROOT/simulator/results/sync/traces" 2>/dev/null | wc -l) programs' trace reports, $(find "$LROOT/simulator/results/sync/logs" -name run.log 2>/dev/null | wc -l) run logs"
fi
if R '[ -d ~/sync_mx ]'; then
  mkdir -p "$LROOT/simulator/results/sync_mx/logs" "$LROOT/simulator/results/sync_mx/traces"
  rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_m2_*" "$LROOT/simulator/results/sync_mx/logs/" 2>/dev/null
  rsync -a --copy-links --prune-empty-dirs --include='*/' --include='pin.err' --include='cut.log' --include='*.mix' --include='DONE' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/sync_mx/" "$LROOT/simulator/results/sync_mx/traces/" 2>/dev/null
  rsync -a --copy-links --include='driver.log' --include='q0b/***' --exclude='*' -e "$RSH" "$SRV:/home/harshraj/sync_mx/" "$LROOT/simulator/results/sync_mx/" 2>/dev/null
  echo "   sync_mx/: $(ls "$LROOT/simulator/results/sync_mx/traces" 2>/dev/null | wc -l) programs' trace reports, $(find "$LROOT/simulator/results/sync_mx/logs" -name run.log 2>/dev/null | wc -l) run logs"
fi
if R '[ -d ~/sync_g5 ]'; then
  mkdir -p "$LROOT/simulator/results/sync_g5/logs"
  rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_g2_*" "$LROOT/simulator/results/sync_g5/logs/" 2>/dev/null
  rsync -a --copy-links --include='driver.log' --include='q0m/***' --exclude='*' -e "$RSH" "$SRV:/home/harshraj/sync_g5/" "$LROOT/simulator/results/sync_g5/" 2>/dev/null
  echo "   sync_g5/: $(find "$LROOT/simulator/results/sync_g5/logs" -name run.log 2>/dev/null | wc -l) run logs"
fi
if R '[ -d ~/sync_g6 ]'; then
  mkdir -p "$LROOT/simulator/results/sync_g6/logs"
  rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_g3_*" "$LROOT/simulator/results/sync_g6/logs/" 2>/dev/null
  rsync -a --copy-links --include='driver.log' --include='launch.log' --include='build_run.log' --include='q0/***' --include='q0m/***' --exclude='*' -e "$RSH" "$SRV:/home/harshraj/sync_g6/" "$LROOT/simulator/results/sync_g6/" 2>/dev/null
  echo "   sync_g6/: $(find "$LROOT/simulator/results/sync_g6/logs" -name run.log 2>/dev/null | wc -l) run logs"
fi
if R '[ -d ~/sync_nb ] || [ -d ~/newbench ]'; then
  mkdir -p "$LROOT/simulator/results/newbench/logs" "$LROOT/simulator/results/newbench/traces" "$LROOT/simulator/results/newbench/server"
  rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_n2_*" "$LROOT/simulator/results/newbench/logs/" 2>/dev/null
  rsync -a --copy-links --prune-empty-dirs --include='*/' --include='pin.err' --include='cut.log' --include='anchor.txt' --include='*.mix' --include='DONE' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/sync_nb/" "$LROOT/simulator/results/newbench/traces/" 2>/dev/null
  rsync -a --copy-links --include='*/' --include='size.log' --include='CHOSEN' --include='PROGS' --include='JOBS' --include='count.txt' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/newbench/" "$LROOT/simulator/results/newbench/server/" 2>/dev/null
  rsync -a --copy-links --include='driver.log' --exclude='*' -e "$RSH" "$SRV:/home/harshraj/sync_nb/" "$LROOT/simulator/results/newbench/" 2>/dev/null
  rsync -a --copy-links -e "$RSH" "$SRV:/home/harshraj/sync_nb_r/driver.log" "$LROOT/simulator/results/newbench/driver_r.log" 2>/dev/null   # radiosity's own chain (amendment 2)
  echo "   newbench/: $(ls "$LROOT/simulator/results/newbench/server"/*/CHOSEN 2>/dev/null | wc -l) sized, $(find "$LROOT/simulator/results/newbench/logs" -name run.log 2>/dev/null | wc -l) run logs"
fi
if R '[ -d ~/streamfix ]'; then
  # the counter's counts, summaries, routine tables, CPUID files and logs (as streamfix_all.sh pull)
  mkdir -p "$LROOT/simulator/results/streamfix"
  rsync -a --copy-links --max-size=20m \
        --include='*/' --include='c.*' --include='STATUS' --include='PROGS' --include='err.txt' --include='*.cpuid' --include='facts.txt' \
        --include='driver.log' --include='DONE' --include='run.log' --include='dump.txt' --include='diff.txt' --include='out.txt' \
        --include='COUNTER_MD5' --include='gem5.cpuid.failed' --prune-empty-dirs \
        --exclude='*' -e "$RSH" "$SRV:/home/harshraj/streamfix/" "$LROOT/simulator/results/streamfix/" 2>/dev/null
  echo "   streamfix/: $(ls -d "$LROOT/simulator/results/streamfix/runs"/*/ 2>/dev/null | wc -l) counter runs, $(grep -l '^exit 0 ' "$LROOT/simulator/results/streamfix/runs"/*/STATUS 2>/dev/null | wc -l) exited 0"
fi
if R '[ -d ~/sync_nc ]'; then
  # the F2 retrace (as syncnc_all.sh pull)
  mkdir -p "$LROOT/simulator/results/sync_nc/logs" "$LROOT/simulator/results/sync_nc/traces"
  rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
        "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_n3_*" "$LROOT/simulator/results/sync_nc/logs/" 2>/dev/null
  rsync -a --copy-links --prune-empty-dirs --include='*/' --include='pin.err' --include='cut.log' --include='*.mix' --include='DONE' --include='CPUID' \
        --include='LEN' --include='FAILED' --include='anchor.txt' --include='anchor.err' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/sync_nc/" "$LROOT/simulator/results/sync_nc/traces/" 2>/dev/null
  rsync -a --copy-links --include='*.log' --include='gem5.cpuid' --include='*_PASSED' --exclude='*' -e "$RSH" "$SRV:/home/harshraj/sync_nc/" "$LROOT/simulator/results/sync_nc/" 2>/dev/null
  echo "   sync_nc/: $(ls "$LROOT/simulator/results/sync_nc/traces" 2>/dev/null | wc -l) programs' trace reports, $(find "$LROOT/simulator/results/sync_nc/logs" -name run.log 2>/dev/null | wc -l) run logs"
fi
if R '[ -d ~/sync_h2 ]'; then
  # held-out set 2 and streamcluster (heldout2_design_2026-11-04.md, Note 8):
  # the trace sets' reports (QT; the window counts, raw<t>.mix), the ChampSim
  # run logs (Q3), the sizing markers (QB) and the chain's log (its binary).
  # Copied, not read. The counter runs: scripts/heldout2_all.sh pullcount.
  # Only set 2's trees: set 1's phaseA_b3_h2_{radix,waternsq,fmm}4 are not these.
  H2L="$LROOT/simulator/results/heldout2"
  mkdir -p "$H2L/logs" "$H2L/traces" "$H2L/server"
  for p in fluidanimate bodytrack facesim vips oceannc streamcluster; do
    rsync -a --copy-links --include='*/' --include='run.log' --exclude='*' -e "$RSH" \
          "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/results/phaseA_b3_h2_${p}4" "$H2L/logs/" 2>/dev/null
  done
  rsync -a --copy-links --prune-empty-dirs --include='*/' --include='pin.err' --include='*.mix' --include='DONE' --include='CPUID' \
        --include='LEN' --include='FAILED' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/sync_h2/" "$H2L/traces/" 2>/dev/null
  rsync -a --copy-links --prune-empty-dirs --exclude='inputs/' --exclude='upload/' --exclude='h2probe/' --include='*/' \
        --include='SIZED' --include='CHOSEN' --include='NCPU' --include='PROGS' --include='JOBS' --include='size.log' \
        --include='streamcluster.PROGS' --include='streamcluster.JOBS' --exclude='*' \
        -e "$RSH" "$SRV:/home/harshraj/heldout2/" "$H2L/server/" 2>/dev/null
  rsync -a --copy-links -e "$RSH" "$SRV:/home/harshraj/sync_h2/driver.log" "$H2L/driver.log" 2>/dev/null
  echo "   heldout2/: $(find "$H2L/traces" -name DONE 2>/dev/null | wc -l) trace sets done, $(find "$H2L/logs" -name run.log 2>/dev/null | wc -l) run logs, $(ls "$H2L"/server/*/SIZED 2>/dev/null | wc -l) sized (counter runs: heldout2_all.sh pullcount)"
fi
if R '[ -f ~/disk/go.log ]'; then
  mkdir -p "$LROOT/simulator/results/disk"
  rsync -a -e "$RSH" "$SRV:/home/harshraj/disk/go.log" "$SRV:/home/harshraj/disk/proposal.tsv" "$LROOT/simulator/results/disk/" 2>/dev/null \
    && echo "   disk/: the clean-up log"
fi
echo; echo "Done. Tell Claude: pulled."
