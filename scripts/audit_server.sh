#!/usr/bin/env bash
# The 2026-10-17 validation round, server half. READ-ONLY: it writes only under
# ~/audit, and changes no source, binary, trace, run or queue.
#
#   bash ~/audit_server.sh collect        # a minute or two: everything below except the traces
#   bash ~/audit_server.sh traces         # starts the slow part, detached and niced (about 1 h)
#   bash ~/audit_server.sh traces-status  # how far it is
#
# collect -> ~/audit/collect_<time>.tar.xz, holding:
#   machine.txt    boot time, load, disk, crontab, our processes
#   sources.md5    every source and script file of the main tree, ~/c0_build,
#                  ~/diag_build, and the runner scripts in ~ (matched against
#                  git history on the laptop: which commit ran)
#   bins.txt       every simulator binary: md5, size, time, and which counters
#                  it can print (a fingerprint of the code it was built from)
#   settings/      every queue's queue.env, queue.txt and configs; each
#                  pipeline's configs, logs and text files (~/a6, ~/c0, ~/diag,
#                  ~/b3_heldout, ~/b3_canneal8, ~/barnes_std, ~/b3v4_chain)
#   logs/          every ChampSim run.log under results/ (with its mtime)
#   traces.txt     every trace a log names: path, real path, size, mtime
#   gem5/          every gem5 run: config.ini, stats.txt, run.log, simout,
#                  simerr; the md5 of each binary and input it names; the
#                  gem5 binary's md5, its git state and local patch
# traces -> ~/audit/traces/<name>.{md5,mix}: the md5 of each trace file, and
#   trace_mix (scripts/trace_mix.c, a counter independent of count_rmw.py)
#   over the whole trace: loads, stores, read-modify-writes, branches and a
#   content hash every 100,000 records, so any window can be read off later.
set -uo pipefail
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
A="${A:-$HOME/audit}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
JOBS="${JOBS:-6}"
TREES="$R $HOME/c0_build $HOME/diag_build"
PIPES="a6 c0 diag b3_heldout b3_canneal8 barnes_std b3v4_chain"
MARKERS='RMW LOADS ISSUED AS RFO|RMW LOADS FORWARDED FROM THE STORE QUEUE|COHERENCE DIR RFO PROTOCOL-OTHER|PRIVATE-CACHE COHERENCE LEVEL|COHERENCE INVALIDATION LATENCY|BOUNDED-PROTOCOL'
mkdir -p "$A"

