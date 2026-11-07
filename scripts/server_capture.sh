#!/usr/bin/env bash
# Capture everything on the server that does not exist in the local repo.
#
#   scp -P 2222 scripts/server_capture.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/server_capture.sh'
#   scp -P 2222 user@your-server:~/server_capture.tar.gz /tmp/
#
# Read-only: it copies and archives, it modifies nothing in the repo.
#
# WHY: the server repo is a DIFFERENT GitHub repository from the laptop's, with
# an unrelated history. It carries two commits that exist nowhere else
# (26df093 "VMEM shared-overlay + 16-core support", 1b56a25 results) plus 68
# uncommitted items -- among them a modified PIN tracer that is probably the
# tool that actually produced the traces, and the btp_*_shared_v2.json configs
# that are the real regime-2 evaluation configs. None of that can be recovered
# once the tree is replaced, so it is captured first.
#
# Traces (406 GB) are deliberately NOT included.
set +e

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
STAGE="$HOME/server_capture"
OUT="$HOME/server_capture.tar.gz"

[ -d "$R" ] || { echo "repo not found at $R"; exit 1; }
rm -rf "$STAGE"; mkdir -p "$STAGE"
cd "$R" || exit 1

echo "== 1/6  git history bundle (carries the two unpushed commits) =="
git bundle create "$STAGE/server_repo.bundle" --all 2>&1 | tail -3
git log --oneline -20 > "$STAGE/git_log.txt" 2>&1
git status --short > "$STAGE/git_status.txt" 2>&1

echo "== 2/6  tracked modifications (the tracer is the one that matters) =="
mkdir -p "$STAGE/modified"
git diff > "$STAGE/modified/tracked_changes.diff" 2>&1
# and the full current files, so we can compare directly
for f in simulator/tracer/pin/champsim_tracer.cpp simulator/replacement/coalesce/coalesce.h; do
  [ -f "$f" ] && mkdir -p "$STAGE/modified/$(dirname "$f")" && cp "$f" "$STAGE/modified/$f"
done

echo "== 3/6  untracked configs (the real regime-2 evaluation configs) =="
mkdir -p "$STAGE/configs"
cp "$R"/simulator/btp_*.json "$STAGE/configs/" 2>/dev/null
cp "$R"/btp_*.json "$STAGE/configs/" 2>/dev/null
ls "$STAGE/configs" | wc -l | xargs echo "   configs captured:"

echo "== 4/6  untracked replacement modules (incl. the bias-sweep variants) =="
mkdir -p "$STAGE/replacement"
for d in "$R"/simulator/replacement/*/; do
  name=$(basename "$d")
  if ! git ls-files --error-unmatch "simulator/replacement/$name" >/dev/null 2>&1; then
    cp -r "$d" "$STAGE/replacement/" 2>/dev/null
  fi
done
# the .bak/.canonical copies of coalesce, which may show earlier variants
cp "$R"/simulator/replacement/coalesce/*.bak_fix "$STAGE/replacement/" 2>/dev/null
cp "$R"/simulator/replacement/coalesce/*.canonical "$STAGE/replacement/" 2>/dev/null
ls "$STAGE/replacement" | tr '\n' ' ' | xargs echo "   modules captured:"

echo "== 5/6  server-side patches and tarballs =="
mkdir -p "$STAGE/patches"
cp "$HOME"/*.patch "$STAGE/patches/" 2>/dev/null
cp "$HOME"/*.tar.gz "$STAGE/patches/" 2>/dev/null
rm -f "$STAGE/patches/server_capture.tar.gz"

echo "== 6/6  result logs =="
mkdir -p "$STAGE/results"
if [ -d "$R/simulator/results" ]; then
  (cd "$R/simulator" && tar czf "$STAGE/results/results.tar.gz" results 2>/dev/null)
  du -sh "$STAGE/results/results.tar.gz" 2>/dev/null | xargs echo "   results archive:"
fi

# the ad-hoc driver scripts, for reference on what was actually run
mkdir -p "$STAGE/home_scripts"
cp "$HOME"/*.sh "$STAGE/home_scripts/" 2>/dev/null
rm -f "$STAGE/home_scripts/server_report.sh" "$STAGE/home_scripts/server_capture.sh"
cp "$HOME"/*.py "$STAGE/home_scripts/" 2>/dev/null

echo
echo "== packing =="
tar czf "$OUT" -C "$HOME" server_capture 2>/dev/null
du -sh "$OUT"
echo
echo "Done. Bring it back with:"
echo "  scp -P 2222 user@your-server:~/server_capture.tar.gz /tmp/"
