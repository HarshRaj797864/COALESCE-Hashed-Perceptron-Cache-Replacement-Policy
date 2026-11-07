#!/usr/bin/env bash
# Inventory the server before we sync anything.
#
#   scp -P 2222 scripts/server_report.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/server_report.sh'
#
# Writes ~/server_report.txt and prints it. Read-only: inspects, changes nothing.
set +e

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
OUT="$HOME/server_report.txt"

{
echo "=============================================="
echo " SERVER REPORT  $(date -u '+%Y-%m-%d %H:%M UTC')"
echo " host: $(hostname)"
echo "=============================================="
echo
echo "===== MACHINE ====="
echo "cores: $(nproc)"
free -g | head -2
df -h "$HOME" | tail -1
echo

echo "===== REPO ====="
if [ ! -d "$R" ]; then
  echo "!! REPO NOT FOUND at $R"
else
  cd "$R" || exit 0
  echo "path:   $R"
  echo "remote: $(git remote -v 2>/dev/null | head -1)"
  echo "branch: $(git branch --show-current 2>/dev/null)"
  echo "HEAD:   $(git log -1 --format='%h %ad %s' --date=short 2>/dev/null)"
  echo "vs origin/main (left=behind right=ahead): $(git rev-list --left-right --count origin/main...HEAD 2>/dev/null)"
  echo
  echo "--- UNCOMMITTED CHANGES (most important section) ---"
  n=$(git status --short 2>/dev/null | wc -l)
  echo "total modified/untracked: $n"
  git status --short 2>/dev/null | head -50
  echo
  echo "--- diff stat of tracked modifications ---"
  git diff --stat 2>/dev/null | tail -25
  echo
  echo "--- local commits not on origin ---"
  git log origin/main..HEAD --oneline 2>/dev/null | head -20
  echo
  echo "--- stashes ---"
  git stash list 2>/dev/null | head
fi
echo

echo "===== TRACES ====="
ls -la "$R/simulator/traces/" 2>/dev/null | head -50
echo "count: $(ls "$R/simulator/traces/" 2>/dev/null | wc -l)"
echo "size:  $(du -sh "$R/simulator/traces/" 2>/dev/null | cut -f1)"
echo

echo "===== NON-PARSEC TRACES ANYWHERE (SPEC / CRC2 -- needed for A4) ====="
find "$HOME" -maxdepth 5 -name "*.champsimtrace*" 2>/dev/null \
  | grep -viE "canneal|ocean|barnes|fluid|water" | head -30
echo

echo "===== RESULTS ====="
du -sh "$R/simulator/results" 2>/dev/null
echo "log files: $(find "$R/simulator/results" -name '*.log' 2>/dev/null | wc -l)"
find "$R/simulator/results" -maxdepth 2 -type d 2>/dev/null | head -20
echo

echo "===== SERVER-SIDE PATCHES (may contain work never committed) ====="
for p in "$HOME"/*.patch; do
  [ -f "$p" ] || continue
  echo "--- $(basename "$p")  ($(wc -l < "$p") lines) ---"
  grep '^+++' "$p" 2>/dev/null | head -8
done
echo

echo "===== TARBALLS ====="
ls -la "$HOME"/*.tar.gz 2>/dev/null
echo

echo "===== ANYTHING RUNNING? ====="
ps aux | grep -E "[c]hampsim|[p]in\b" | head
echo

echo "===== BUILD STATE ====="
echo "--- bin/ ---"
ls -la "$R/simulator/bin/" 2>/dev/null | head -20
echo "--- absolute.options (which headers does the build use?) ---"
cat "$R/simulator/absolute.options" 2>/dev/null
echo
echo "--- does config.sh still exist (old build model)? ---"
ls -la "$R/simulator/config.sh" 2>/dev/null || echo "no config.sh"
echo

echo "===== SPLASH3 / BENCHMARK SOURCES ====="
ls "$HOME/splash3" 2>/dev/null | head -15
echo

echo "===== TOOLCHAIN ====="
g++ --version 2>/dev/null | head -1
python3 --version 2>/dev/null
echo
echo "===== END ====="
} 2>&1 | tee "$OUT"

echo
echo "Report written to $OUT"
