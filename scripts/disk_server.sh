#!/usr/bin/env bash
# Clear the server's disk of what is not needed (owner, 2026-10-18).
#
#   bash ~/disk_server.sh report   # READ-ONLY: sizes, what is in use, and a proposal -> ~/disk/proposal.tsv
#   bash ~/disk_server.sh go       # carry out ~/disk/proposal.tsv, as the owner approved it (detached)
#   bash ~/disk_server.sh status
#
# Only paths under ~ (this account) are ever touched; never another user's
# files, never /tmp. Actions:
#   COMPRESS  a trace still needed but stored uncompressed: xz -1, the result
#             checked byte for byte against the original, only then the
#             original removed (ChampSim reads .xz directly). Nothing is lost.
#   DELETE    obsolete: a void or dropped trace set, a build tree whose binary
#             is frozen in the main tree, a core dump.
#   KEEP      needed: traces in use or planned, every result log (evidence,
#             small), gem5, the program binaries, the source trees.
#   ASK       not recognised: listed with its size, never touched.
# go skips any path a running process has open or names on its command line,
# and says so; run go again after that job ends.
set -uo pipefail
R="${R:-$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy}"
S="$R/simulator"
T="$S/traces"
D="${D:-$HOME/disk}"
mkdir -p "$D"

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }
size_of() { du -sb "$1" 2>/dev/null | cut -f1; }

