#!/usr/bin/env bash
# The 2026-10-17 validation round: run the read-only server audit and bring
# its output to the laptop. One command, one password. Nothing on the server
# changes except ~/audit, ~/audit_server.sh and ~/trace_mix.c.
#
#   scripts/audit_all.sh           # collect (a few minutes) + start the trace count (about 1 h, detached)
#   scripts/audit_all.sh traces    # later: pull the trace count (says how far it is if not done)
#
# Output: simulator/results/audit/ (gitignored): collect_<time>/ and traces/.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT="$LROOT/simulator/results/audit"
MODE="${1:-}"
case "$MODE" in ""|traces) ;; *) echo "usage: $0 [traces]"; exit 1 ;; esac
mkdir -p "$OUT"

CTL="$HOME/.ssh/cm-audit-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=60m \
    -o ServerAliveInterval=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }
RS=(rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL")

if [ -z "$MODE" ]; then
  echo; echo "== upload the audit (report-only) =="
  for f in audit_server.sh trace_mix.c; do
    scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/$f" "$SRV:$SRV_HOME/$f.new" || { echo "upload of $f failed"; exit 1; }
    R "mv -f $SRV_HOME/$f.new $SRV_HOME/$f" || exit 1
  done
  r=$(R "md5sum < $SRV_HOME/audit_server.sh | cut -c1-32")
  [ "$r" = "$(md5sum < "$LROOT/scripts/audit_server.sh" | cut -c1-32)" ] || { echo "~/audit_server.sh does not match"; exit 1; }
  echo "   uploaded"

  echo; echo "== collect (read-only; a few minutes) =="
  R "bash $SRV_HOME/audit_server.sh collect" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "collect failed"; exit 1; }

  echo; echo "== bring it down =="
  "${RS[@]}" --include='collect_*.tar.xz' --exclude='*' "$SRV:$SRV_HOME/audit/" "$OUT/" || { echo "rsync failed"; exit 1; }
  latest=$(ls -1t "$OUT"/collect_*.tar.xz | head -1)
  tar -C "$OUT" -xJf "$latest" && echo "   $(basename "$latest" .tar.xz)/ unpacked ($(du -sh "${latest%.tar.xz}" | cut -f1))"

  echo; echo "== start the trace count (detached, niced) =="
  R "bash $SRV_HOME/audit_server.sh traces" | sed 's/^/   /'
  echo
  echo "Tell Claude: audit collected.  In about an hour:  scripts/audit_all.sh traces"
else
  R "bash $SRV_HOME/audit_server.sh traces-status" | sed 's/^/   /'
  mkdir -p "$OUT/traces"
  "${RS[@]}" "$SRV:$SRV_HOME/audit/traces/" "$OUT/traces/" || { echo "rsync failed"; exit 1; }
  echo "   pulled: $(ls "$OUT"/traces/*.done 2>/dev/null | wc -l) traces counted"
  echo "Tell Claude: traces pulled."
fi
