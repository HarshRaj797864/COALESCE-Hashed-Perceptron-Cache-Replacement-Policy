#!/usr/bin/env bash
# Build the migrated simulator on the server and prove it is sane.
#
#   scp -P 2222 scripts/server_build.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/server_build.sh'
#
# Runs AFTER scripts/deploy_to_server.sh --go.
#
# develop configures at runtime: one binary, bin/champsim, and the config JSON
# is data. The old `./config.sh <cfg> && make clean && make` loop, and the ~40
# per-policy binaries it produced, are gone.
set +e

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
S="$R/simulator"

# /tmp here is the shared root filesystem and sits at 100% full. g++ writes its
# assembler temporaries to TMPDIR and fails with "No space left on device"
# while /home still has hundreds of GB.
export TMPDIR="$HOME/.build_tmp"
mkdir -p "$TMPDIR"

fail() { echo; echo "FAILED: $*"; exit 1; }

echo "== 1/5  where we are =="
cd "$S" || fail "no simulator tree at $S"
echo "   $(pwd)"
echo "   modules: $(ls replacement | tr '\n' ' ')"

echo
echo "== 1b/5  dependencies =="
# develop needs CLI11, fmt, lzma, bzip2 via vcpkg. The server tree was built
# under the old model, so the manifest may be older than develop's.
if [ -d "$S/vcpkg_installed/x64-linux/include" ]; then
  echo "   vcpkg_installed present:"
  ls "$S/vcpkg_installed/x64-linux/include" | tr '\n' ' ' | fold -w 100 | sed 's/^/     /'
  echo
  for h in CLI/CLI.hpp fmt/format.h; do
    if [ -e "$S/vcpkg_installed/x64-linux/include/$h" ]; then echo "   ok   $h"
    else echo "   MISSING  $h"; fi
  done
else
  echo "   vcpkg_installed/x64-linux/include NOT FOUND"
  echo "   The build will fail. Bootstrap with:"
  echo "     cd $S && ./vcpkg/bootstrap-vcpkg.sh && ./vcpkg/vcpkg install"
  fail "dependencies are not installed"
fi

echo
# Refuse to rebuild bin/champsim only while a queue driver can still LAUNCH from
# it. A driver reads its queue inside `while read ...; done < queue.txt`, so it
# holds the file open until it has attempted every line -- then it can no longer
# start anything. Running jobs are safe: the linker writes a new file and a
# running process keeps the binary it started with (tested 2026-09-24: the job
# completed, its exe shown as "(deleted)"). Refusing on any running champsim, as
# this used to, blocked every rebuild for the whole tail of a sweep.
launching_drivers() {
  local lk pid q fd
  for lk in "$HOME"/.phase_a*/driver.pid "$HOME"/.a4*/driver.pid; do
    [ -f "$lk" ] || continue
    pid=$(cat "$lk" 2>/dev/null)
    { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || continue
    q=$(readlink -f "$(dirname "$lk")/queue.txt")
    for fd in /proc/"$pid"/fd/*; do
      [ "$(readlink "$fd" 2>/dev/null)" = "$q" ] && { printf ' %s (pid %s)' "$(dirname "$lk")" "$pid"; break; }
    done
  done
}
busy=$(launching_drivers)
[ -z "$busy" ] || fail "a queue driver can still launch jobs from bin/champsim -- rebuilding now would mix binaries:$busy"

echo "== 2/5  stale generated files =="
# absolute.options supplies -I for every translation unit. A copy pointing at
# another checkout silently fed the build another tree's headers for nine
# months. It is deliberately deleted so the Makefile regenerates it from
# $(realpath inc) here.
rm -f absolute.options _configuration.mk
rm -rf .csconfig
echo "   removed absolute.options, _configuration.mk, .csconfig"

echo
echo "== 3/5  build =="
make clean > /dev/null 2>&1
# make's own status, with the full output kept. `if ! make | tail` tested tail's
# status, so a failed build passed this line; only the -x check below caught it,
# and only because `make clean` had removed the old binary first.
make -j"$(nproc)" > "$HOME/.server_build_make.log" 2>&1; mrc=$?
tail -25 "$HOME/.server_build_make.log"
[ "$mrc" -eq 0 ] || fail "build failed (make rc=$mrc) -- full log: ~/.server_build_make.log"
[ -x bin/champsim ] || fail "bin/champsim was not produced"
echo "   built: $(ls -la bin/champsim | awk '{print $5" bytes"}')"

echo
echo "== 4/5  include path points HERE =="
cat absolute.options
grep -q "$S/inc" absolute.options || fail "absolute.options does not point at $S/inc -- the nine-month bug is back"
echo "   ok"

echo
echo "== 5/5  policy guards =="
cd "$R" || fail "no repo at $R"
rc=0
for g in check_include_path check_fill_hook check_signatures; do
  echo "-- $g"
  if bash "bench/policy_sanity/$g.sh"; then echo "   PASS"; else echo "   FAIL"; rc=1; fi
done

echo
if [ "$rc" -ne 0 ]; then
  fail "one or more guards failed -- do not queue runs"
fi
echo "All green. bin/champsim is built and the guards pass."
echo
echo "Next: a smoke run."
echo "  cd $S"
echo "  scripts/make_config.py --policy lru --cores 8 --regime shared -o $HOME/smoke.json"
echo "  bin/champsim --config $HOME/smoke.json --warmup-instructions 1000000 --simulation-instructions 2000000 traces/canneal{1,2,3,4,5,6,7,8}.champsimtrace"
