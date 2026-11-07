#!/usr/bin/env bash
# The m2 and g5 relaunch, run ON THE SERVER and detached, so a dropped laptop
# connection cannot stop it. (2026-10-21: scripts/syncmx_all.sh lost its
# connection two minutes into the build, before the refresh and the chain.)
# It does what syncmx_all.sh's steps 3-4 do, then starts the g5 chain:
#   0. stops if either chain is already running; waits for any earlier
#      'sync_server.sh build' still running (nohup keeps a dropped one going);
#   1. VARIANT=mx build: guards, the tracer, QS, Q0, Q0b (about 15 min);
#   2. VARIANT=mx refresh: traces from the old tracer moved aside, with their runs;
#   3. VARIANT=mx chain: trace 8 programs, then 12 runs (detached);
#   4. VARIANT=g5 chain: waits for the new traces, Q0m, 12 runs (detached).
# The g5 binary is not rebuilt: champsim_g5_034cd735 passed Q0 on 2026-10-20
# and no simulator source has changed since (only make_config.py's new
# option, whose defaults are byte-identical).
# Needs the sources that scripts/syncmx_all.sh step 2 uploaded (2026-10-21).
#
# From the laptop, one password (uploads to .new, then mv; log ~/relaunch_m2g5.log):
#   ssh -p 2222 user@your-server 'cat > ~/relaunch_m2g5.sh.new; mv -f ~/relaunch_m2g5.sh.new ~/relaunch_m2g5.sh; setsid nohup bash ~/relaunch_m2g5.sh > ~/relaunch_m2g5.log 2>&1 < /dev/null & sleep 5; cat ~/relaunch_m2g5.log' < scripts/relaunch_m2g5.sh
# Later: tail ~/relaunch_m2g5.log, or scripts/pull_results.sh.
set -uo pipefail
SV="$HOME/sync_server.sh"
say() { echo "$(date '+%F %T') $*"; }
fail() { say "RELAUNCH STOPPED: $*"; exit 1; }

say "relaunch start"
[ -f "$SV" ] || fail "no $SV"
for v in mx g5; do
  st=$(VARIANT=$v bash "$SV" status 2>/dev/null | head -1)
  case "$st" in *"chain alive"*) fail "the $v chain is already running -- nothing done" ;; esac
done
n=0
while pgrep -u "$(id -u)" -f '[s]ync_server\.sh build' > /dev/null; do
  [ $((n % 10)) = 0 ] && say "an earlier build is still running; waiting for it to end"
  n=$((n + 1)); sleep 30
done
say "1/4 mx build: guards, the tracer, QS, Q0, Q0b (about 15 min)"
VARIANT=mx bash "$SV" build || fail "the mx build failed (above; ~/sync_mx/build_run.log)"
say "2/4 mx refresh"
VARIANT=mx bash "$SV" refresh || fail "the refresh failed"
say "3/4 mx chain"
VARIANT=mx bash "$SV" chain || fail "the mx chain did not start"
say "4/4 g5 chain"
VARIANT=g5 bash "$SV" chain || fail "the g5 chain did not start"
say "RELAUNCH DONE: both chains started"
