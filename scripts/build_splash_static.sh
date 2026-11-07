#!/usr/bin/env bash
# Build statically linked SPLASH-3 binaries for gem5 SE mode.
#
#   scp -P 2222 scripts/build_splash_static.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/build_splash_static.sh plan'
#   ssh -p 2222 user@your-server 'bash ~/build_splash_static.sh go'
#   ssh -p 2222 user@your-server 'bash ~/build_splash_static.sh verify'
#
#   # rebuild ONE app, with the traced binary's own flags and fortify off
#   ONLY=BARNES OPT= FORTIFY=0 bash ~/build_splash_static.sh go
#
# OPT (default -O2) is added to the tree's own CFLAGS. On Ubuntu, -O2 also turns
# on _FORTIFY_SOURCE, which needs optimisation to act. That is why the static
# BARNES aborted natively with "buffer overflow detected" on its correct input
# (2026-09-25), while the traced dynamic BARNES, built with the tree's own
# flags, has no fortified calls. OPT= builds with exactly the tree's flags --
# the same code the traces came from -- and FORTIFY=0 makes the absence of
# fortify explicit. ONLY limits the rebuild, so a static binary already in use
# (OCEAN, in the B3 comparison) is not changed. A static binary being replaced
# is kept as <bin>.prev_<time>.
#
# WHY. gem5 SE mode emulates syscalls rather than booting an OS, so a
# dynamically linked binary needs the guest dynamic loader and a matching libc
# inside the simulation. It usually just fails. The SPLASH-3 binaries here were
# built for native tracing under Pin, which does not care, so both OCEAN and
# BARNES came back DYNAMIC.
#
# THE ORIGINALS ARE NOT TOUCHED. Every trace this project has was produced by
# those exact binaries, and although tracing is finished, overwriting them would
# destroy the ability to reproduce a trace. Static builds go to a separate tree
# and the originals are restored afterwards if the build modified them in place.
#
# pthreads: glibc 2.34+ folded libpthread into libc, so static linking with
# threads works without the --whole-archive dance older guides describe. Ubuntu
# 24.04 ships glibc 2.39. If a build fails on pthread symbols anyway, that is
# the first thing to check.
set -uo pipefail

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
SPLASH="${SPLASH:-$R/simulator/tracer/splash-3/codes/apps}"
DEST="${DEST:-$HOME/splash-static}"
LOG="$HOME/splash_static_build.log"

# app-subdir : binary name
APPS=(
  "ocean/contiguous_partitions:OCEAN"
  "barnes:BARNES"
)
OPT="${OPT--O2}"          # unset -> -O2 (the original behaviour); OPT= -> none
FORTIFY="${FORTIFY:-}"    # 0 -> -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0
ONLY="${ONLY:-}"          # space-separated binary names; empty -> every app

die() { echo "ERROR: $*" >&2; exit 1; }

linkage() { file -b "$1" 2>/dev/null | grep -oE 'statically linked|dynamically linked' || echo "unknown"; }

phase_plan() {
  echo "== SPLASH-3 apps to build statically =="
  echo "   source: $SPLASH"
  echo "   dest:   $DEST"
  echo
  local entry dir bin src
  for entry in "${APPS[@]}"; do
    dir="${entry%%:*}"; bin="${entry##*:}"
    src="$SPLASH/$dir/$bin"
    if [ -x "$src" ]; then
      printf '   %-34s present, %s\n' "$dir/$bin" "$(linkage "$src")"
    else
      printf '   %-34s MISSING at %s\n' "$dir/$bin" "$src"
    fi
    [ -x "$DEST/$bin" ] && printf '   %-34s static build exists: %s\n' "" "$(linkage "$DEST/$bin")"
  done
  echo
  echo "   glibc: $(ldd --version 2>/dev/null | head -1)"
  echo "   (2.34+ merges libpthread into libc, so -static works with threads)"
}

