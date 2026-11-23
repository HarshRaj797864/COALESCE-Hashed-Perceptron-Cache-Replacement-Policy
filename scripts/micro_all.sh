#!/usr/bin/env bash
# gem5 on coherence_micro, the program with known coherence counts
# (bench/policy_sanity/micro_design_2026-10-17.md). One command, one password.
#
#   scripts/micro_all.sh          # upload, build on the server, start 11 gem5 runs (detached; ~30-60 min)
#   scripts/micro_all.sh pull     # later: status, and bring the stats down
#   scripts/micro_all.sh q16      # Q16 (breadth_bc amendment 5): 16 threads, 16 CPUs, 12 runs into ~/micro16 (owner's word)
#   scripts/micro_all.sh q16pull  # later: status, and Q16's stats to simulator/results/micro_gem5_16/
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
case "$MODE" in ""|pull|q16|q16pull) ;; *) echo "usage: $0 [pull|q16|q16pull]"; exit 1 ;; esac
PREREG="bench/policy_sanity/micro_design_2026-10-17.md"
RW=micro; ENVS=""
if [ "$MODE" = q16 ] || [ "$MODE" = q16pull ]; then
  PREREG="bench/policy_sanity/breadth_bc_design_2026-11-10.md"; OUT="$LROOT/simulator/results/micro_gem5_16"; RW=micro16
  ENVS="NT=16 ACT0=12 W=$SRV_HOME/micro16 CASES='pp_lock pp_store pp_rmw readers upgrade ctl priv_E priv_S llc_out offchip s16'"
  [ "$MODE" = q16 ] && { grep -q '^## Amendment 5, 2026-11-12' "$LROOT/$PREREG" || { echo "$PREREG has no amendment 5 (Q16)"; exit 1; }; }
fi

if [ -z "$MODE" ] || [ "$MODE" = q16 ]; then
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  [ -z "$(git -C "$LROOT" status --porcelain -- bench/coherence_micro.c scripts/micro_server.sh "$PREREG")" ] \
    || { echo "uncommitted changes in what is uploaded -- commit first"; exit 1; }
fi
CTL="$HOME/.ssh/cm-micro-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -fN "$SRV" \
  || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

if [ -z "$MODE" ] || [ "$MODE" = q16 ]; then
  R "mkdir -p $SRV_HOME/$RW" || exit 1
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/bench/coherence_micro.c" "$SRV:$SRV_HOME/$RW/coherence_micro.c" || { echo "upload failed"; exit 1; }
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/micro_server.sh" "$SRV:$SRV_HOME/micro_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/micro_server.sh.new $SRV_HOME/micro_server.sh" || exit 1
  echo "   uploaded (program md5 $(md5sum < "$LROOT/bench/coherence_micro.c" | cut -c1-12))"
  R "$ENVS bash $SRV_HOME/micro_server.sh go" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
  echo; echo "Started. Later:  scripts/micro_all.sh ${MODE:+q16}pull"
else
  R "$ENVS bash $SRV_HOME/micro_server.sh status" | sed 's/^/   /'
  mkdir -p "$OUT"
  rsync -a --copy-links --include='*/' --include='stats.txt' --include='run.log' --include='config.ini' --exclude='*' \
    -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/$RW/gem5/" "$OUT/" && echo "   pulled: $(find "$OUT" -name stats.txt | wc -l) stats files"
fi
