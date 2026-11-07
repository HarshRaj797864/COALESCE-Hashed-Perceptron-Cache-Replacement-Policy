#!/usr/bin/env bash
# Run the read-only server audit (scripts/verify_b3.sh) and keep its output on
# the laptop. One command, one password; nothing on the server is changed
# except two report-only scripts in ~ and the count's output in ~/verify_b3_rmw.
#
#   scripts/verify_b3_all.sh         # the audit; also starts the trace count on the server
#   scripts/verify_b3_all.sh rmw     # the trace count's result, 10-20 minutes later
#
# Output: simulator/results/verify_b3[_rmw]_<time>.txt (gitignored). The first
# form also compares the server's source md5s with this checkout's files.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"   # overridable only to test this script
LROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-}"
case "$MODE" in ""|rmw) ;; *) echo "usage: $0 [rmw]"; exit 1 ;; esac
OUT="$LROOT/simulator/results/verify_b3${MODE:+_$MODE}_$(date +%Y%m%d_%H%M%S).txt"
mkdir -p "$(dirname "$OUT")"

CTL="$HOME/.ssh/cm-verify-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=10m -fN "$SRV" || { echo "could not connect"; exit 1; }

if [ -z "$MODE" ]; then
  # Report-only scripts, not queue drivers: a plain copy is safe (CLAUDE.md).
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/verify_b3.sh" "$LROOT/scripts/count_rmw.py" "$SRV:$SRV_HOME/" || { echo "upload failed"; exit 1; }
fi
ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "bash ~/verify_b3.sh $MODE" > "$OUT" 2>&1 || { echo "the audit failed; see $OUT"; exit 1; }
echo "saved: $OUT ($(wc -l < "$OUT") lines)"

if [ -n "$MODE" ]; then cat "$OUT"; exit 0; fi

echo
echo "== server sources against this checkout ($(git -C "$LROOT" rev-parse --short HEAD)$(git -C "$LROOT" diff --quiet -- simulator || echo ', with uncommitted simulator changes')) =="
bad=0; n=0
while read -r sum path; do
  n=$((n + 1))
  if [ "$(md5sum < "$LROOT/simulator/$path" 2>/dev/null | cut -c1-32)" = "$sum" ]; then printf '   same     %s\n' "$path"
  else printf '   DIFFERS  %s\n' "$path"; bad=$((bad + 1)); fi
done < <(awk '/^== 1\. SOURCE/ { on = 1; next } /^== 2\./ { on = 0 } on && $1 ~ /^[0-9a-f]{32}$/ { print $1, $2 }' "$OUT")
[ "$n" -gt 0 ] || { echo "   no source md5s in the audit output -- see $OUT"; exit 1; }
echo "   $n files, $bad differ"
grep -E '^   bin/' "$OUT"
echo
echo "== runs =="
grep -cE '^   phaseA_b3_v' "$OUT" | sed 's/^/   logs audited: /'
awk '/^== 2\. RUNS/ { on = 1; next } /^== 3\./ { on = 0 } on' "$OUT" | grep -E 'warmup|wrapped' | sed 's/log written.*//' | sort | uniq -c | sed 's/^/   /'
echo
sed -n '/^== 4\./,$p' "$OUT"
echo "Tell Claude: audit saved.  Then, in 10-20 minutes:  scripts/verify_b3_all.sh rmw"
