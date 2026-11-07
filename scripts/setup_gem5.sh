#!/usr/bin/env bash
# Phase B1 -- stand up gem5 with a real MESI directory.
#
#   scp -P 2222 scripts/setup_gem5.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/setup_gem5.sh check'   # prerequisites only
#   ssh -p 2222 user@your-server 'bash ~/setup_gem5.sh deps'    # pip-install scons, no root
#   ssh -p 2222 user@your-server 'bash ~/setup_gem5.sh clone'
#   ssh -p 2222 user@your-server 'bash ~/setup_gem5.sh build'   # detached, hours
#   ssh -p 2222 user@your-server 'bash ~/setup_gem5.sh status'
#
#   # switch the EXISTING build to another protocol, incrementally (detached)
#   ssh -n -p 2222 user@your-server 'PROTOCOL=MESI_Three_Level bash ~/setup_gem5.sh rebuild'
#
#   # MESI_Three_Level only: stop a false-alarm FIFO panic (config file, no rebuild)
#   ssh -n -p 2222 user@your-server 'bash ~/setup_gem5.sh patch-fifo'
#
# WHY. The overlay fakes sharing by aliasing pages, and whether that resembles
# real coherence is unproven. gem5 models coherence properly, so running the
# same workload through both and comparing sharing-degree distribution and
# invalidations per thousand LLC accesses is what turns the overlay from a hack
# into an instrument. docs/framing.md: the tool is the contribution, and this
# is what makes the tool credible.
#
# SCOPE. gem5 is a MEASURING INSTRUMENT here, not an evaluation platform. We do
# NOT port COALESCE, Hawkeye or Mockingjay into Ruby -- that means plumbing MESI
# state through gem5's replacement interface, which is a large detour the paper
# does not need. One characterization run per workload, standard config, extract
# the coherence event distribution.
#
# BUILD COMMAND. docs/PLAN.md still says
#     scons build/X86_MESI_Two_Level/gem5.opt PROTOCOL=MESI_Two_Level
# That has not worked since gem5 23.1, which moved protocol selection to
# kconfig. The release notes are explicit: "scons PROTOCOL=<NAME> build/ALL/
# gem5.opt will not work anymore". This script uses defconfig/setconfig and
# DISCOVERS the protocol option name rather than assuming it, falling back to
# build_opts/ALL, which the same notes say now includes every Ruby protocol.
set -uo pipefail

GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
GEM5_REF="${GEM5_REF:-v25.1.0.1}"   # latest stable, 2026-04-21; disclose in methodology
BUILD="${GEM5_BUILD:-X86}"
# do_build may fall back to ALL; it records the effective directory here so
# status and later phases do not go looking for the wrong path.
[ -f "$GEM5_DIR/.gem5_build_dir" ] && BUILD="$(cat "$GEM5_DIR/.gem5_build_dir")"
LOG="$HOME/gem5_build.log"
SPLASH="${SPLASH:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/tracer/splash-3/codes/apps}"
JOBS="${JOBS:-$(( $(nproc) / 2 ))}"  # the sweep is using the other half
# The protocol a build targets. MESI_Two_Level was B1's; MESI_Three_Level
# (private L0 + L1, shared L2) is the one whose hierarchy matches ChampSim's
# L1D / L2C / LLC -- decided 2026-09-23, see docs/PLAN.md section 4.
PROTOCOL="${PROTOCOL:-MESI_Two_Level}"
# rebuild runs beside a ChampSim sweep on a loaded, shared machine: fewer jobs
# and the lowest priority, so the sweep's critical path is not slowed.
REBUILD_JOBS="${REBUILD_JOBS:-8}"
# /home is shared and its free space has swung by 24 GB in a day. Refuse to
# start, and refuse to keep a backup binary, below this.
MIN_FREE_GB="${MIN_FREE_GB:-15}"

die() { echo "ERROR: $*" >&2; exit 1; }