collect() {
  local stamp O T b f d
  stamp=$(date +%Y%m%d_%H%M%S); O="$A/collect_$stamp"; mkdir -p "$O"
  echo "collect -> $O"

  { echo "now: $(date '+%F %T')   booted: $(uptime -s)"; uptime; nproc; free -g; df -h "$HOME" "$S/traces"
    echo "== crontab"; crontab -l 2>&1
    echo "== our processes"; ps -u "$(id -u)" -o pid,ppid,etimes,ni,args --sort=start_time | cut -c1-400
  } > "$O/machine.txt" 2>&1
  echo "   machine.txt"

  for T in $TREES; do
    [ -d "$T/simulator" ] || { echo "$(basename "$T") MISSING" >> "$O/sources.md5"; continue; }
    ( cd "$T" && find simulator/inc simulator/src simulator/replacement simulator/branch simulator/btb \
          simulator/prefetcher simulator/scripts simulator/config simulator/test scripts bench/policy_sanity \
          -maxdepth 4 -type f \( -name '*.cc' -o -name '*.h' -o -name '*.py' -o -name '*.sh' -o -name '*.c' \
          -o -name '*.json' -o -name '*.mk' -o -name Makefile -o -name '*.options' \) 2>/dev/null
      ls simulator/Makefile simulator/*.options simulator/vcpkg.json 2>/dev/null ) \
      | LC_ALL=C sort -u | ( cd "$T" && xargs -r -d '\n' md5sum ) | sed "s|^|$(basename "$T") |" >> "$O/sources.md5"
  done
  ( cd "$HOME" && ls -1 ./*.sh ./*.py 2>/dev/null | sed 's|^\./||' | xargs -r -d '\n' md5sum ) | sed 's|^|home |' >> "$O/sources.md5"
  echo "   sources.md5: $(wc -l < "$O/sources.md5") files"

  for T in $TREES; do
    for b in "$T"/simulator/bin/*; do
      [ -f "$b" ] || continue
      f=$(strings -a "$b" 2>/dev/null)
      printf '%s %s md5=%s size=%s mtime=%s' "$(basename "$T")" "${b#"$T"/simulator/}" "$(md5sum < "$b" | cut -c1-32)" \
        "$(stat -c %s "$b")" "$(date -r "$b" '+%F_%T')"
      while IFS= read -r m; do printf ' [%s]=%s' "$m" "$(grep -cF "$m" <<< "$f")"; done < <(tr '|' '\n' <<< "$MARKERS")
      echo
    done
  done > "$O/bins.txt"
  echo "   bins.txt: $(wc -l < "$O/bins.txt") binaries"

  mkdir -p "$O/settings"
  for d in "$HOME"/.phase_a*; do
    [ -d "$d" ] || continue
    mkdir -p "$O/settings/$(basename "$d")"
    find "$d" -maxdepth 1 -type f \( -name 'queue.env' -o -name 'queue.txt' -o -name '*.json' -o -name 'run.log' \) \
      -exec cp -p {} "$O/settings/$(basename "$d")/" \;
  done
  for p in $PIPES; do
    [ -d "$HOME/$p" ] || continue
    ( cd "$HOME" && find "$p" -type f -size -50M \( -name '*.json' -o -name '*.env' -o -name '*.log' -o -name '*.txt' \
        -o -name 'VERDICT' -o -name '*.tsv' \) -print0 | tar --null -T - -cf - ) | tar -C "$O/settings" -xpf -
  done
  echo "   settings/: $(find "$O/settings" -type f | wc -l) files"

  mkdir -p "$O/logs"
  ( cd "$S/results" && find . -name run.log -print0 | tar --null -T - -cf - ) | tar -C "$O/logs" -xpf -
  echo "   logs/: $(find "$O/logs" -name run.log | wc -l) run logs"

  # Each CPU's trace, as the run named it. Runners cd to $S first, except
  # those that pass absolute paths.
  find "$O/logs" -name run.log -exec grep -h -E '^CPU [0-9]+ runs ' {} + | awk '{ print $4 }' | LC_ALL=C sort -u \
    | while IFS= read -r t; do
        case "$t" in /*) f="$t" ;; *) f="$S/$t" ;; esac
        if [ -e "$f" ]; then printf '%s %s %s %s\n' "$t" "$(readlink -f "$f")" "$(stat -L -c %s "$f")" "$(date -r "$f" '+%F_%T')"
        else printf '%s MISSING - -\n' "$t"; fi
      done > "$O/traces.txt"
  echo "   traces.txt: $(wc -l < "$O/traces.txt") traces named by the logs, $(grep -c ' MISSING ' "$O/traces.txt") missing"

  mkdir -p "$O/gem5"
  { echo "binary: $GEM5_DIR/build/X86/gem5.opt"
    [ -f "$GEM5_DIR/build/X86/gem5.opt" ] && echo "md5: $(md5sum < "$GEM5_DIR/build/X86/gem5.opt" | cut -c1-32)  mtime: $(date -r "$GEM5_DIR/build/X86/gem5.opt" '+%F %T')"
    echo "protocol file: $(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null)"
    for p in MESI_Three_Level MESI_Two_Level; do echo "controllers $p: $(strings -a "$GEM5_DIR/build/X86/gem5.opt" 2>/dev/null | grep -c "${p}_L1Cache_Controller")"; done
    echo "git: $(git -C "$GEM5_DIR" describe --tags --always --dirty 2>&1)  head $(git -C "$GEM5_DIR" rev-parse HEAD 2>&1)"
    echo "== git status"; git -C "$GEM5_DIR" status --short 2>&1 | head -50
  } > "$O/gem5/gem5_build.txt"
  git -C "$GEM5_DIR" diff > "$O/gem5/gem5_local.diff" 2>&1
  find "$HOME" -maxdepth 6 -name config.ini -path "*gem5*" -not -path "$GEM5_DIR/*" 2>/dev/null | LC_ALL=C sort | while IFS= read -r c; do
    d=$(dirname "$c"); rel="${d#"$HOME"/}"
    mkdir -p "$O/gem5/runs/$rel"
    for f in config.ini stats.txt simout simerr simout.txt simerr.txt run.log; do
      [ -f "$d/$f" ] && cp -p "$d/$f" "$O/gem5/runs/$rel/"
    done
    # The binary and the input each process ran, as gem5 recorded them.
    grep -E '^(executable|input|cmd)=' "$c" | LC_ALL=C sort -u | while IFS= read -r kv; do
      v="${kv#*=}"
      case "$kv" in
        cmd=*) echo "$kv"
               for w in $v; do [ -f "$w" ] && echo "   cmd file $w md5=$(md5sum < "$w" | cut -c1-32) size=$(stat -c %s "$w")"; done ;;
        *) if [ -f "$v" ]; then echo "$kv md5=$(md5sum < "$v" | cut -c1-32) size=$(stat -c %s "$v") mtime=$(date -r "$v" '+%F_%T')"
           else echo "$kv (not a file here)"; fi ;;
      esac
    done > "$O/gem5/runs/$rel/inputs.txt"
    # Every other file in the run directory (inputs copied there, outputs), by md5.
    ( cd "$d" && find . -maxdepth 1 -type f -size -200M -print0 | LC_ALL=C sort -z | xargs -r -0 md5sum ) > "$O/gem5/runs/$rel/files.md5" 2>&1
  done
  echo "   gem5/: $(find "$O/gem5/runs" -name config.ini | wc -l) runs"

  # The program binaries: what was traced (dynamic) and what gem5 ran
  # (static). Their symbol tables let the laptop map each trace's sampled
  # instruction addresses to functions, so a trace of the wrong program shows.
  mkdir -p "$O/elf"
  find "$S/tracer/splash-3/codes" "$S/tracer/parsec" "$S/tracer/pin" "$HOME"/splash-static* "$HOME/splash-heldout" \
       "$HOME/b3_heldout_build" "$HOME/barnes_std_build" "$HOME/b3_canneal8" -maxdepth 6 -type f -size -80M \
       \( -iname 'canneal*' -o -iname 'barnes*' -o -iname 'ocean*' -o -iname 'radix*' -o -iname 'water*' -o -iname 'fmm*' \) \
       2>/dev/null | LC_ALL=C sort -u | while IFS= read -r b; do
    [ "$(head -c 4 "$b" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ] || continue
    n=$(echo "${b#"$HOME"/}" | sed 's|/|__|g')
    printf '%s md5=%s size=%s mtime=%s %s\n' "$b" "$(md5sum < "$b" | cut -c1-32)" "$(stat -c %s "$b")" "$(date -r "$b" '+%F_%T')" \
      "$(file -b "$b" 2>/dev/null | cut -d, -f1-2 | tr ' ' '_')" >> "$O/elf/list.txt"
    nm -n --defined-only "$b" 2>/dev/null | awk '$2 ~ /^[TtWw]$/' > "$O/elf/$n.nm"
  done
  echo "   elf/: $(wc -l < "$O/elf/list.txt" 2>/dev/null || echo 0) program binaries"

  tar -C "$A" -cJf "$A/collect_$stamp.tar.xz" "collect_$stamp" && rm -rf "$O"
  echo "done: $A/collect_$stamp.tar.xz ($(du -h "$A/collect_$stamp.tar.xz" | cut -f1))"
}

trace_one() {   # $1 = real path of a trace; writes $A/traces/<name>.{md5,mix,done}
  local f="$1" n rd
  n=$(echo "$f" | sed "s|^$S/traces/||; s|^$HOME/||; s|/|__|g")
  [ -f "$A/traces/$n.done" ] && return 0
  case "$f" in *.xz) rd="xz -dc" ;; *.gz) rd="gzip -dc" ;; *) rd="cat" ;; esac
  # One read of the file: the md5 of the bytes on disk, and the count of what they decompress to.
  rm -f "$A/traces/$n.md5"
  ionice -c3 nice -n 19 cat "$f" | tee >(md5sum | cut -c1-32 > "$A/traces/$n.md5.tmp") | nice -n 19 $rd | nice -n 19 "$A/trace_mix" 100000 > "$A/traces/$n.mix" \
    || { echo "FAILED $f"; return 1; }
  local i=0
  while [ ! -s "$A/traces/$n.md5.tmp" ] && [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done   # the md5 finishes just after the count
  mv -f "$A/traces/$n.md5.tmp" "$A/traces/$n.md5" && echo "$f" > "$A/traces/$n.done"
}

traces() {
  local latest
  latest=$(ls -1t "$A"/collect_*.tar.xz 2>/dev/null | head -1)
  [ -n "$latest" ] || { echo "run collect first"; exit 1; }
  [ -f "$HOME/trace_mix.c" ] || { echo "no ~/trace_mix.c -- upload it with this script"; exit 1; }
  gcc -O2 -o "$A/trace_mix" "$HOME/trace_mix.c" || { echo "trace_mix does not compile"; exit 1; }
  if [ -f "$A/traces.pid" ] && kill -0 "$(cat "$A/traces.pid")" 2>/dev/null; then echo "already running (pid $(cat "$A/traces.pid"))"; exit 0; fi
  mkdir -p "$A/traces"
  tar -xJOf "$latest" --wildcards '*/traces.txt' | awk '$2 != "MISSING" { print $2 }' | LC_ALL=C sort -u > "$A/traces/list.txt"
  echo "$(wc -l < "$A/traces/list.txt") traces, $JOBS at a time, niced; results in $A/traces"
  export -f trace_one; export A S HOME
  ( setsid bash -c "echo \$\$ > '$A/traces.pid'; xargs -a '$A/traces/list.txt' -d '\n' -P $JOBS -I{} bash -c 'trace_one \"\$1\"' _ {} > '$A/traces/run.log' 2>&1; rm -f '$A/traces.pid'" < /dev/null > /dev/null 2>&1 & )
  sleep 1; echo "started"
}

traces_status() {
  local total done
  total=$(wc -l < "$A/traces/list.txt" 2>/dev/null || echo 0)
  done=$(ls "$A"/traces/*.done 2>/dev/null | wc -l)
  if [ -f "$A/traces.pid" ] && kill -0 "$(cat "$A/traces.pid")" 2>/dev/null; then echo "traces: $done of $total done, running"
  else echo "traces: $done of $total done, not running"; fi
  [ -s "$A/traces/run.log" ] && { echo "errors:"; tail -5 "$A/traces/run.log"; }
  true
}

case "${1:-}" in
  collect) collect ;;
  traces) traces ;;
  traces-status) traces_status ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
