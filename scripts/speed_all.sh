#!/usr/bin/env bash
# The speed test (bench/policy_sanity/speed_design_2026-10-18.md): gem5 against
# ChampSim on the standard barnes. One command, one password.
#
#   scripts/speed_all.sh          # upload and start 12 runs on the server (detached; about 1-3 h)
#   scripts/speed_all.sh pull     # later: status, the report, and the files
#
# Writes only ~/speed and ~/speed_server.sh on the server; touches no binary,
# trace, run or queue. Output: simulator/results/speed/ (gitignored).
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT="$LROOT/simulator/results/speed"
MODE="${1:-}"
case "$MODE" in ""|pull) ;; *) echo "usage: $0 [pull]"; exit 1 ;; esac
PREREG="bench/policy_sanity/speed_design_2026-10-18.md"
if [ -z "$MODE" ]; then
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  [ -z "$(git -C "$LROOT" status --porcelain -- scripts/speed_server.sh "$PREREG")" ] || { echo "uncommitted changes in what is uploaded -- commit first"; exit 1; }
fi
CTL="$HOME/.ssh/cm-speed-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -fN "$SRV" \
  || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

if [ -z "$MODE" ]; then
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/speed_server.sh" "$SRV:$SRV_HOME/speed_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/speed_server.sh.new $SRV_HOME/speed_server.sh" || exit 1
  echo "   uploaded"
  R "bash $SRV_HOME/speed_server.sh go" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
  echo; echo "Started. In about 2 hours:  scripts/speed_all.sh pull"
else
  R "bash $SRV_HOME/speed_server.sh status" | sed 's/^/   /'
  echo
  R "bash $SRV_HOME/speed_server.sh report" | tee "$OUT.report.txt" 2>/dev/null | sed 's/^/   /'
  mkdir -p "$OUT"
  rsync -a --copy-links --include='*/' --include='time.txt' --include='run.log' --include='stats.txt' --include='config.ini' \
    --include='cfg.json' --include='o3_name.txt' --exclude='*' -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/speed/" "$OUT/" \
    && echo "   pulled to simulator/results/speed/"
  echo "Tell Claude: speed pulled."
fi