# pip --user installs land here and are not on PATH by default.
VENV="${GEM5_VENV:-$HOME/.gem5-venv}"
export PATH="$VENV/bin:$HOME/.local/bin:$PATH"

# Install scons without root. This is a shared machine and sudo is not
# available, but gem5's only hard build-tool dependency beyond a compiler and
# Python headers is scons, which pip provides as a normal user package.
#
# protobuf is deliberately NOT installed: it only enables gem5's binary trace
# output, and Phase B needs the Ruby stats file, not traces.
phase_deps() {
  echo "== installing scons without root =="
  if command -v scons >/dev/null 2>&1; then
    echo "   already present: $(command -v scons)"
    scons --version 2>&1 | grep -oE 'v[0-9.]+' | head -1 | sed 's/^/   version /'
    return 0
  fi

  # Ubuntu 24.04 marks the system Python as externally managed (PEP 668), so
  # `pip install --user` is refused outright -- nothing to do with the network.
  # Two ways round it, cleanest first.
  #
  # 1. A virtualenv. Self-contained, touches nothing system-wide.
  # 2. --user --break-system-packages. The flag name is alarmist for a --user
  #    install: it writes to ~/.local and cannot modify a system package. It is
  #    the documented escape hatch when venv is unavailable.
  if python3 -m venv "$VENV" 2>/dev/null; then
    echo "   venv at $VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip 2>/dev/null
    if "$VENV/bin/pip" install --quiet scons; then
      echo "   installed: $VENV/bin/scons"
      "$VENV/bin/scons" --version 2>&1 | grep -oE 'v[0-9.]+' | head -1 | sed 's/^/   version /'
      return 0
    fi
    echo "   venv created but pip install failed inside it"
  else
    echo "   python3 -m venv unavailable (python3-venv not installed)"
  fi

  echo "   falling back to pip --user --break-system-packages"
  if python3 -m pip install --user --break-system-packages --quiet scons; then
    hash -r
    command -v scons >/dev/null 2>&1 \
      && { echo "   installed: $(command -v scons)"; return 0; } \
      || { echo "   installed but not on PATH; add ~/.local/bin to PATH"; return 1; }
  fi

  echo
  echo "   Both routes failed. Remaining options:"
  echo "     - pip download scons on your laptop, scp the wheel up, install it"
  echo "     - ask whoever administers the box for python3-scons or python3-venv"
  return 1
}

phase_check() {
  echo "== prerequisites =="
  local missing=0
  for t in scons g++ python3 git; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '   %-12s %s\n' "$t" "$($t --version 2>&1 | head -1 | cut -c1-50)"
    else
      printf '   %-12s MISSING\n' "$t"; missing=$((missing + 1))
    fi
  done
  echo
  echo "   python3 dev headers: $(python3 -c 'import sysconfig,os;p=sysconfig.get_paths()["include"]+"/Python.h";print("ok "+p if os.path.exists(p) else "MISSING")' 2>/dev/null)"
  for m in protobuf; do
    printf '   %-12s %s\n' "$m" "$(pkg-config --modversion $m 2>/dev/null || echo 'not found (optional, disables trace output)')"
  done
  echo
  echo "== disk =="
  # gem5 source plus one full build is roughly 15-20 GB. /home has been tight,
  # and regenerating ocean at n514 wants ~86 GB of its own.
  df -h "$HOME" | tail -1
  local free_gb; free_gb=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
  echo "   gem5 needs ~20 GB (source + one build). Free: ${free_gb}G"
  [ -n "$free_gb" ] && [ "$free_gb" -lt 25 ] && echo "   !! TIGHT -- compress traces first, and mind that ocean regeneration wants ~86 GB"
  echo
  if [ "$missing" -gt 0 ]; then
    echo "$missing tool(s) missing."
    command -v scons >/dev/null 2>&1 || echo "   scons: run '$0 deps' to pip-install it as a user package (no root)"
    return 1
  fi
  echo "prerequisites ok"
}

