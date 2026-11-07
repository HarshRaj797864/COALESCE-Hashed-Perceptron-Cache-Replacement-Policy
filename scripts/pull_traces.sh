#!/usr/bin/env bash
# Copy the 4-thread canneal and barnes traces from the server to the laptop
# (xz-compressed: ~230 MB + ~170 MB). One command, one password; read-only on
# the server. simulator/traces/ is gitignored.
#
#   scripts/pull_traces.sh
#
# Why: with the real traces here, the exact checks can run on them
# (issued + forwarded RMW loads against count_rmw.py's count), and a simulator
# change can be tried on the real 4-core workloads before it goes to the
# server. ocean_4t is left there: 48 GB, uncompressed.
set -uo pipefail
PORT=2222
SRV="user@your-server"
RS="/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces"
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
LT="$LROOT/simulator/traces"

CTL="$HOME/.ssh/cm-traces-$$"
mkdir -p "$HOME/.ssh" "$LT/canneal_4t"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -fN "$SRV" || { echo "could not connect"; exit 1; }

# Absolute server paths and --copy-links, always (CLAUDE.md).
rsync -a --copy-links --info=progress2 -e "ssh -p $PORT -o ControlPath=$CTL" \
  --include='canneal[1-4].champsimtrace.xz' --exclude='*' "$SRV:$RS/canneal_4t/" "$LT/canneal_4t/" || { echo "canneal_4t: rsync failed"; exit 1; }
rsync -a --copy-links --info=progress2 -e "ssh -p $PORT -o ControlPath=$CTL" \
  --include='barnes_4t[0-3].champsimtrace.xz' --exclude='*' "$SRV:$RS/" "$LT/" || { echo "barnes_4t: rsync failed"; exit 1; }

echo
echo "== server md5s against the copies =="
bad=0
while read -r sum path; do
  f="$LT/${path#"$RS"/}"
  if [ "$(md5sum < "$f" 2>/dev/null | cut -c1-32)" = "$sum" ]; then printf '   same     %s  (%s)\n' "${path#"$RS"/}" "$(du -h "$f" | cut -f1)"
  else printf '   DIFFERS  %s\n' "${path#"$RS"/}"; bad=1; fi
done < <(ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "md5sum $RS/canneal_4t/canneal[1-4].champsimtrace.xz $RS/barnes_4t[0-3].champsimtrace.xz")
[ "$bad" = 0 ] && echo "Done. Tell Claude: traces pulled." || { echo "a copy differs from the server's -- rerun"; exit 1; }
