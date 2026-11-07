#!/usr/bin/env bash
# The speed test (bench/policy_sanity/speed_design_2026-10-18.md): gem5 and
# ChampSim on the standard barnes, at once, each configuration twice.
# Writes only under ~/speed; touches no binary, trace, run or queue.
#
#   bash ~/speed_server.sh go       # start the 12 runs, detached (about 1-3 h)
#   bash ~/speed_server.sh status
#   bash ~/speed_server.sh report   # instructions per CPU-second, and P1-P3
set -uo pipefail
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
W="${W:-$HOME/speed}"
GEM5_DIR="${GEM5_DIR:-$HOME/gem5}"
BUILD="X86"; [ -f "$GEM5_DIR/.gem5_build_dir" ] && BUILD="$(cat "$GEM5_DIR/.gem5_build_dir")"
GEM5="${GEM5:-$GEM5_DIR/build/$BUILD/gem5.opt}"
SE="$GEM5_DIR/configs/deprecated/example/se.py"
BINS="${BINS:-$HOME/splash-static}"
RUNNER="${RUNNER:-$HOME/run_gem5_splash.sh}"     # its barnes-input writes the B3 runs' barnes.in
CS_NEW="${CS_NEW:-$S/bin/champsim_b3v4_69ebdcce}"
CS_OLD="${CS_OLD:-$S/bin/champsim_phaseA_20260923}"
TR="${TR:-$S/traces/barnes_std_4t}"
TRACES="${TRACES:-barnes0_aligned.champsimtrace barnes1.champsimtrace barnes2.champsimtrace barnes3.champsimtrace}"
STOP="${STOP:-30000000}"          # gem5: until a thread commits this many
PERCORE="${PERCORE:-25000000}"    # ChampSim: per core, from the aligned start
REPS="${REPS:-2}"
TIME_BIN="${TIME_BIN:-/usr/bin/time}"
CONFIGS="G-ts-ruby G-o3-ruby G-o3-classic C-l2 C-l0 C-before"

die() { echo "STOPPED: $*"; exit 1; }

ruby_caches="--ruby --l0i_size=32kB --l0i_assoc=8 --l0d_size=32kB --l0d_assoc=8 --l1d_size=512kB --l1d_assoc=8 --l2_size=2MB --l2_assoc=16 --num-l2caches=1 --num-clusters=1"
classic_caches="--caches --l2cache --l1i_size=32kB --l1i_assoc=8 --l1d_size=32kB --l1d_assoc=8 --l2_size=2MB --l2_assoc=16"

preflight() {
  [ -x "$TIME_BIN" ] || die "no $TIME_BIN (GNU time)"
  "$TIME_BIN" -f "%U" true 2>/dev/null || die "$TIME_BIN does not take -f"
  [ -x "$GEM5" ] || die "no gem5 at $GEM5"
  [ "$(cat "$GEM5_DIR/.gem5_protocol" 2>/dev/null)" = MESI_Three_Level ] || die "gem5 is not the MESI_Three_Level build"
  [ -x "$BINS/BARNES" ] || die "no $BINS/BARNES"
  [ -f "$RUNNER" ] || die "no $RUNNER"
  for b in "$CS_NEW" "$CS_OLD"; do [ -x "$b" ] || die "no $b"; done
  for t in $TRACES; do [ -f "$TR/$t" ] || die "no $TR/$t"; done
  [ -x "$S/scripts/make_config.py" ] || die "no make_config.py"
}

o3_name() {   # the out-of-order CPU's name in this gem5
  "$GEM5" "$SE" --list-cpu-types 2>/dev/null | grep -o -E '\b(X86O3CPU|DerivO3CPU|O3CPU)\b' | head -1
}

# "( cd X || exit 1; setsid ... & )", never "( cd X && setsid ... & )": the &
# would background the whole && list as a subshell that holds the caller's
# pipe until the run ends (the 0700b8c bug, repeated here on 2026-10-18 and
# caught when speed_all.sh did not return).
start_gem5() {   # $1 run dir  $2 cpu type  $3 cache options
  local d="$1"
  mkdir -p "$d"
  bash "$RUNNER" barnes-input "$d/barnes.in" 4 > /dev/null || die "barnes-input failed"
  # shellcheck disable=SC2086 -- $3 is a list of options
  ( cd "$d" || exit 1; setsid nice -n 19 "$TIME_BIN" -f "TIME wall %e user %U sys %S maxrss_kb %M" -o "$d/time.txt" \
      "$GEM5" --outdir="$d" "$SE" --num-cpus=4 --cpu-type="$2" --mem-size=4GB $3 --maxinsts="$STOP" \
      -c "$BINS/BARNES" -i "$d/barnes.in" < /dev/null > "$d/run.log" 2>&1 & )
}

start_champsim() {   # $1 run dir  $2 binary  $3 level
  local d="$1" t list=""
  mkdir -p "$d"
  "$S/scripts/make_config.py" --policy lru --cores 4 --regime shared --private-coherence "$3" -o "$d/cfg.json" || die "make_config failed"
  for t in $TRACES; do list="$list $TR/$t"; done
  # shellcheck disable=SC2086 -- $list is a list of trace paths
  ( cd "$S" || exit 1; setsid nice -n 19 "$TIME_BIN" -f "TIME wall %e user %U sys %S maxrss_kb %M" -o "$d/time.txt" \
      "$2" --config "$d/cfg.json" --warmup-instructions 0 --simulation-instructions "$PERCORE" $list \
      < /dev/null > "$d/run.log" 2>&1 & )
}

