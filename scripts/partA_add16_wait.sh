#!/usr/bin/env bash
# Part A, amendment 4's add16, waiting on the server for the first chain to
# end (upstream_equiv_design_2026-11-10.md, amendment 5; owner's word
# 2026-11-13). Uploaded and started, detached, by scripts/partA_all.sh add16wait.
#
#   bash ~/partA_add16_wait.sh MD5     # MD5: the staged ~/partA_server.sh.add16 (amendment 4's runner)
#
# It does what partA_all.sh add16 does on the server, no sooner than add16
# would: waits while the partA chain is alive (checked every 10 min); then
# puts the staged runner in place of ~/partA_server.sh (md5 checked before and
# after); 'e0_16' (which refuses unless all 185 runs are complete); 'chain'.
# Any refusal or failure stops it with nothing added. A reboot ends it (as it
# ends the chain); then partA_all.sh add16 by hand.
set -uo pipefail
W="${W:-$HOME/partA}"
PIDF="$W/.driver.pid"
WPID="$W/.add16_wait.pid"
STAGED="${STAGED:-$HOME/partA_server.sh.add16}"
LIVE="${LIVE:-$HOME/partA_server.sh}"
POLL="${POLL:-600}"
MD5="${1:?usage: $0 MD5-of-the-staged-runner}"

alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
stop() { echo "$(date '+%F %T') STOPPED: $* -- nothing added"; rm -f "$WPID"; exit 1; }

alive "$WPID" && { echo "a waiter is running already (pid $(cat "$WPID"))"; exit 0; }
echo $$ > "$WPID"
[ -f "$STAGED" ] && [ "$(md5sum < "$STAGED" | cut -c1-32)" = "$MD5" ] || stop "$STAGED is missing or not md5 $MD5"
echo "$(date '+%F %T') WAIT: for the partA chain (pid $(cat "$PIDF" 2>/dev/null || echo none)) to end; staged runner md5 ${MD5:0:8}"
while alive "$PIDF"; do sleep "$POLL"; done
echo "$(date '+%F %T') the partA chain is not running"
[ "$(md5sum < "$STAGED" | cut -c1-32)" = "$MD5" ] || stop "$STAGED changed while waiting"
mv -f "$STAGED" "$LIVE" || stop "mv onto $LIVE failed"
[ "$(md5sum < "$LIVE" | cut -c1-32)" = "$MD5" ] || stop "$LIVE is not md5 $MD5 after the mv"
echo "$(date '+%F %T') $LIVE is the amendment 4 runner (md5 ${MD5:0:8})"
bash "$LIVE" e0_16 || stop "e0_16 refused or failed (above)"
bash "$LIVE" chain || stop "the chain did not start (above)"
echo "$(date '+%F %T') ADDED: 16a and 16b (E1 20 runs, E2 2); the chain skips the 185 done"
rm -f "$WPID"
