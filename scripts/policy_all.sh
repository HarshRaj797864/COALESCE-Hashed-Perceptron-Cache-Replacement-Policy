#!/usr/bin/env bash
# Step 5, the policy runs on the final tool (bench/policy_sanity/policy_rerun_design_2026-10-19.md).
# One command, one password.
#
#   scripts/policy_all.sh          # upload; the 171 job lines to ~/sync_pol/JOBS; start the chain
#                                  # (traces canneal 16 first if missing, then the runs, 16-core first)
#   scripts/policy_all.sh status
#
# The chain is sync_server.sh VARIANT=pol: the final binary (the g6 build of
# 2026-10-27, Q0 and Q0m passed against champsim_g5_034cd735; scripts/syncg6_all.sh), the synchronised traces in traces/sync_mx/,
# trees phaseA_b3_p2_*. Detached; no auto-resume (run this again after a
# reboot: it skips traced programs and finished runs).
# POL_JOBS runs at once (default 16; the server's other jobs share its 48
# cores). Concurrency changes no result: each run is deterministic.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
MODE="${1:-go}"
case "$MODE" in go|status) ;; *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;; esac
UPLOAD="sync_server.sh sync_cut.py trace_mix.c sync_anchor.py"
if [ "$MODE" = go ]; then
  git -C "$LROOT" ls-files --error-unmatch bench/policy_sanity/policy_rerun_design_2026-10-19.md > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  for f in $UPLOAD policy_jobs.py; do
    [ -z "$(git -C "$LROOT" status --porcelain -- "scripts/$f")" ] || { echo "scripts/$f has uncommitted changes -- commit first"; exit 1; }
  done
  JOBS_FILE="$(mktemp)"; trap 'rm -f "$JOBS_FILE"' EXIT
  python3 "$LROOT/scripts/policy_jobs.py" > "$JOBS_FILE" || { echo "policy_jobs.py failed"; exit 1; }
  [ "$(wc -l < "$JOBS_FILE")" = 171 ] || { echo "expected 171 job lines"; exit 1; }
fi
CTL="$HOME/.ssh/cm-policy-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL" "${JOBS_FILE:-}"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
if [ "$MODE" = go ]; then
  if R "[ -f $SRV_HOME/sync_pol/.driver.pid ] && kill -0 \$(cat $SRV_HOME/sync_pol/.driver.pid 2>/dev/null) 2>/dev/null"; then echo "the step-5 chain is already running -- scripts/policy_all.sh status"; exit 0; fi
  for f in $UPLOAD; do
    scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/$f.new" || { echo "upload of $f failed"; exit 1; }
    R "mv -f $SRV_HOME/$f.new $SRV_HOME/$f" || exit 1
  done
  R "mkdir -p $SRV_HOME/sync_pol" || exit 1
  scp -q -P "$PORT" -o ControlPath="$CTL" "$JOBS_FILE" "$SRV:$SRV_HOME/sync_pol/JOBS" || { echo "upload of the job lines failed"; exit 1; }
  echo "   uploaded; 171 job lines in ~/sync_pol/JOBS"
  R "VARIANT=pol JOBS=${POL_JOBS:-16} bash $SRV_HOME/sync_server.sh chain" 2>&1 | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "the chain did not start"; exit 1; }
  echo; echo "Started. Where it is: scripts/policy_all.sh status (or scripts/pull_results.sh)"
else
  R "VARIANT=pol bash $SRV_HOME/sync_server.sh status" 2>&1
fi