go() {
  preflight
  local o3; o3=$(o3_name)
  [ -n "$o3" ] || die "this gem5 lists no out-of-order CPU"
  echo "gem5 $GEM5 (md5 $(md5sum < "$GEM5" | cut -c1-12)); out-of-order CPU: $o3"
  echo "ChampSim: $(basename "$CS_NEW"), $(basename "$CS_OLD"); traces $TR"
  mkdir -p "$W"
  echo "$o3" > "$W/o3_name.txt"
  local c r d
  for r in $(seq 1 "$REPS"); do
    for c in $CONFIGS; do
      d="$W/$c.$r"
      if [ -f "$d/time.txt" ] && grep -q '^TIME' "$d/time.txt"; then echo "   $c.$r: done already"; continue; fi
      if pgrep -u "$(id -u)" -f -- "--outdir=$d |--config $d/cfg.json" > /dev/null 2>&1; then echo "   $c.$r: running"; continue; fi
      rm -rf "$d"
      case "$c" in
        G-ts-ruby)    start_gem5 "$d" TimingSimpleCPU "$ruby_caches" ;;
        G-o3-ruby)    start_gem5 "$d" "$o3" "$ruby_caches" ;;
        G-o3-classic) start_gem5 "$d" "$o3" "$classic_caches" ;;
        C-l2)         start_champsim "$d" "$CS_NEW" 2 ;;
        C-l0)         start_champsim "$d" "$CS_NEW" 0 ;;
        C-before)     start_champsim "$d" "$CS_OLD" 0 ;;
      esac
      echo "   $c.$r: started"
    done
  done
}

status() {
  local d n=0 done=0
  for d in "$W"/*.[0-9]; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    if [ -f "$d/time.txt" ] && grep -q '^TIME' "$d/time.txt"; then done=$((done + 1)); printf '   %-16s done\n' "$(basename "$d")"
    else printf '   %-16s running\n' "$(basename "$d")"; fi
  done
  echo "speed: $done of $n runs done"
}

report() {
  python3 - "$W" "$CONFIGS" << 'EOF'
import os, re, sys
W, configs = sys.argv[1], sys.argv[2].split()
rows = {}
print(f'{"run":16s} {"instructions":>14s} {"cpu s":>9s} {"wall s":>9s} {"K instr / cpu s":>16s} {"peak MB":>8s}  check')
for c in configs:
    for d in sorted(x for x in os.listdir(W) if x.startswith(c + '.')):
        p = os.path.join(W, d)
        t = open(os.path.join(p, 'time.txt')).read() if os.path.exists(os.path.join(p, 'time.txt')) else ''
        m = re.search(r'TIME wall ([\d.]+) user ([\d.]+) sys ([\d.]+) maxrss_kb (\d+)', t)
        if not m:
            print(f'{d:16s} (not finished)'); continue
        wall, user, sysf, rss = float(m.group(1)), float(m.group(2)), float(m.group(3)), int(m.group(4))
        log = open(os.path.join(p, 'run.log'), errors='replace').read()
        if c.startswith('G-'):
            st = os.path.join(p, 'stats.txt')
            ins = 0
            if os.path.exists(st):
                for line in open(st):
                    if line.startswith('simInsts'):
                        ins = int(float(line.split()[1])); break
            ok = 'ok' if 'max instruction count' in log else 'DID NOT END AT ITS STOP'
        else:
            ins = sum(int(x) for x in re.findall(r'Simulation complete CPU \d+ instructions: (\d+)', log))
            ok = 'ok' if 'ChampSim completed all CPUs' in log and 'Reached end of trace' not in log else 'INCOMPLETE OR WRAPPED'
            lv = re.search(r'PRIVATE-CACHE COHERENCE LEVEL: (\d)', log)
            want = {'C-l2': '2', 'C-l0': '0', 'C-before': None}[c]
            if (lv.group(1) if lv else None) != want:
                ok += f'; level printed {lv.group(1) if lv else "none"}, expected {want}'
        rate = ins / (user + sysf) / 1e3 if user + sysf else 0
        rows.setdefault(c, []).append(rate)
        print(f'{d:16s} {ins:14,d} {user + sysf:9.0f} {wall:9.0f} {rate:16.1f} {rss / 1024:8.0f}  {ok}')
print()
mean = {c: sum(v) / len(v) for c, v in rows.items() if v}
for c in configs:
    if c in mean:
        v = rows[c]
        print(f'{c:14s} mean {mean[c]:8.1f} K instr / cpu s   (repeats {", ".join("%.1f" % x for x in v)}; spread {100 * (max(v) - min(v)) / mean[c]:.1f}%)')
print()
def ratio(a, b):
    return mean[a] / mean[b] if a in mean and b in mean and mean[b] else float('nan')
r1, r2, r3 = ratio('C-l2', 'G-o3-ruby'), ratio('G-ts-ruby', 'C-l2'), ratio('C-l2', 'C-before')
print(f'P1  C-l2 / G-o3-ruby   = {r1:.2f}   (holds if >= 2)   {"HOLDS" if r1 >= 2 else "FAILS"}')
print(f'P2  G-ts-ruby / C-l2   = {r2:.2f}   (holds if >= 1)   {"HOLDS" if r2 >= 1 else "FAILS"}')
print(f'P3  C-l2 / C-before    = {r3:.2f}   (holds if >= 0.7) {"HOLDS" if r3 >= 0.7 else "FAILS"}')
print(f'reported: C-l2 / G-o3-classic = {ratio("C-l2", "G-o3-classic"):.2f}; C-l0 / C-before = {ratio("C-l0", "C-before"):.2f}')
EOF
}

case "${1:-}" in
  go) go ;;
  status) status ;;
  report) report ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
