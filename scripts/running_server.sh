#!/usr/bin/env bash
# READ-ONLY: everything of ours running on the server, grouped by kind, with
# each chain's own status. Nothing is started, stopped or written outside a
# temporary file of its own.
#
#   bash ~/running_server.sh          # uploaded and run by scripts/running_all.sh
#
# Groups: chains (sync_server.sh __chain, with VARIANT read from the process's
# environment), runs (__job), ChampSim, tracing (__trace, Pin), gem5, xz, then
# every other process of ours that none of these matched -- so nothing is
# hidden. The report's own session is left out.
set -u
HOMED="$HOME"
S="$HOMED/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator"
me=$(id -u)
mysid=$(ps -o sid= -p $$ | tr -d ' ')
T=$(mktemp); trap 'rm -f "$T"' EXIT
# pid sid etimes pcpu rss(MB) args -- ours, the report's own session left out
ps -u "$me" -o pid=,sid=,etimes=,pcpu=,rss=,args= | awk -v s="$mysid" '$2 != s { $5 = int($5 / 1024); print }' > "$T"

dur() { local t=$1; printf '%dd%02dh%02dm' $((t / 86400)) $((t % 86400 / 3600)) $((t % 3600 / 60)); }
var_of() { tr '\0' '\n' < "/proc/$1/environ" 2> /dev/null | sed -n 's/^VARIANT=//p' | head -1; }
cwd_of() { readlink "/proc/$1/cwd" 2> /dev/null | sed "s|^$HOMED|~|"; }

echo "== machine: $(hostname), up since $(uptime -s 2>/dev/null), load $(cut -d' ' -f1-3 /proc/loadavg) on $(nproc) cores"
free -g | awk '/^Mem/ { printf "   memory: %d GB used of %d, %d GB available\n", $3, $2, $7 }'
echo "   disk (/home): $(df -BG --output=avail "$HOMED" | tail -1 | tr -d ' ') free of $(df -BG --output=size "$HOMED" | tail -1 | tr -d ' ')"
echo "== CPU by user (sum of %CPU, 100 = one core), top 6"
ps -eo user=,pcpu= | awk '{ c[$1] += $2 } END { for (u in c) printf "   %-14s %7.0f\n", u, c[u] }' | sort -k2 -nr | head -6

echo "== ours: $(wc -l < "$T") processes"
used=$(mktemp); trap 'rm -f "$T" "$used"' EXIT
mark() { echo "$1" >> "$used"; }

echo "-- chains (sync_server.sh __chain and other drivers)"
n=0
while read -r pid sid et cpu rss args; do
  case "$args" in
    *sync_server*.sh\ __chain*|*__chain*) echo "   pid $pid VARIANT=$(var_of "$pid") up $(dur "$et"): ${args:0:110}"; mark "$pid"; n=$((n + 1)) ;;
    *launch_b3_gem5.sh*|*heldout2_server.sh*|*streamfix_server.sh*|*run_phase_a.sh*|*newbench_server.sh*|*relaunch_*|*_chain.sh*)
      echo "   pid $pid up $(dur "$et"): ${args:0:120}"; mark "$pid"; n=$((n + 1)) ;;
  esac
done < "$T"
[ "$n" -gt 0 ] || echo "   none"

echo "-- runs being executed (__job: suffix workload cores scaled warm-up measured traces [policy regime mshr])"
# each job is two processes with the same arguments (its shell and the subshell
# that runs ChampSim): one line per job
jl=$(while read -r pid sid et cpu rss args; do
  case "$args" in *" __job "*) echo "   VARIANT=$(var_of "$pid") up $(dur "$et"): ${args#* __job }"; mark "$pid" ;; esac
done < "$T" | sort -u)
[ -n "$jl" ] && { echo "$jl"; echo "   ($(echo "$jl" | wc -l) runs)"; } || echo "   none"

echo "-- ChampSim processes (binary, config, time, %CPU, RSS MB; progress: the slowest and fastest core's latest heartbeat"
echo "   against warm-up + measured, and a straight-line guess at the time left from the slowest core)"
n=0
while read -r pid sid et cpu rss args; do
  case "$args" in *"/bin/champsim"*" --config "*)
    b=$(echo "$args" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\/bin\/champsim/) { n = split($i, a, "/"); print a[n]; exit } }')
    c=$(echo "$args" | sed -n 's/.* --config \([^ ]*\).*/\1/p' | sed "s|^$HOMED|~|")
    printf '   %-26s %-60s %s %5s%% %5s\n' "$b" "$c" "$(dur "$et")" "$cpu" "$rss"; mark "$pid"; n=$((n + 1))
    # the run's log is its standard output; heartbeat counts run on through warm-up.
    # Only complete heartbeat lines: ChampSim's output reaches the file in
    # blocks, so its last line is often cut mid-number ("150000000" read as 15)
    lg=$(readlink "/proc/$pid/fd/1" 2> /dev/null)
    wu=$(echo "$args" | sed -n 's/.*--warmup-instructions \([0-9]*\).*/\1/p'); si=$(echo "$args" | sed -n 's/.*--simulation-instructions \([0-9]*\).*/\1/p')
    if [ -n "$lg" ] && [ -f "$lg" ] && [ -n "$wu" ] && [ -n "$si" ]; then
      grep -a -E '^Heartbeat CPU [0-9]+ instructions: [0-9]+ cycles: [0-9]+ .*\(Simulation time: [^)]*\)$' "$lg" | awk -v tgt=$((wu + si)) -v et="$et" '
        { c[$3] = $5 }
        END { lo = -1; hi = 0; k = 0
              for (x in c) { k++; if (lo < 0 || c[x] < lo) lo = c[x]; if (c[x] > hi) hi = c[x] }
              if (k == 0) { print "      progress: no heartbeat yet"; exit }
              left = (lo > 0 && lo < tgt) ? et * (tgt - lo) / lo : 0
              printf "      progress: %d cores, slowest %.0f M, fastest %.0f M of %.0f M (%.0f%%); time left at this pace ~%.0f h\n",
                     k, lo / 1e6, hi / 1e6, tgt / 1e6, 100 * lo / tgt, left / 3600 }'
    fi ;; esac
