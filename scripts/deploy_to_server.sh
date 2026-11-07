#!/usr/bin/env bash
# Deploy the migrated tree (ChampSim develop + our eleven audited policies) to
# the server.
#
#   scripts/deploy_to_server.sh            # dry run -- shows every change, does nothing
#   scripts/deploy_to_server.sh --go       # actually deploy
#
# Runs on the LAPTOP (rsync's local side). Nothing to scp first.
#
# WHAT IT WILL NOT TOUCH, ever:
#   simulator/traces/    331 GB of freshly regenerated, audited traces
#   simulator/results/   every historical result log
#   simulator/tracer/    pin, splash-3 sources, the built tracer
#   simulator/bin/ vcpkg*/ archive_logs/
# These are excluded by path, and no rsync in this script has --delete pointed
# at a directory containing them.
#
# WHY --delete IS USED AT ALL, on source directories only:
#   simulator/Makefile globs every *.cc under branch/ btb/ prefetcher/
#   replacement/ and compiles all of it. The server still carries module
#   directories from the old one-binary-per-policy model (cb_0_0/, cb_0_20/,
#   cb_40_0/, cb_150_75/ and friends) written against the OLD module interface.
#   Left in place they are compiled, and the build fails. Syncing without
#   --delete would therefore produce a tree that cannot build.
#
# Absolute server paths and --copy-links throughout: a previous session caused
# damage with relative paths plus symlinks.
set -euo pipefail

PORT=2222
SRV="user@your-server"
RROOT="/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
LROOT="/home/rajharsh/programming-playground/repos/COALESCE"

GO=0
[ "${1:-}" = "--go" ] && GO=1

say() { printf '\n== %s ==\n' "$*"; }

# One password, not fifteen. Each rsync and ssh below is a separate connection
# and would prompt separately; OpenSSH connection multiplexing lets them all
# ride one authenticated master. The socket path is kept short -- a unix socket
# path over ~104 characters silently fails to bind.
#
# COALESCE_CTL: ride a master connection the CALLER already opened (one
# password for a whole multi-step run, scripts/ocean4_all.sh). It must be
# live -- there is no silent fallback to a second prompt -- and it is left
# open for the caller, which owns it.
mkdir -p "$HOME/.ssh"
if [ -n "${COALESCE_CTL:-}" ]; then
  CTL="$COALESCE_CTL"
  ssh -O check -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null \
    || { echo "COALESCE_CTL=$CTL is not a live master connection"; exit 1; }
else
  CTL="$HOME/.ssh/cm-coalesce-$$"
  cleanup() {
    ssh -O exit -o ControlPath="$CTL" -p "$PORT" "$SRV" 2>/dev/null || true
    rm -f "$CTL"
  }
  trap cleanup EXIT

  echo "Opening one shared connection -- you will be asked for the password once."
  ssh -p "$PORT" -o ControlMaster=yes -o ControlPath="$CTL" -o ControlPersist=15m -fN "$SRV" \
    || { echo "could not open the master connection"; exit 1; }
fi

SSH=(ssh -p "$PORT" -o ControlPath="$CTL")
RSYNC=(rsync -a --copy-links --human-readable --itemize-changes -e "ssh -p $PORT -o ControlPath=$CTL")
[ "$GO" -eq 1 ] || RSYNC+=(--dry-run)

if [ "$GO" -eq 0 ]; then
  cat << 'BANNER'
DRY RUN. Nothing is changed. Lines starting with:
   >f  a file that would be sent       *deleting  a file that would be removed
   cd  a directory that would be made
Re-run with --go to apply.
BANNER
fi

# Source directories: local tree is the source of truth, stale files must go.
# None of these contains traces, results or the tracer.
SRC_DIRS=(
  simulator/inc
  simulator/src
  simulator/branch
  simulator/btb
  simulator/prefetcher
  simulator/replacement
  simulator/config
  simulator/test
  simulator/scripts
  bench
)

# Loose files: copied over, nothing removed.
FILES=(
  simulator/Makefile
  simulator/global.options
  simulator/module.options
  simulator/vcpkg.json
  simulator/.gitignore
)

if [ "$GO" -eq 1 ]; then
  say "backing up the server's current source tree first"
  "${SSH[@]}" "$SRV" "cd $RROOT && tar czf \$HOME/pre_deploy_backup_\$(date +%Y%m%d_%H%M%S).tar.gz \
      --exclude=simulator/traces --exclude=simulator/results --exclude=simulator/bin \
      --exclude=simulator/vcpkg --exclude=simulator/vcpkg_installed --exclude=simulator/tracer/pin \
      simulator/inc simulator/src simulator/replacement simulator/branch simulator/btb \
      simulator/prefetcher simulator/Makefile simulator/*.json bench 2>/dev/null; \
      ls -la \$HOME/pre_deploy_backup_*.tar.gz | tail -2"
fi

for d in "${SRC_DIRS[@]}"; do
  [ -d "$LROOT/$d" ] || { echo "skip (absent locally): $d"; continue; }
  say "$d   (--delete: local is source of truth)"
  "${RSYNC[@]}" --delete "$LROOT/$d/" "$SRV:$RROOT/$d/"
done

say "loose files (no deletion)"
for f in "${FILES[@]}"; do
  [ -f "$LROOT/$f" ] || continue
  "${RSYNC[@]}" "$LROOT/$f" "$SRV:$RROOT/$f"
done

say "run configs (no deletion)"
"${RSYNC[@]}" --include='*.json' --exclude='*' "$LROOT/simulator/" "$SRV:$RROOT/simulator/"

if [ "$GO" -eq 1 ]; then
  say "removing generated build files so they regenerate on the server"
  # absolute.options pointed at a SIBLING checkout for nine months and silently
  # supplied every translation unit's -I path, so the build read another tree's
  # headers. The Makefile now regenerates it from $(realpath inc); it must not
  # arrive from here carrying laptop paths.
  "${SSH[@]}" "$SRV" "rm -f $RROOT/simulator/absolute.options $RROOT/simulator/_configuration.mk; \
      rm -rf $RROOT/simulator/.csconfig; echo removed"

  say "verifying the server has the traces we expect"
  "${SSH[@]}" "$SRV" "ls $RROOT/simulator/traces/*.champsimtrace $RROOT/simulator/traces/*/*.champsimtrace 2>/dev/null | wc -l | xargs echo 'trace files:'; \
      du -sh $RROOT/simulator/traces | cut -f1 | xargs echo 'trace bytes:'"

  cat << 'NEXT'

Deployed. Next, on the server:

  bash ~/server_build.sh

That builds bin/champsim and runs the three policy guards.
NEXT
else
  echo
  echo "Dry run complete. Re-run with --go to apply."
fi
