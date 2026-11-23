#!/usr/bin/env bash
# Q16's ChampSim half on the server (breadth_bc_design_2026-11-10.md,
# amendments 5 and 8): uploads the harness's four files to ~/q16cs/root and
# q16cs_server.sh (.new + mv), then starts both forms detached on the server.
# Nothing runs on the laptop. gem5's half: scripts/micro_all.sh q16 / q16pull.
#
#   scripts/q16cs_all.sh go       # owner's word
#   scripts/q16cs_all.sh status   # read-only
#   scripts/q16cs_all.sh pull     # read-only: status, then the logs and counts to simulator/results/micro_champsim_q16/
#   scripts/q16cs_all.sh stop     # ends both forms (only their own session)
#   scripts/q16cs_all.sh diag     # q16_results_2026-11-13.md: upload, then s16 at level 2 in the barrier form,
#                                 # event log kept (owner's word)
#   scripts/q16cs_all.sh diagpull # read-only: that run's logs, counts and event log to simulator/results/micro_champsim_q16/
set -uo pipefail
PORT="${PORT:-2222}"
SRV="${SRV:-user@your-server}"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PREREG="bench/policy_sanity/breadth_bc_design_2026-11-10.md"
FILES="bench/micro_champsim.sh bench/micro_trim.py bench/coherence_micro.c simulator/scripts/make_config.py"
OUT="$LROOT/simulator/results/micro_champsim_q16"
SV="bash $SRV_HOME/q16cs_server.sh"
MODE="${1:-}"
case "$MODE" in go|status|pull|stop|diag|diagpull) ;; *) echo "usage: $0 go|status|pull|stop|diag|diagpull"; exit 1 ;; esac
DIAG="barrier s16 2"; DIAGD="diag_barrier_s16_L2"

if [ "$MODE" = go ] || [ "$MODE" = diag ]; then
  bash -n "$LROOT/scripts/q16cs_server.sh" || { echo "q16cs_server.sh does not parse"; exit 1; }
  grep -q '^## Amendment 8, 2026-11-12' "$LROOT/$PREREG" || { echo "$PREREG has no amendment 8"; exit 1; }
  if [ "$MODE" = diag ]; then
    git -C "$LROOT" ls-files --error-unmatch bench/policy_sanity/q16_results_2026-11-13.md > /dev/null 2>&1 || { echo "the diagnosis note is not committed"; exit 1; }
    [ -z "$(git -C "$LROOT" status --porcelain -- bench/policy_sanity/q16_results_2026-11-13.md)" ] || { echo "the diagnosis note has uncommitted changes"; exit 1; }
  fi
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" > /dev/null 2>&1 || { echo "the pre-registration is not committed"; exit 1; }
  # shellcheck disable=SC2086
  [ -z "$(git -C "$LROOT" status --porcelain -- $FILES scripts/q16cs_server.sh scripts/q16cs_all.sh "$PREREG")" ] \
    || { echo "uncommitted changes in what is uploaded -- commit first"; exit 1; }
fi
CTL="$HOME/.ssh/cm-q16cs-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -o ConnectTimeout=30 -fN "$SRV" \
  || { echo "could not connect (a locked key agent? see CLAUDE.md, server access)"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

case "$MODE" in
  go|diag)
    R "mkdir -p $SRV_HOME/q16cs/root/bench $SRV_HOME/q16cs/root/simulator/scripts" || exit 1
    for f in $FILES; do
      scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/q16cs/root/$f" || { echo "upload of $f failed"; exit 1; }
    done
    R "chmod +x $SRV_HOME/q16cs/root/simulator/scripts/make_config.py"
    l=$(cd "$LROOT" && cat $FILES | md5sum | cut -c1-32)
    r=$(R "cd $SRV_HOME/q16cs/root && cat $FILES | md5sum | cut -c1-32")
    [ "$l" = "$r" ] || { echo "the uploaded files do not match the laptop's"; exit 1; }
    scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/q16cs_server.sh" "$SRV:$SRV_HOME/q16cs_server.sh.new" || { echo "upload failed"; exit 1; }
    R "mv -f $SRV_HOME/q16cs_server.sh.new $SRV_HOME/q16cs_server.sh" || exit 1
    echo "   uploaded: the harness's four files (match) and q16cs_server.sh"
    if [ "$MODE" = diag ]; then R "$SV diag $DIAG" | sed 's/^/   /'; else R "$SV go" | sed 's/^/   /'; fi
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
    echo; echo "Later:  $0 status   /   $0 pull" ;;
  status) R "$SV status" ;;
  stop) R "$SV stop" ;;
  diagpull)
    R "$SV status" | sed 's/^/   /'
    mkdir -p "$OUT/$DIAGD"
    rsync -a --copy-links -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/q16cs/$DIAGD/" "$OUT/$DIAGD/" \
      && rsync -a -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/q16cs/form_$DIAGD.log" "$SRV:$SRV_HOME/q16cs/RC_$DIAGD" "$OUT/$DIAGD/" \
      && echo "   pulled to simulator/results/micro_champsim_q16/$DIAGD/: $(ls "$OUT/$DIAGD" | tr '\n' ' ')" ;;
  pull)
    R "$SV status" | sed 's/^/   /'
    mkdir -p "$OUT"
    rsync -a --copy-links --include='out_*/' --include='out_*/**' --include='form_*.log' --include='driver.log' --include='RC_*' --exclude='*' \
      -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/q16cs/" "$OUT/" \
      && echo "   pulled to simulator/results/micro_champsim_q16/: $(ls "$OUT"/out_*/*.xline 2>/dev/null | wc -l) counts" ;;
esac
