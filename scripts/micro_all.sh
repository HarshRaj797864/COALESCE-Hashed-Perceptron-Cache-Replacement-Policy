#!/usr/bin/env bash
# gem5 on coherence_micro, the program with known coherence counts
# (bench/policy_sanity/micro_design_2026-10-17.md). One command, one password.
#
#   scripts/micro_all.sh          # upload, build on the server, start 11 gem5 runs (detached; ~30-60 min)
#   scripts/micro_all.sh pull     # later: status, and bring the stats down
#
# Writes only ~/micro and ~/micro_server.sh on the server; touches no run,
# binary or queue. Output: simulator/results/micro_gem5/ (gitignored).
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT="$LROOT/simulator/results/micro_gem5"
MODE="${1:-}"
case "$MODE" in ""|pull) ;; *) echo "usage: $0 [pull]"; exit 1 ;; esac
PREREG="bench/policy_sanity/micro_design_2026-10-17.md"

if [ -z "$MODE" ]; then
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  [ -z "$(git -C "$LROOT" status --porcelain -- bench/coherence_micro.c scripts/micro_server.sh "$PREREG")" ] \
    || { echo "uncommitted changes in what is uploaded -- commit first"; exit 1; }
fi
CTL="$HOME/.ssh/cm-micro-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -fN "$SRV" \
  || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

if [ -z "$MODE" ]; then
  R "mkdir -p $SRV_HOME/micro" || exit 1
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/bench/coherence_micro.c" "$SRV:$SRV_HOME/micro/coherence_micro.c" || { echo "upload failed"; exit 1; }
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/micro_server.sh" "$SRV:$SRV_HOME/micro_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/micro_server.sh.new $SRV_HOME/micro_server.sh" || exit 1
  echo "   uploaded (program md5 $(md5sum < "$LROOT/bench/coherence_micro.c" | cut -c1-12))"
  R "bash $SRV_HOME/micro_server.sh go" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
  echo; echo "Started. In about an hour:  scripts/micro_all.sh pull"
else
  R "bash $SRV_HOME/micro_server.sh status" | sed 's/^/   /'
  mkdir -p "$OUT"
  rsync -a --copy-links --include='*/' --include='stats.txt' --include='run.log' --include='config.ini' --exclude='*' \
    -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/micro/gem5/" "$OUT/" && echo "   pulled: $(find "$OUT" -name stats.txt | wc -l) stats files"
  echo "Tell Claude: micro pulled."
fi