phase_go() {
  mkdir -p "$DEST" || die "cannot create $DEST"
  : > "$LOG"
  local entry dir bin src saved ok=0 fail=0
  for entry in "${APPS[@]}"; do
    dir="${entry%%:*}"; bin="${entry##*:}"
    if [ -n "$ONLY" ]; then case " $ONLY " in *" $bin "*) ;; *) echo "   (not rebuilding $bin: ONLY=$ONLY)"; continue ;; esac; fi
    src="$SPLASH/$dir"
    [ -d "$src" ] || { echo "   SKIP $dir -- no such directory"; continue; }
    echo "== $dir/$bin =="

    # Preserve the original binary. These produced every trace we have.
    saved=""
    if [ -x "$src/$bin" ]; then
      saved="$src/$bin.native-backup"
      [ -f "$saved" ] || cp -p "$src/$bin" "$saved"
      echo "   original preserved as $(basename "$saved") ($(linkage "$src/$bin"))"
    fi

    # Read the flags the tree already uses and APPEND to them.
    #
    # Passing LDFLAGS=... on the make command line REPLACES the Makefile's
    # value, and SPLASH-3's Makefile.config keeps -lm there. Overriding it
    # dropped -lm and every math symbol came back undefined -- sqrt, pow, sin,
    # floor. The flags have to be extended, not substituted.
    local cfg base_ld base_cf
    cfg=$(find "$src" -maxdepth 4 -name Makefile.config 2>/dev/null | head -1)
    [ -z "$cfg" ] && cfg=$(find "$SPLASH/../.." -maxdepth 3 -name Makefile.config 2>/dev/null | head -1)
    base_ld=""; base_cf=""
    if [ -n "$cfg" ]; then
      base_ld=$(grep -E '^\s*LDFLAGS\s*[:+]?=' "$cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
      base_cf=$(grep -E '^\s*CFLAGS\s*[:+]?=' "$cfg" 2>/dev/null | head -1 | sed 's/^[^=]*=//')
      echo "   Makefile.config: $cfg"
      echo "     existing LDFLAGS: ${base_ld:-<none found>}"
      echo "     existing CFLAGS : ${base_cf:-<none found>}"
    else
      echo "   no Makefile.config found; falling back to explicit -lm"
    fi
    # -lm last: it must follow the objects that reference it.
    local ld_use="-static -pthread ${base_ld} -lm"
    local cf_use="-static ${OPT:+$OPT }-pthread ${base_cf}"
    [ "$FORTIFY" = 0 ] && cf_use="$cf_use -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0"
    echo "   building with CFLAGS=\"$cf_use\""

    echo "   building with LDFLAGS=\"$ld_use\""
    (
      cd "$src" || exit 1
      make clean
      make CFLAGS="$cf_use" LDFLAGS="$ld_use"
    ) >> "$LOG" 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ] || [ ! -x "$src/$bin" ]; then
      echo "   BUILD FAILED (rc=$rc) -- see $LOG"
      tail -12 "$LOG" | sed 's/^/     /'
      fail=$((fail + 1))
    elif [ "$(linkage "$src/$bin")" != "statically linked" ]; then
      echo "   built, but still $(linkage "$src/$bin") -- the Makefile is overriding LDFLAGS"
      echo "   inspect: grep -nE 'LDFLAGS|CFLAGS|LIBS' $src/Makefile"
      fail=$((fail + 1))
    else
      if [ -e "$DEST/$bin" ]; then
        local prev; prev="$DEST/$bin.prev_$(date +%Y%m%d_%H%M%S)"
        cp -p "$DEST/$bin" "$prev" && echo "   previous static build kept as $(basename "$prev")"
      fi
      cp -p "$src/$bin" "$DEST/$bin"
      echo "   ok -> $DEST/$bin  ($(linkage "$DEST/$bin"), $(stat -c %s "$DEST/$bin") bytes)"
      ok=$((ok + 1))
    fi

    # Put the native binary back so the tracing setup stays reproducible.
    if [ -n "$saved" ] && [ -f "$saved" ]; then
      cp -p "$saved" "$src/$bin"
      echo "   original restored ($(linkage "$src/$bin"))"
    fi
  done

  echo
  echo "   built: $ok   failed: $fail"
  [ "$fail" -eq 0 ] || die "$fail app(s) did not build statically"
}

phase_verify() {
  echo "== static binaries =="
  local entry bin n=0 bad=0
  for entry in "${APPS[@]}"; do
    bin="${entry##*:}"
    if [ -x "$DEST/$bin" ] && [ "$(linkage "$DEST/$bin")" = "statically linked" ]; then
      # Fortified call sites: calls to __*_chk in the binary's own code. grep
      # -c, not -q, after a pipe under pipefail (1a2b8ca).
      printf '   %-12s %-18s %12s bytes   %s call(s) to a fortified __*_chk\n' "$bin" "statically linked" "$(stat -c %s "$DEST/$bin")" \
        "$(objdump -d "$DEST/$bin" 2>/dev/null | grep -cE 'call.*<__[a-z_]+_chk(@plt)?>')"
      n=$((n + 1))
    else
      printf '   %-12s %s\n' "$bin" "MISSING or not static"
      bad=$((bad + 1))
    fi
  done
  echo
  echo "   ready for gem5 SE mode: $n   problems: $bad"
  echo
  echo "== originals (must still be dynamic, they produced our traces) =="
  for entry in "${APPS[@]}"; do
    local dir="${entry%%:*}"; bin="${entry##*:}"
    [ -x "$SPLASH/$dir/$bin" ] && printf '   %-34s %s\n' "$dir/$bin" "$(linkage "$SPLASH/$dir/$bin")"
  done
}

case "${1:-}" in
  plan)   phase_plan ;;
  go)     phase_go ;;
  verify) phase_verify ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
