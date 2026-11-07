#!/usr/bin/env bash
# Compress trace sets to reclaim disk, safely.
#
#   scp -P 2222 scripts/compress_traces.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/compress_traces.sh plan'
#   ssh -p 2222 user@your-server 'bash ~/compress_traces.sh go barnes_4t canneal_4t'   # detached
#   ssh -p 2222 user@your-server 'bash ~/compress_traces.sh status'
#
# ChampSim reads .xz natively, and run_phase_a.sh resolves a trace stem to
# .champsimtrace OR .champsimtrace.xz, so a compressed set stays usable. Before
# that change, compressing anything silently removed it from every job's reach.
#
# WHY IT MATTERS: regenerating ocean at -n514 needs ~86 GB and /home has been
# hovering near 40 GB free on a filesystem shared with other users.
#
# SAFETY. The original is deleted ONLY after the compressed file exists, its xz
# index reads back, and its recorded uncompressed size matches the original byte
# for byte. A truncated .xz looks exactly like a trace until something reads it,
# and these are traces that took hours to generate.
#
# REFUSES a set that anything is using -- a process with one of its files open,
# or naming the set's path on its command line -- and re-checks before every
# file. It used to refuse whenever ANY champsim ran, which on 2026-09-25 blocked
# reclaiming 179 GB of retired ocean/water traces for the whole day-long
# COALESCE relaunch, whose jobs read only canneal and barnes, while /home fell
# to 14 GB free.
#
# Runs detached (setsid) and logs to ~/compress_traces.log: 179 GB of xz takes
# a while, and an ssh drop would stop it mid-file. Lowest priority and a fixed
# thread count, so it never outranks the simulations sharing the machine.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
T="$R/simulator/traces"
PRESET="${XZ_PRESET:--1}"     # -1 is ~4x faster than default and still ~4:1 here
# 8, not 0 (one per core), and nice 19: the simulations run at nice 19 too, so
# this must not take the machine from them. nice 10 used to outrank them.
THREADS="${XZ_THREADS:-8}"
LOG="${LOG:-$HOME/compress_traces.log}"
PIDF="$HOME/.compress_traces.pid"

die() { echo "ERROR: $*" >&2; exit 1; }

# Where a set's files live: a directory (ocean_8t/) or a filename prefix
# (barnes_4t0.champsimtrace ...).
set_prefix() { if [ -d "$T/$1" ]; then echo "$T/$1/"; else echo "$T/$1"; fi; }

# PIDs using a set: an open file under its prefix (readable for our own
# processes), or the prefix on the command line (readable for everyone's).
set_users() {
  local pre p; pre=$(set_prefix "$1")
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    # grep -c throughout: under pipefail, grep -q's early exit SIGPIPEs a long
    # producer and the pipeline reads as "no match" -- here that would call a
    # set in use NOT in use (seen for real in run_gem5_splash.sh, 2026-09-25).
    if [ "$(ls -l "$p/fd" 2>/dev/null | grep -cF -- "$pre")" -gt 0 ]; then echo "${p#/proc/}"; continue; fi
    # { } so a process that exits mid-scan is silent: the shell reports a failed
    # < redirection itself, before a trailing 2>/dev/null takes effect.
    [ "$({ tr '\0' ' ' < "$p/cmdline"; } 2>/dev/null | grep -cF -- "$pre")" -gt 0 ] && echo "${p#/proc/}"
  done | sort -u
}
describe_users() { local p; for p in "$@"; do printf '     pid %s: %s\n' "$p" "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-110)"; done; }
alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

set_files() {
  local name="$1"
  if [ -d "$T/$name" ]; then
    find "$T/$name" -maxdepth 1 -name '*.champsimtrace' 2>/dev/null | sort
  else
    find "$T" -maxdepth 1 -name "${name}*.champsimtrace" 2>/dev/null | sort
  fi
}

phase_plan() {
  echo "== compressible trace sets =="
  printf '   %-18s %6s %10s %12s\n' set files size 'est. saved'
  local name files n sz
  for name in barnes_4t canneal_4t canneal_8t canneal_16t water_8t ocean_8t; do
    files=$(set_files "$name"); n=$(echo "$files" | grep -c . )
    [ "$n" -eq 0 ] && continue
    sz=$(echo "$files" | xargs -r du -cb 2>/dev/null | tail -1 | cut -f1)
    printf '   %-18s %6s %10s %12s\n' "$name" "$n" \
      "$(numfmt --to=iec "$sz")" "~$(numfmt --to=iec $((sz * 3 / 4)))"
  done
  echo
  echo "   (estimate assumes ~4:1, which is what these traces achieve at $PRESET)"
  echo
  df -h "$T" | tail -1
}