phase_clone() {
  if [ -d "$GEM5_DIR/.git" ]; then
    echo "already cloned at $GEM5_DIR ($(cd "$GEM5_DIR" && git describe --tags 2>/dev/null || echo unknown))"
    return 0
  fi
  echo "cloning gem5 @ $GEM5_REF (shallow) into $GEM5_DIR"
  git clone --depth 1 --branch "$GEM5_REF" https://github.com/gem5/gem5.git "$GEM5_DIR" \
    || die "clone failed -- check the tag exists, or set GEM5_REF"
  (cd "$GEM5_DIR" && git describe --tags)
  du -sh "$GEM5_DIR"
}

# Find the kconfig option that enables MESI_Two_Level, rather than guessing its
# spelling. The release notes say protocol names in Kconfig now match the SLICC
# file names, but the exact prefix has moved between releases.
discover_protocol_opt() {
  local d="$GEM5_DIR/build/$BUILD"
  [ -f "$d/gem5.build/config" ] || return 1
  grep -oE '^[A-Za-z0-9_]*MESI_Two_Level[A-Za-z0-9_]*' "$d/gem5.build/config" 2>/dev/null | head -1 && return 0
  grep -ioE '^[A-Za-z0-9_]*MESI[A-Za-z0-9_]*TWO[A-Za-z0-9_]*' "$d/gem5.build/config" 2>/dev/null | head -1
}

do_build() {
  cd "$GEM5_DIR" || die "no $GEM5_DIR -- run 'clone' first"
  echo "=== defconfig build/$BUILD from build_opts/$BUILD ==="
  scons defconfig "build/$BUILD" "build_opts/$BUILD" 2>&1 | tail -5

  local opt; opt=$(discover_protocol_opt)
  if [ -n "$opt" ]; then
    echo "=== enabling $opt ==="
    scons setconfig "build/$BUILD" "$opt"=y 2>&1 | tail -3
  else
    echo "=== could not find a MESI_Two_Level option in the generated config ==="
    echo "    falling back to build_opts/ALL, which the 23.1 release notes say"
    echo "    includes every Ruby protocol."
    BUILD=ALL
    scons defconfig build/ALL build_opts/ALL 2>&1 | tail -5
  fi

  echo "=== building build/$BUILD/gem5.opt with $JOBS jobs ==="
  echo "    (half the cores; the ChampSim sweep is using the rest)"
  nice -n 15 scons "build/$BUILD/gem5.opt" -j"$JOBS"
  local rc=$?
  echo "=== scons rc=$rc ==="
  [ "$rc" -eq 0 ] || exit "$rc"

  # Record the build directory actually used, so status and the run scripts
  # agree after an ALL fallback rather than looking for the X86 path.
  echo "$BUILD" > "$GEM5_DIR/.gem5_build_dir"

  echo "=== verifying the protocol is compiled into the BINARY ==="
  # The previous check was `grep -rl MESI_Two_Level build/$BUILD/`, which is
  # vacuous: SLICC generates files literally NAMED MESI_Two_Level.*, so it
  # matches whether or not the protocol linked. It also walks several GB.
  # gem5 embeds each controller's generated Python module, so the module name
  # appearing in the binary means the protocol is genuinely in there.
  local bin="build/$BUILD/gem5.opt"
  if ./"$bin" --help >/dev/null 2>&1; then echo "    binary runs"
  else echo "    !! binary did NOT run"; fi
  local n
  n=$(strings -a "$bin" 2>/dev/null | grep -c "MESI_Two_Level_L1Cache_Controller")
  if [ "${n:-0}" -gt 0 ]; then
    echo "    MESI_Two_Level controllers embedded in the binary ($n references)"
  else
    echo "    !! MESI_Two_Level NOT in the binary -- protocol selection did not take"
  fi
  ls -la "$bin"
}

