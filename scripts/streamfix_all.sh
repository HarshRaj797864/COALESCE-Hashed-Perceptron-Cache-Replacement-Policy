#!/usr/bin/env bash
# Step 4's same-stream failures, the diagnosis
# (bench/policy_sanity/stream_fix_design_2026-11-02.md). One command, one password.
#
#   scripts/streamfix_all.sh          # upload the sources and start the runs on the server (detached; ~2-4 h)
#   scripts/streamfix_all.sh pull     # later: status, and the counts -> simulator/results/streamfix/
#   scripts/streamfix_all.sh more lunc   # LU non-contiguous (rule c): its counter runs with both CPUIDs, once
#                                        # the first round has ended and lunc is sized (detached; waits)
#   scripts/streamfix_all.sh redo [lunc] # amendment 2 (2026-11-04): upload, then the round again after the
#                                        # failed CPUID dump (gem5 aborts on leaf 0xd subleaf 2); the first
#                                        # round's logs go to ~/streamfix/r1, its host runs stand if the
#                                        # counter rebuilds to the same file; then 'more' for the programs named
#
# Writes only ~/streamfix and ~/streamfix_server.sh on the server; touches no
# binary, trace, run or queue.
set -uo pipefail
PORT=2222
SRV="user@your-server"
SRV_HOME="${SRV_HOME:-/home/harshraj}"
LROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT="$LROOT/simulator/results/streamfix"
MODE="${1:-}"
case "$MODE" in ""|pull|more|redo) ;; *) echo "usage: $0 [pull | more <program>... | redo [<program>...]]"; exit 1 ;; esac
[ "$MODE" != more ] || [ $# -ge 2 ] || { echo "usage: $0 more <program>..."; exit 1; }
PREREG="bench/policy_sanity/stream_fix_design_2026-11-02.md"
UP=(simulator/tracer/stream_count/stream_count.cpp simulator/tracer/stream_count/Makefile scripts/cpuid_dump.c bench/stream_micro.c scripts/trace_mix.c scripts/cpuid_qe.py)
if [ "$MODE" = more ]; then
  [ -z "$(git -C "$LROOT" status --porcelain -- scripts/streamfix_server.sh)" ] || { echo "uncommitted changes in scripts/streamfix_server.sh -- commit first"; exit 1; }
fi
if [ -z "$MODE" ] || [ "$MODE" = redo ]; then
  git -C "$LROOT" ls-files --error-unmatch "$PREREG" "${UP[@]}" > /dev/null 2>&1 || { echo "the pre-registration or an uploaded file is not committed"; exit 1; }
  [ -z "$(git -C "$LROOT" status --porcelain -- scripts/streamfix_server.sh "$PREREG" "${UP[@]}")" ] || { echo "uncommitted changes in what is uploaded -- commit first"; exit 1; }
fi
if [ "$MODE" = redo ]; then
  # read the log whole first (piped into grep -q, git dies of SIGPIPE under pipefail)
  subjects=$(git -C "$LROOT" log --format=%s -- "$PREREG")
  grep -q '^prereg(streamfix): amendment 2' <<< "$subjects" || { echo "amendment 2 (the CPUID dump leaf by leaf) is not committed"; exit 1; }
fi
CTL="$HOME/.ssh/cm-streamfix-$$"
mkdir -p "$HOME/.ssh"
cleanup() { ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true; rm -f "$CTL"; }
trap cleanup EXIT
echo "One connection -- the password is asked once."
ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=30m -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
  -o ConnectTimeout=30 -fN "$SRV" || { echo "could not connect"; exit 1; }
R() { ssh -n -p "$PORT" -o ControlPath="$CTL" "$SRV" "$@"; }

if [ -z "$MODE" ]; then
  R "mkdir -p $SRV_HOME/streamfix/src" || exit 1
  for f in "${UP[@]}"; do
    scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/streamfix/src/$(basename "$f")" || { echo "upload of $f failed"; exit 1; }
  done
  # the runner: to a new name, then mv (a live driver keeps its own copy)
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/streamfix_server.sh" "$SRV:$SRV_HOME/streamfix_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/streamfix_server.sh.new $SRV_HOME/streamfix_server.sh" || exit 1
  echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
  R "bash $SRV_HOME/streamfix_server.sh go" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
  echo; echo "Started. In about 3 hours:  scripts/streamfix_all.sh pull"
elif [ "$MODE" = redo ]; then
  shift
  R "bash $SRV_HOME/streamfix_server.sh status" | head -1 | sed 's/^/   before: /'
  # the runner first, to a new name, then mv; its redo refuses while anything of streamfix runs
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/streamfix_server.sh" "$SRV:$SRV_HOME/streamfix_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/streamfix_server.sh.new $SRV_HOME/streamfix_server.sh" || exit 1
  if R "f=$SRV_HOME/streamfix/.driver.pid; [ -f \$f ] && kill -0 \$(cat \$f) 2>/dev/null || { [ -f \$f.more ] && kill -0 \$(cat \$f.more) 2>/dev/null; }"; then
    echo "   streamfix is running (driver or 'more') -- nothing changed"; exit 1
  fi
  for f in "${UP[@]}"; do
    scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/$f" "$SRV:$SRV_HOME/streamfix/src/$(basename "$f").new" || { echo "upload of $f failed"; exit 1; }
    R "mv -f $SRV_HOME/streamfix/src/$(basename "$f").new $SRV_HOME/streamfix/src/$(basename "$f")" || exit 1
  done
  echo "   uploaded ($(git -C "$LROOT" rev-parse --short HEAD))"
  R "bash $SRV_HOME/streamfix_server.sh redo" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
  if [ $# -ge 1 ]; then
    R "bash $SRV_HOME/streamfix_server.sh more $*" | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "'more $*' did not start (the round runs regardless)"; exit 1; }
  fi
  echo; echo "Started. QE in about 10 minutes, the runs about 20 minutes after:  scripts/streamfix_all.sh pull"
elif [ "$MODE" = more ]; then
  shift
  # the runner: to a new name, then mv (the live driver keeps its own copy)
  scp -q -P "$PORT" -o ControlPath="$CTL" "$LROOT/scripts/streamfix_server.sh" "$SRV:$SRV_HOME/streamfix_server.sh.new" || { echo "upload failed"; exit 1; }
  R "mv -f $SRV_HOME/streamfix_server.sh.new $SRV_HOME/streamfix_server.sh" || exit 1
  echo "   uploaded streamfix_server.sh ($(git -C "$LROOT" rev-parse --short HEAD))"
  R "bash $SRV_HOME/streamfix_server.sh more $*" | sed 's/^/   /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || { echo "did not start"; exit 1; }
else
  R "bash $SRV_HOME/streamfix_server.sh status" | sed 's/^/   /'
  mkdir -p "$OUT"
  # the counts, summaries, routine tables, CPUID files and logs; not the programs' own output
  rsync -a --copy-links --max-size=20m \
    --include='*/' --include='c.*' --include='STATUS' --include='PROGS' --include='err.txt' --include='*.cpuid' --include='facts.txt' \
    --include='driver.log' --include='DONE' --include='run.log' --include='dump.txt' --include='diff.txt' --include='out.txt' \
    --include='COUNTER_MD5' --include='gem5.cpuid.failed' --prune-empty-dirs \
    --exclude='*' -e "ssh -p $PORT -o ControlPath=$CTL" "$SRV:$SRV_HOME/streamfix/" "$OUT/" \
    && echo "   pulled to simulator/results/streamfix/"
  echo "Tell Claude: streamfix pulled."
fi
