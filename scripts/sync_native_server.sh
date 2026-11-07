#!/usr/bin/env bash
# How far apart were the threads in the traced (Pin) run? Read-only on the
# synchronised traces; writes only under ~/sync/native. See sync_native_drift.py.
#
#   bash ~/sync_native_server.sh go       # detached; a program already measured is skipped
#   bash ~/sync_native_server.sh status   # progress, then every finished program's result
set -uo pipefail
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
TDIR="${TDIR:-$R/simulator/traces/sync}"
W="${W:-$HOME/sync/native}"
PY="$HOME/sync_native_drift.py"
PIDF="$W/.pid"
# program | traces in core order, as the runs took them (sync_server.sh traces_for)
PROGS="ocean4|raw0 raw1 raw2 raw3
canneal4|raw1 raw2 raw3 raw4
canneal8|raw1 raw2 raw3 raw4 raw5 raw6 raw7 raw8
barnes256|raw0 raw1 raw2 raw3
barnesstd|raw0_aligned raw1 raw2 raw3
radix|raw0 raw1 raw2 raw3
waternsq|raw0_aligned raw1 raw2 raw3
fmm|raw0_aligned raw1 raw2 raw3"
mkdir -p "$W"

alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

one() {   # program, trace names
  local p="$1" t list=""
  [ -f "$W/$p.done" ] && return 0
  for t in $2; do
    [ -s "$TDIR/$p/$t.champsimtrace.xz" ] || { echo "MISSING $TDIR/$p/$t.champsimtrace.xz" > "$W/$p.txt"; return 1; }
    list="$list $TDIR/$p/$t.champsimtrace.xz"
  done
  # shellcheck disable=SC2086 -- a list of paths
  nice -n 19 python3 "$PY" "$W/$p.tsv" $list > "$W/$p.txt.tmp" 2>&1
  local rc=$?
  mv -f "$W/$p.txt.tmp" "$W/$p.txt"
  if [ "$rc" -eq 0 ]; then touch "$W/$p.done"; else echo "FAILED (exit $rc)" >> "$W/$p.txt"; fi
}

run_all() {
  echo $$ > "$PIDF"
  local n=0 line
  while IFS= read -r line; do
    one "${line%%|*}" "${line#*|}" &
    n=$((n + 1))
    [ $((n % 2)) -eq 0 ] && wait     # two programs at a time (each: up to 8 readers + 8 xz)
  done <<< "$PROGS"
  wait
  date '+%F %T' > "$W/ALL_DONE"
  rm -f "$PIDF"
}

case "${1:-}" in
  go)
    [ -f "$PY" ] || { echo "no $PY -- scripts/sync_native_all.sh uploads it"; exit 1; }
    if alive; then echo "already running"; exit 0; fi
    rm -f "$W/ALL_DONE"
    m=$(md5sum < "$PY" | cut -c1-32)          # a changed measuring script measures every program again
    if [ "$(cat "$W/.py_md5" 2>/dev/null)" != "$m" ]; then rm -f "$W"/*.done; echo "$m" > "$W/.py_md5"; fi
    ( cd "$W" || exit 1; setsid bash "$(readlink -f "$0")" __run < /dev/null > "$W/driver.log" 2>&1 & )
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$PIDF" ] || [ -f "$W/ALL_DONE" ] && break; sleep 1; done
    echo "started (about 10-20 min)" ;;
  __run) run_all ;;
  alive) alive ;;
  status)
    d=$(ls "$W"/*.done 2>/dev/null | wc -l)
    echo "== traced-run drift: $d of $(echo "$PROGS" | wc -l) programs measured; $(alive && echo running || echo 'not running')$([ -f "$W/ALL_DONE" ] && echo "; finished $(cat "$W/ALL_DONE")")"
    while IFS= read -r line; do
      p="${line%%|*}"
      [ -f "$W/$p.txt" ] || continue
      echo "== $p"; cat "$W/$p.txt"
    done <<< "$PROGS" ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
