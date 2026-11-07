#!/usr/bin/env bash
# Repair the @reboot resume so it rebuilds the SAME queue that is running.
#
#   scp -P 2222 scripts/fix_resume_env.sh user@your-server:~/
#   ssh -n -p 2222 user@your-server 'bash ~/fix_resume_env.sh show'
#   ssh -n -p 2222 user@your-server 'bash ~/fix_resume_env.sh set WORKLOADS=canneal REGIMES="shared private"'
#
# WHY A SEPARATE SCRIPT. run_phase_a.sh's install-resume writes a crontab line
# with no environment, and build_queue reads WORKLOADS and REGIMES from the
# environment. So a sweep launched as
#
#     WORKLOADS=canneal REGIMES="shared private" run_phase_a.sh go
#
# would, after a reboot, rebuild the DEFAULT queue instead: canneal+barnes,
# shared only. The 33 private jobs would silently drop out, the barnes jobs
# would be skipped as already complete, and the resume would exit in seconds
# looking like it had worked. That is the 2026-09-17 failure again -- a sweep
# that dies at a reboot and nothing restarts it -- except this time it would
# report success.
#
# This is a separate script rather than a fix to run_phase_a.sh because a
# driver is currently executing that file, and bash reads a script
# incrementally: overwriting it mid-run is what produced the transient syntax
# errors on 2026-09-21 and 09-22. The permanent fix lands in run_phase_a.sh and
# takes effect on the next sweep.
set -uo pipefail

TAG="${TAG:-}"
SUFFIX=""; [ -n "$TAG" ] && SUFFIX="_$TAG"
HOMEDIR="${HOME:-/home/harshraj}"
LOG="$HOMEDIR/.phase_a$SUFFIX/reboot.log"

show() {
  echo "== current @reboot entries =="
  crontab -l 2>/dev/null | grep -n 'run_phase_a' | sed 's/^/   /' || echo "   (none)"
  echo
  echo "== what a resume would rebuild =="
  if [ "$(crontab -l 2>/dev/null | grep -c 'WORKLOADS=')" -gt 0 ]; then
    echo "   crontab carries an explicit queue definition:"
    crontab -l 2>/dev/null | grep -o "WORKLOADS='[^']*' *REGIMES='[^']*'" | sed 's/^/     /'
  else
    echo "   crontab carries NO WORKLOADS/REGIMES, so a resume would fall back to"
    echo "   the defaults: WORKLOADS='canneal barnes'  REGIMES='shared'"
    echo "   -- which is a DIFFERENT queue from whatever is running."
  fi
  echo
  echo "== what is actually queued right now =="
  local q="$HOMEDIR/.phase_a$SUFFIX/queue.txt"
  if [ -s "$q" ]; then
    echo "   $(wc -l < "$q") jobs"
    awk -F'|' '{print "     " $2 " " $3 "c " $4}' "$q" | sort | uniq -c | sort -rn | head
  else
    echo "   no queue file at $q"
  fi
}

set_env() {
  [ $# -gt 0 ] || { echo "ERROR: pass the assignments, e.g. WORKLOADS=canneal REGIMES=\"shared private\"" >&2; exit 1; }
  # Re-quote each assignment. The calling shell strips the quotes before this
  # script sees them, so "$*" would emit REGIMES=shared private and cron would
  # try to run `private`.
  local envs="" a k v
  for a in "$@"; do
    k="${a%%=*}"; v="${a#*=}"
    envs="$envs $k='$v'"
  done
  envs="${envs# }"
  local line="@reboot sleep 180 && $envs /bin/bash $HOMEDIR/run_phase_a.sh resume $TAG >> $LOG 2>&1"
  mkdir -p "$HOMEDIR/.phase_a$SUFFIX"
  # Remove EVERY prior entry for this tag, not just one shaped like the last.
  #
  # The first version filtered on "run_phase_a.sh resume $TAG\b". With an empty
  # TAG that is "...resume \b", and a word boundary after a space requires a
  # word character next -- the existing line had two spaces (an empty tag
  # interpolated), so it did not match and survived. The crontab ended up with
  # both the env-less entry and the new one, which on reboot race for the
  # driver lock; if the env-less one wins, the queue is rebuilt wrong, which is
  # the exact failure this script exists to prevent.
  local pat
  if [ -n "$TAG" ]; then
    pat="run_phase_a\.sh resume[[:space:]]+$TAG([[:space:]]|$)"
  else
    pat="run_phase_a\.sh resume[[:space:]]*(>|$)"
  fi
  (crontab -l 2>/dev/null | grep -Ev "$pat"; echo "$line") | crontab -
  echo "installed:"
  crontab -l | grep 'run_phase_a' | sed 's/^/   /'
  echo
  echo "A reboot will now rebuild the queue with: $envs"
}

case "${1:-show}" in
  show) show ;;
  set)  shift; set_env "$@" ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