done < "$T"
echo "   ($n ChampSim)"

echo "-- tracing (__trace, Pin tools: tracer, counter, probe)"
n=0
while read -r pid sid et cpu rss args; do
  case "$args" in
    *" __trace "*) echo "   VARIANT=$(var_of "$pid") up $(dur "$et"): __trace ${args#* __trace }"; mark "$pid" ;;
    *champsim_tracer.so*|*stream_count.so*|*h2probe.so*|*/pin\ *|*pinbin*)
      tool=$(echo "$args" | sed -n 's/.* -t \([^ ]*\).*/\1/p' | sed "s|^$HOMED|~|")
      prog=$(echo "$args" | sed -n 's/.* -- \(.*\)/\1/p')
      echo "   pin up $(dur "$et") ${cpu}% ${rss} MB, tool ${tool:-?}, in $(cwd_of "$pid"): ${prog:0:90}"; mark "$pid"; n=$((n + 1)) ;;
  esac
done < "$T"
echo "   ($n Pin)"

echo "-- gem5 (output directory, time, %CPU, RSS MB)"
n=0
while read -r pid sid et cpu rss args; do
  case "$args" in
    *gem5.opt*)
      o=$(echo "$args" | sed -n 's/.*--outdir=\([^ ]*\).*/\1/p' | sed "s|^$HOMED|~|")
      case "$args" in timeout\ *|*/timeout\ *) mark "$pid"; continue ;; esac   # its timeout wrapper: the gem5 line below stands for it
      printf '   %-62s %s %5s%% %5s\n' "${o:-?}" "$(dur "$et")" "$cpu" "$rss"; mark "$pid"; n=$((n + 1)) ;;
  esac
done < "$T"
echo "   ($n gem5)"

x=$(awk '$6 ~ /(^|\/)xz$/ || $6 ~ /(^|\/)xz / { n++ } END { print n + 0 }' "$T")
echo "-- xz (trace compression): $x"
awk '$6 ~ /(^|\/)xz$/ { print $1 }' "$T" >> "$used"

echo "-- everything else of ours (not counted above; shells, sleeps and sshd shown by count only)"
others=$(awk 'NR == FNR { u[$1] = 1; next } !($1 in u)' "$used" "$T")
echo "$others" | awk 'NF { a = $6; for (i = 7; i <= NF; i++) a = a " " $i; if (a ~ /^(-?bash|sh|sleep|sshd|\/usr\/bin\/bash|\/bin\/bash|\/bin\/sh|tee|cat|tail|ps|awk|sed|grep|xargs|nice|setsid)( |$)/) { split(a, w, " "); k[w[1]]++ } else printf "   pid %s up %dd%02dh%02dm %s%%: %s\n", $1, $3 / 86400, $3 % 86400 / 3600, $3 % 3600 / 60, $4, substr(a, 1, 120) } END { s = ""; for (x in k) s = s " " x " " k[x] ";"; if (s != "") print "   by count:" s }'

echo
echo "== chains, their own status"
for v in pol nb; do
  [ -f "$HOMED/sync_server.sh" ] && VARIANT=$v bash "$HOMED/sync_server.sh" status 2>&1 | sed 's/^/   /' | head -16
done
[ -f "$HOMED/sync_server_h2.sh" ] && VARIANT=h2 bash "$HOMED/sync_server_h2.sh" status 2>&1 | head -2 | sed 's/^/   /'
echo "== held-out set 2, gem5"
for p in fluidanimate bodytrack facesim vips oceannc; do
  [ -f "$HOMED/launch_b3_gem5.sh" ] && WL=$p bash "$HOMED/launch_b3_gem5.sh" status 2>&1 | sed 's/^/   /'
done
echo "== our crontab (@reboot resumes)"
c=$(crontab -l 2>/dev/null | grep -v '^#' | grep .); [ -n "$c" ] && echo "$c" | sed 's/^/   /' || echo "   none"