phase_build() {
  [ -d "$GEM5_DIR" ] || die "no $GEM5_DIR -- run 'clone' first"
  if scons_running; then
    die "a gem5 build is already running. Use 'status'."
  fi
  echo "launching detached; log -> $LOG"
  echo "$(date '+%F %T') GEM5 BUILD START ($JOBS jobs)" >> "$LOG"
  setsid env GEM5_DIR="$GEM5_DIR" GEM5_BUILD="$BUILD" JOBS="$JOBS" \
    bash "$0" __build < /dev/null >> "$LOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
  tail -5 "$LOG"
  echo
  echo "check with:  bash $0 status"
}

# B1's deliverable is "ocean and barnes running under Ruby MESI_Two_Level",
# not a compiled binary. gem5 SE mode is where this kind of project stalls --
# docs/PLAN.md timeboxes it for that reason -- and the usual blocker is the
# workload binary, not gem5. SE mode wants statically linked executables;
# dynamically linked ones need the loader and a matching libc in the guest and
# frequently do not work.
phase_check_workloads() {
  echo "== SPLASH-3 binaries for gem5 SE mode =="
  local found=0 static=0 dyn=0
  for b in "$SPLASH"/ocean/contiguous_partitions/OCEAN "$SPLASH"/barnes/BARNES \
           "$HOME"/splash3/codes/apps/ocean/contiguous_partitions/OCEAN \
           "$HOME"/splash3/codes/apps/barnes/BARNES; do
    [ -x "$b" ] || continue
    found=$((found + 1))
    local info; info=$(file -b "$b" 2>/dev/null)
    case "$info" in
      *statically\ linked*) static=$((static + 1)); printf '   %-52s STATIC  ok\n' "$(basename "$(dirname "$b")")/$(basename "$b")" ;;
      *dynamically\ linked*) dyn=$((dyn + 1));    printf '   %-52s DYNAMIC -- SE mode may refuse it\n' "$(basename "$(dirname "$b")")/$(basename "$b")" ;;
      *) printf '   %-52s %s\n' "$(basename "$b")" "$info" ;;
    esac
  done
  [ "$found" -eq 0 ] && echo "   none found -- build SPLASH-3 first"
  echo
  echo "   found: $found   static: $static   dynamic: $dyn"
  if [ "$dyn" -gt 0 ]; then
    echo
    echo "   Dynamically linked binaries usually need rebuilding with -static"
    echo "   before gem5 SE mode will run them:"
    echo "     make clean && make CFLAGS=\"-static -O2\" LDFLAGS=-static"
    echo "   This is the step that eats the time budget, so settle it before"
    echo "   the build finishes rather than after."
  fi
}