# A trace or directory under traces/ -> action and reason
classify_trace() {   # path relative to traces/
  local p="$1"
  case "$p" in
    sync|sync/*)                         echo "KEEP|synchronised-replay traces (step 2, running)" ;;
    canneal_4t|canneal_8t|canneal_16t)   echo "KEEP|the canneal evaluation traces (compressed)" ;;
    barnes_4t[0-3].champsimtrace.xz)     echo "KEEP|barnes-256 (the gem5 comparison on its own program; small)" ;;
    *.champsimtrace.xz)                  case "$p" in [0-9][0-9][0-9].*|[0-9][0-9][0-9][0-9].*) echo "KEEP|SPEC (A4 baseline validation)" ;; *) echo "ASK|a compressed trace not recognised" ;; esac ;;
    ocean_4t|radix_4t|waternsq_4t|fmm_4t|barnes_std_4t) echo "DIR|" ;;
    canneal_big*|canneal_tiny*|canneal_simlarge*) echo "DELETE|pre-migration canneal mixes (duplicated threads; void)" ;;
    canneal[0-9].champsimtrace*|canneal[0-9][0-9].champsimtrace*) echo "DELETE|pre-migration top-level canneal traces (superseded by canneal_Nt/)" ;;
    ocean_8t|water_8t)                   echo "DELETE|out of the evaluation (trace-wrap margin at 8 cores)" ;;
    fluidanimate*|fluid*)                echo "DELETE|fluidanimate dropped (its traces carried no data accesses)" ;;
    barnes_big*)                         echo "DELETE|pre-migration barnes variant" ;;
    *)                                   echo "ASK|not recognised" ;;
  esac
}

in_use() {   # path -> 0 if a running process of ours has it open or names it
  local p="$1" pid
  for pid in $(pgrep -u "$(id -u)"); do
    [ -d "/proc/$pid" ] || continue
    if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$p"; then return 0; fi
    if ls -l "/proc/$pid/fd" 2>/dev/null | grep -qF -- "$p"; then return 0; fi
    case "$(readlink "/proc/$pid/cwd" 2>/dev/null)/" in "$p"/*) return 0 ;; esac
  done
  return 1
}

report() {
  local P="$D/proposal.tsv" f rel cls act why sz total_del=0 total_cmp=0
  : > "$P"
  echo "== disk: $(df -h "$HOME" | tail -1 | awk '{print $4 " free of " $2}')   ($(date '+%F %T'))"
  echo
  echo "== the largest things in ~ (top level)"
  du -sb "$HOME"/* "$HOME"/.[!.]* 2>/dev/null | sort -rn | head -15 | while read -r sz f; do printf '   %8s  %s\n' "$(human "$sz")" "${f#"$HOME"/}"; done
  echo
  echo "== traces/ ($(human "$(size_of "$T")"))"
  for f in "$T"/*; do
    [ -e "$f" ] || continue
    rel="${f#"$T"/}"
    cls=$(classify_trace "$rel"); act="${cls%%|*}"; why="${cls#*|}"
    if [ "$act" = DIR ]; then
      # the uncompressed per-program sets: each raw file is compressed; .xz kept
      local g
      for g in "$f"/*; do
        [ -f "$g" ] || continue
        case "$g" in
          *.champsimtrace) sz=$(size_of "$g"); printf 'COMPRESS\t%s\t%s\t%s\n' "$g" "$sz" "needed, uncompressed" >> "$P"; total_cmp=$((total_cmp + sz)) ;;
          *) printf 'KEEP\t%s\t%s\t%s\n' "$g" "$(size_of "$g")" "already compressed or small" >> "$P" ;;
        esac
      done
      continue
    fi
    sz=$(size_of "$f")
    printf '%s\t%s\t%s\t%s\n' "$act" "$f" "$sz" "$why" >> "$P"
    [ "$act" = DELETE ] && total_del=$((total_del + sz))
  done
  # Home-level items
  for f in "$HOME/c0_build" "$HOME/diag_build"; do
    [ -d "$f" ] || continue
    sz=$(size_of "$f"); printf 'DELETE\t%s\t%s\t%s\n' "$f" "$sz" "build tree; its binary is frozen in the main tree's bin/, its sources in git" >> "$P"
    total_del=$((total_del + sz))
  done
  while IFS= read -r f; do
    file -b "$f" 2>/dev/null | grep -q 'core file' || continue   # only a real core dump
    sz=$(size_of "$f"); printf 'DELETE\t%s\t%s\t%s\n' "$f" "$sz" "core dump" >> "$P"; total_del=$((total_del + sz))
  done < <(find "$HOME" "$S" -maxdepth 1 -type f \( -name core -o -name 'core.[0-9]*' \) 2>/dev/null)
  for f in "$HOME/gem5" "$HOME/sync_build" "$HOME/b3_heldout_build" "$HOME/barnes_std_build" "$S/results" "$HOME/.build_tmp"; do
    [ -e "$f" ] && printf 'KEEP\t%s\t%s\t%s\n' "$f" "$(size_of "$f")" "needed (gem5, current builds, program binaries, result logs, Pin's temp)" >> "$P"
  done
  echo
  echo "== proposal (~/disk/proposal.tsv)"
  for act in DELETE COMPRESS ASK KEEP; do
    local n tot
    n=$(awk -F'\t' -v a="$act" '$1 == a' "$P" | wc -l)
    tot=$(awk -F'\t' -v a="$act" '$1 == a { s += $3 } END { print s + 0 }' "$P")
    [ "$n" -gt 0 ] || continue
    echo "   $act: $n item(s), $(human "$tot")"
    awk -F'\t' -v a="$act" '$1 == a' "$P" | sort -t$'\t' -k3,3nr | while IFS=$'\t' read -r a p s w; do
      u=""; in_use "$p" && u="  [IN USE NOW: go will skip it]"
      printf '      %8s  %s -- %s%s\n' "$(human "$s")" "${p#"$HOME"/}" "$w" "$u"
    done
  done
  echo
  echo "   DELETE frees about $(human "$total_del"); COMPRESS about $(human $((total_cmp * 9 / 10))) more (traces compress 90% or better)."
  echo "   Nothing has been changed. To carry this out: scripts/disk_all.sh go"
}

do_go() {
  local P="$D/proposal.tsv" a p s w log="$D/go.log"
  [ -s "$P" ] || { echo "no proposal -- run report first"; exit 1; }
  echo $$ > "$D/.go.pid"
  echo "$(date '+%F %T') GO START (free: $(df -h "$HOME" | tail -1 | awk '{print $4}'))" >> "$log"
  while IFS=$'\t' read -r a p s w; do
    case "$a" in DELETE|COMPRESS) ;; *) continue ;; esac
    case "$p" in "$HOME"/*) ;; *) echo "$(date '+%F %T') REFUSED (outside ~) $p" >> "$log"; continue ;; esac
    [ -e "$p" ] || { echo "$(date '+%F %T') GONE already $p" >> "$log"; continue; }
    if in_use "$p"; then echo "$(date '+%F %T') SKIPPED (in use) $p" >> "$log"; continue; fi
    if [ "$a" = DELETE ]; then
      rm -rf -- "$p" && echo "$(date '+%F %T') DELETED $p ($s bytes)" >> "$log"
    else
      if [ -e "$p.xz" ]; then echo "$(date '+%F %T') SKIPPED ($p.xz exists) $p" >> "$log"; continue; fi
      if nice -n 19 xz -1 -T4 -k -- "$p" && nice -n 19 xz -dc -- "$p.xz" | cmp -s - "$p"; then
        rm -f -- "$p" && echo "$(date '+%F %T') COMPRESSED $p ($s -> $(size_of "$p.xz") bytes; checked byte for byte)" >> "$log"
      else
        rm -f -- "$p.xz"; echo "$(date '+%F %T') FAILED to compress $p (original kept)" >> "$log"
      fi
    fi
  done < "$P"
  echo "$(date '+%F %T') GO END (free: $(df -h "$HOME" | tail -1 | awk '{print $4}'))" >> "$log"
  rm -f "$D/.go.pid"
}

case "${1:-}" in
  report) report ;;
  go)
    if [ -f "$D/.go.pid" ] && kill -0 "$(cat "$D/.go.pid")" 2>/dev/null; then echo "already running"; exit 0; fi
    setsid bash "$(readlink -f "$0")" __go < /dev/null > /dev/null 2>&1 &
    disown 2>/dev/null; sleep 1
    echo "started; it works through ~/disk/proposal.tsv (compression can take an hour or more); progress: bash ~/disk_server.sh status" ;;
  __go) do_go ;;
  status)
    echo "== disk: $(df -h "$HOME" | tail -1 | awk '{print $4 " free"}'); clean-up $([ -f "$D/.go.pid" ] && kill -0 "$(cat "$D/.go.pid")" 2>/dev/null && echo running || echo 'not running')"
    [ -f "$D/go.log" ] && tail -15 "$D/go.log" | sed 's/^/   /' ;;
  *) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