phase_go() {
  [ $# -gt 0 ] || die "name at least one set, e.g. 'go barnes_4t canneal_4t'"
  alive && die "a compression run is already going (pid $(cat "$PIDF")) -- 'status'"
  local name u bad=0
  for name in "$@"; do
    [ -n "$(set_files "$name")" ] || { echo "   $name: nothing uncompressed -- skipped"; continue; }
    u=$(set_users "$name")
    if [ -n "$u" ]; then echo "   !! $name is in use:"; describe_users $u; bad=1
    else echo "   $name: not in use"; fi
  done
  [ "$bad" -eq 0 ] || die "refusing -- compressing a trace a job is reading replaces the file under it"
  echo "$(date '+%F %T') COMPRESS START $*" >> "$LOG"
  setsid bash "$0" __go "$@" < /dev/null >> "$LOG" 2>&1 &
  disown 2>/dev/null
  sleep 3
  echo "launched; log -> $LOG"; tail -3 "$LOG"
  echo "check with:  bash $0 status"
}

do_go() {
  echo $$ > "$PIDF"

  local name f out orig_size back n_ok=0 n_fail=0 saved=0
  for name in "$@"; do
    local files; files=$(set_files "$name")
    [ -n "$files" ] || { echo "no uncompressed files for $name -- skipping"; continue; }
    echo "== $name =="
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # Re-check before every file: something may have started using the set.
      u=$(set_users "$name")
      if [ -n "$u" ]; then echo "   !! $name came into use -- stopping before $(basename "$f")"; describe_users $u; n_fail=$((n_fail + 1)); break; fi
      out="$f.xz"
      if [ -s "$out" ]; then echo "   already compressed: $(basename "$out")"; continue; fi
      orig_size=$(stat -c %s "$f")
      printf '   %-34s %8s -> ' "$(basename "$f")" "$(numfmt --to=iec "$orig_size")"

      if ! nice -n 19 xz "$PRESET" -T"$THREADS" -c "$f" > "$out.part" 2>/dev/null; then
        echo "FAILED (xz error)"; rm -f "$out.part"; n_fail=$((n_fail + 1)); continue
      fi
      # The archive must read back, and its recorded uncompressed size must match
      # the original exactly, before the original is destroyed.
      back=$(xz --robot -l "$out.part" 2>/dev/null | awk -F'\t' '$1=="totals"{print $5}')
      if [ -z "$back" ] || [ "$back" != "$orig_size" ]; then
        echo "FAILED (readback $back != original $orig_size)"
        rm -f "$out.part"; n_fail=$((n_fail + 1)); continue
      fi
      mv "$out.part" "$out"
      rm -f "$f"
      saved=$((saved + orig_size - $(stat -c %s "$out")))
      echo "$(numfmt --to=iec "$(stat -c %s "$out")")  ok"
      n_ok=$((n_ok + 1))
    done <<< "$files"
  done

  echo
  echo "   compressed: $n_ok   failed: $n_fail   reclaimed: $( [ "$saved" -ge 0 ] && numfmt --to=iec "$saved" || echo "none (${saved} bytes)")"
  df -h "$T" | tail -1
  rm -f "$PIDF"
  [ "$n_fail" -eq 0 ] || die "$n_fail file(s) failed -- originals for those were NOT deleted"
  echo "$(date '+%F %T') COMPRESS DONE"
}

phase_status() {
  alive && echo "== compression RUNNING (pid $(cat "$PIDF")) ==" || echo "== compression not running =="
  tail -6 "$LOG" 2>/dev/null | sed 's/^/   /'
  echo
  echo "== trace sets =="
  printf '   %-18s %6s %6s %10s\n' set raw xz size
  local name d
  for d in "$T"/*/ ; do
    [ -d "$d" ] || continue
    name=$(basename "$d"); [ "$name" = spec ] && continue
    printf '   %-18s %6s %6s %10s\n' "$name" \
      "$(find "$d" -maxdepth 1 -name '*.champsimtrace' | wc -l)" \
      "$(find "$d" -maxdepth 1 -name '*.champsimtrace.xz' | wc -l)" \
      "$(du -sh "$d" 2>/dev/null | cut -f1)"
  done
  printf '   %-18s %6s %6s %10s\n' "barnes_4t" \
    "$(find "$T" -maxdepth 1 -name 'barnes_4t*.champsimtrace' | wc -l)" \
    "$(find "$T" -maxdepth 1 -name 'barnes_4t*.champsimtrace.xz' | wc -l)" \
    "$(du -ch "$T"/barnes_4t*.champsimtrace* 2>/dev/null | tail -1 | cut -f1)"
  echo
  df -h "$T" | tail -1
}

case "${1:-}" in
  plan)   phase_plan ;;
  go)     shift; phase_go "$@" ;;
  __go)   shift; do_go "$@" ;;
  status) phase_status ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