free_gb() { df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9'; }
# By process NAME, ours only. `pgrep -f "[s]cons.*gem5"` matched any shell whose
# command text mentioned scons and gem5 -- it refused every run in the first test
# of 'rebuild', because the test's own shell matched. scons launched from PATH
# runs as `scons`; the simulator runs as `gem5.opt`.
scons_running() { pgrep -u "$(id -u)" -x scons >/dev/null 2>&1; }
gem5_running()  { pgrep -u "$(id -u)" -x gem5.opt >/dev/null 2>&1; }

# The exact kconfig option for a protocol, whether it is currently set
# ("NAME=y") or not ("# NAME is not set"). The option-name match is exact, so
# MESI_Three_Level does not pick up MESI_Three_Level_HTM. gem5 v25.1.0.1's
# src/mem/ruby/protocol/Kconfig declares every protocol as an INDEPENDENT bool
# (RUBY_PROTOCOL_<name>), not a choice -- so enabling one does not disable
# another, and a single-protocol build has to switch the others off itself.
protocol_opt() {
  local cfg="$GEM5_DIR/build/$BUILD/gem5.build/config"
  grep -oE "[A-Za-z0-9_]*PROTOCOL_$1(=| is not set)" "$cfg" 2>/dev/null | head -1 | sed -E 's/(=| is not set)$//'
}
protocol_lines() { grep -E 'PROTOCOL' "$GEM5_DIR/build/$BUILD/gem5.build/config" 2>/dev/null | sed 's/^/     /'; }
# The protocols compiled into a binary, from the controller names gem5 embeds.
binary_protocols() {
  strings -a "$1" 2>/dev/null | grep -oE '(MESI|MOESI|MI|MSI|CHI)[A-Za-z_]*_(L0Cache|L1Cache)_Controller' \
    | sed -E 's/_(L0Cache|L1Cache)_Controller$//; s/_COLONS$//' | sort -u | tr '\n' ' '
}
# gem5 also embeds pybind names with "::" spelled "_COLONS_", e.g.
# MESI_Two_Level_COLONS_L1Cache_Controller. Without stripping that, one protocol
# read as two -- seen on the server 2026-09-24 as "MESI_Two_Level
# MESI_Two_Level_COLONS" -- and the post-build check would call a correct
# single-protocol binary "not alone".

# Foreground: every check that can fail fast, so the command that launches the
# detached build also says whether it will work.
phase_rebuild() {
  local cfg="$GEM5_DIR/build/$BUILD/gem5.build/config" bin="$GEM5_DIR/build/$BUILD/gem5.opt" opt f
  [ -f "$cfg" ] || die "no existing build at build/$BUILD -- 'rebuild' switches an existing build; use 'build' first"
  if scons_running; then die "a gem5 build is already running. Use 'status'."; fi
  if gem5_running; then die "a gem5 simulation of ours is running from this build -- let it finish"; fi
  opt=$(protocol_opt "$PROTOCOL")
  [ -n "$opt" ] || die "no kconfig option for $PROTOCOL in $cfg -- not falling back to build/ALL (a full multi-protocol build would not fit the disk)"
  f=$(free_gb)
  echo "== gem5 rebuild: build/$BUILD -> $PROTOCOL =="
  echo "   option:      $opt"
  echo "   current binary has: $( [ -f "$bin" ] && binary_protocols "$bin" || echo none)"
  echo "   config now:"; protocol_lines
  echo "   free disk:   ${f}G (minimum $MIN_FREE_GB)"
  [ -n "$f" ] && [ "$f" -ge "$MIN_FREE_GB" ] || die "not enough free disk"
  echo "   jobs:        $REBUILD_JOBS, nice 19 (the ChampSim sweep has priority)"
  echo "launching detached; log -> $LOG"
  echo "$(date '+%F %T') GEM5 REBUILD START ($PROTOCOL, $REBUILD_JOBS jobs)" >> "$LOG"
  setsid env GEM5_DIR="$GEM5_DIR" GEM5_BUILD="$BUILD" PROTOCOL="$PROTOCOL" REBUILD_JOBS="$REBUILD_JOBS" \
      MIN_FREE_GB="$MIN_FREE_GB" bash "$0" __rebuild < /dev/null >> "$LOG" 2>&1 &
  disown 2>/dev/null
  sleep 5
  tail -8 "$LOG"
  echo
  echo "check with:  bash $0 status"
}

do_rebuild() {
  cd "$GEM5_DIR" || die "no $GEM5_DIR"
  local cfg="build/$BUILD/gem5.build/config" bin="build/$BUILD/gem5.opt" opt others have save
  opt=$(protocol_opt "$PROTOCOL"); [ -n "$opt" ] || die "no option for $PROTOCOL"

  # Keep the binary being replaced, named for what is in it, when the disk
  # allows. The link writes a new file, so the copy is what survives.
  if [ -f "$bin" ]; then
    have=$(binary_protocols "$bin" | tr ' ' '+' | sed 's/+$//')
    save="$bin.${have:-unknown}"
    local k kept=""
    for k in "$bin".*; do [ -f "$k" ] && cmp -s "$k" "$bin" && { kept=$k; break; }; done
    if [ -n "$kept" ]; then echo "=== previous binary already kept: $kept ==="
    elif [ -e "$save" ]; then echo "=== previous binary already kept: $save ==="
    elif [ $(( $(free_gb) - $(du -BG "$bin" | cut -f1 | tr -dc '0-9') )) -ge "$MIN_FREE_GB" ]; then
      cp -p "$bin" "$save" && echo "=== kept the previous binary: $save ==="
    else echo "=== !! not enough disk to keep the previous binary; it will be replaced ==="; fi
  fi

  # Single-protocol build: the target on, every other protocol that is on, off,
  # and the PROTOCOL string naming the target. gem5 keeps that string beside
  # the per-protocol bools (src/mem/ruby/Kconfig: `config PROTOCOL string`), and
  # a single-protocol build requires RUBY_PROTOCOL_<PROTOCOL> to be on
  # (src/mem/ruby/protocol/SConscript:133). Switching only the bools left it
  # reading "MESI_Two_Level" and the first server rebuild, 2026-09-24, stopped
  # there with ValueError. se.py / Ruby.py also read PROTOCOL at run time.
  others=$(grep -oE '^[A-Za-z0-9_]*PROTOCOL_[A-Za-z0-9_]+=y' "$cfg" | sed 's/=y$//' | grep -vx "$opt" | sed 's/$/=n/' | tr '\n' ' ')
  echo "=== setconfig: $opt=y ${others}PROTOCOL=$PROTOCOL ==="
  # shellcheck disable=SC2086 -- $others is a list of NAME=n words
  scons setconfig "build/$BUILD" "$opt=y" $others "PROTOCOL=$PROTOCOL" 2>&1 | tail -5
  echo "=== config after ==="; protocol_lines
  grep -qx "$opt=y" "$cfg" || die "$opt is not set after setconfig -- stopping before a build that would be wrong"
  [ "$(grep -cE '^[A-Za-z0-9_]*PROTOCOL_[A-Za-z0-9_]+=y' "$cfg")" -eq 1 ] || die "more than one protocol still enabled -- stopping"
  grep -qx "PROTOCOL=\"$PROTOCOL\"" "$cfg" || die "the PROTOCOL string is not \"$PROTOCOL\" after setconfig -- stopping"

  echo "=== building build/$BUILD/gem5.opt, $REBUILD_JOBS jobs, nice 19 ==="
  nice -n 19 scons "build/$BUILD/gem5.opt" -j"$REBUILD_JOBS"
  local rc=$?
  echo "=== scons rc=$rc ==="
  [ "$rc" -eq 0 ] || exit "$rc"

  echo "=== verifying the binary ==="
  if ./"$bin" --help >/dev/null 2>&1; then echo "    binary runs"; else echo "    !! binary did NOT run"; fi
  have=$(binary_protocols "$bin")
  echo "    protocols in the binary: ${have:-none found}"
  case " $have " in
    *" $PROTOCOL "*) [ "$(echo $have | wc -w)" -eq 1 ] && echo "    OK -- $PROTOCOL only" \
                       || echo "    !! $PROTOCOL present but not alone" ;;
    *) echo "    !! $PROTOCOL NOT in the binary -- the switch did not take" ;;
  esac
  echo "$PROTOCOL" > "$GEM5_DIR/.gem5_protocol"
  ls -la "$bin"
  echo "=== $(date '+%F %T') GEM5 REBUILD DONE ==="
}

# MESI_Three_Level's two L0<->L1 buffers are strict-FIFO, and gem5 panics
# "FIFO ordering violated" when two paths enqueue into one in the same cycle
# with different delays: the L1 at l1_{request,response}_latency (2 cycles),
# a re-enqueue at 1. A known false alarm -- gem5-users, "Ruby strict fifo
# message buffer panic: FIFO ordering violated" (same buffer, same protocol)
# and "[Ruby memory model] FIFO ordering violation"; the reporter's workaround
# is to turn the strict-FIFO flag off. ocean_4c died of it on
# system.ruby.l0_cntrl0.bufferFromL1 on 2026-09-27, 76 ms simulated in.
#
# Why this changes no result: in MessageBuffer::enqueue (v25.1.0.1), with Ruby
# randomization off, arrival_time = current_time + delta whether or not the
# buffer is ordered, and the heap dequeues by arrival time either way. `ordered`
# then only decides whether the check runs. So this refuses unless the last
# run's config.ini shows randomization off. It is a config file, read at
# start-up: no rebuild. Disclose it in the methodology.
phase_patch_fifo() {
  local f="$GEM5_DIR/configs/ruby/MESI_Three_Level.py" b n ini r
  [ -f "$f" ] || die "no $f"
  for b in ToL1 FromL1; do
    n=$(grep -cE "^[[:space:]]*l0_cntrl\.buffer$b = MessageBuffer\(ordered=(True|False)\)" "$f")
    [ "$n" = 1 ] || die "expected one l0_cntrl.buffer$b assignment in $f, found $n -- read the file before patching"
  done
  ini=$(ls -t "$HOME"/gem5_results_MESI_Three_Level/*/config.ini 2>/dev/null | head -1)
  [ -n "$ini" ] || die "no MESI_Three_Level config.ini to confirm Ruby randomization is off"
  r=$(awk '/^\[/ {s = $0} s == "[system.ruby]" && /^randomization=/ {sub(/^randomization=/, ""); print}' "$ini")
  echo "   [system.ruby] randomization=${r:-<not found>}  ($ini)"
  [ "$r" = false ] || die "Ruby randomization is not recorded as off -- unordering would then change arrival times"
  if ! grep -qE 'l0_cntrl\.buffer(ToL1|FromL1) = MessageBuffer\(ordered=True\)' "$f"; then
    echo "   already patched:"; grep -nE 'l0_cntrl\.buffer(ToL1|FromL1) = ' "$f" | sed 's/^/     /'; return 0
  fi
  # By process name, not command line: -f also matches a `tail -f .../gem5.opt`
  # or this script's own caller (c5ba113 made the same fix for champsim).
  pgrep -u "$(id -u)" -x gem5.opt >/dev/null \
    && die "a gem5 run is live -- patch between runs, so every run has one configuration"
  cp -p "$f" "$f.orig_fifo" || die "cannot back up $f"
  sed -i -E 's/^([[:space:]]*l0_cntrl\.buffer(ToL1|FromL1) = MessageBuffer\()ordered=True\)/\1ordered=False)  # COALESCE: setup_gem5.sh patch-fifo/' "$f"
  n=$(grep -c 'ordered=False)  # COALESCE: setup_gem5.sh patch-fifo' "$f")
  [ "$n" = 2 ] || { cp -p "$f.orig_fifo" "$f"; die "patched $n line(s), expected 2 -- restored the original"; }
  echo "   patched (original kept as $(basename "$f.orig_fifo")):"
  # diff exits 1 because the files differ -- that is the success case, and
  # under pipefail it would become this function's status. The grep above
  # already verified the patch.
  diff "$f.orig_fifo" "$f" | sed 's/^/     /'
  return 0
}

phase_status() {
  echo "== gem5 build =="
  if scons_running; then
    echo "   running (pid $(pgrep -u "$(id -u)" -x scons | head -1))"
  else
    echo "   not running"
  fi
  [ -x "$GEM5_DIR/build/$BUILD/gem5.opt" ] \
    && echo "   binary: $GEM5_DIR/build/$BUILD/gem5.opt ($(stat -c %s "$GEM5_DIR/build/$BUILD/gem5.opt") bytes)" \
    || echo "   binary: not built yet"
  echo
  echo "== last 12 log lines =="
  tail -12 "$LOG" 2>/dev/null || echo "   (no log)"
  echo
  df -h "$HOME" | tail -1
}

case "${1:-}" in
  check)   phase_check ;;
  check-workloads) phase_check_workloads ;;
  deps)    phase_deps ;;
  clone)   phase_clone ;;
  build)   phase_build ;;
  status)  phase_status ;;
  rebuild) phase_rebuild ;;
  patch-fifo) phase_patch_fifo ;;
  __build) do_build ;;
  __rebuild) do_rebuild ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
