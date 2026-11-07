#!/usr/bin/env bash
# Fetch the LLC-sensitive SPEC traces that A4 needs.
#
#   scp -P 2222 scripts/get_spec_traces.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/get_spec_traces.sh plan'   # list, download nothing
#   ssh -p 2222 user@your-server 'bash ~/get_spec_traces.sh go'     # download
#   ssh -p 2222 user@your-server 'bash ~/get_spec_traces.sh verify' # check integrity
#
# WHY: A4 is the reviewers' actual request. R1 and R2 both disbelieved the
# Hawkeye and Mockingjay numbers, and the filed rebuttal promised single-core
# baseline validation for the camera-ready. It has been blocked on "the server
# only has 429.mcf and a perlbench that never touches the LLC" -- n=1 is not a
# validation harness. These traces unblock it.
#
# SOURCE: the DPC-3 archive at Stony Brook, which is one of the two trace
# locations ChampSim's own README gives. Same format and naming as the two
# traces already on the server (429.mcf-22B, 600.perlbench_s-210B), so they
# very likely came from here originally.
#
# ChampSim reads .xz natively -- do NOT decompress these.
set -uo pipefail

BASE="https://dpc3.compas.cs.stonybrook.edu/champsim-traces/speccpu"
R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
DEST="$R/simulator/traces/spec"
LOG="$HOME/get_spec_traces.log"

# The classic memory-intensive SPEC CPU2006 set used in the SHiP, Hawkeye and
# Mockingjay evaluations. One SimPoint per benchmark: the point of A4 is to
# reproduce each policy's published delta over LRU across a spread of
# behaviours, not to characterise any single benchmark in depth.
TRACES=(
  429.mcf-22B.champsimtrace.xz
  433.milc-127B.champsimtrace.xz
  450.soplex-247B.champsimtrace.xz
  459.GemsFDTD-1169B.champsimtrace.xz
  462.libquantum-1343B.champsimtrace.xz
  470.lbm-1274B.champsimtrace.xz
  471.omnetpp-188B.champsimtrace.xz
  473.astar-153B.champsimtrace.xz
  482.sphinx3-1100B.champsimtrace.xz
  483.xalancbmk-716B.champsimtrace.xz
  410.bwaves-1963B.champsimtrace.xz
  437.leslie3d-232B.champsimtrace.xz
)

die() { echo "ERROR: $*" >&2; exit 1; }

# Size the archive claims on the server, for a truncation check.
remote_size() {
  curl -sS -I --max-time 30 "$BASE/$1" 2>/dev/null | tr -d '\r' \
    | awk -F': ' '/^Content-Length/{print $2}' | tail -1
}

# Validate a downloaded archive WITHOUT decompressing it.
#
# This used `xz -t`, which decompresses the whole stream to verify it. These
# traces expand to roughly 10 GB each, so on a machine already running twenty
# ChampSim jobs that took many minutes per file and looked like a hang. The
# realistic failure here is a truncated transfer, not bit rot -- TCP checksums
# and wget's own length check cover the latter. So: compare against the length
# the server advertised, then `xz -l`, which reads the stream index at the end
# of the file and therefore fails on truncation, in milliseconds.
validate() {
  local f="$1" want="$2" got
  [ -s "$f" ] || { echo "      empty file"; return 1; }
  got=$(stat -c %s "$f" 2>/dev/null)
  if [ -n "$want" ] && [ -n "$got" ] && [ "$want" != "$got" ]; then
    echo "      size mismatch: got $got bytes, server says $want"
    return 1
  fi
  if ! xz -l "$f" >/dev/null 2>&1; then
    echo "      xz index unreadable -- archive is truncated or corrupt"
    return 1
  fi
  return 0
}

have() { [ -s "$DEST/$1" ]; }

# 429.mcf-22B already sits in the parent traces directory from earlier work.
# Hard-link it into spec/ rather than pulling 534 MB again -- same filesystem,
# so the link costs nothing and the harness then finds every trace in one place.
adopt_existing() {
  local t="$1"
  [ -s "$DEST/$t" ] && return 0
  local parent="$R/simulator/traces/$t"
  [ -s "$parent" ] || return 1
  if ln "$parent" "$DEST/$t" 2>/dev/null; then
    echo "   adopted (hard-linked) $t from $R/simulator/traces"
    return 0
  fi
  return 1
}

phase_plan() {
  echo "== SPEC traces for A4 =="
  echo "   source: $BASE"
  echo "   dest:   $DEST"
  echo
  local t n_have=0 n_need=0
  for t in "${TRACES[@]}"; do
    if have "$t"; then
      printf '   have    %-44s %s\n' "$t" "$(du -h "$DEST/$t" | cut -f1)"
      n_have=$((n_have + 1))
    else
      printf '   MISSING %s\n' "$t"
      n_need=$((n_need + 1))
    fi
  done
  echo
  echo "   have: $n_have   to download: $n_need"
  echo "   sizes verified 2026-09-18 against the archive; all 12 returned HTTP 200:"
  echo "     omnetpp 1001M  soplex 673M  lbm 662M  mcf 534M  sphinx3 517M  xalancbmk 503M"
  echo "     milc 502M  GemsFDTD 423M  bwaves 384M  astar 376M  leslie3d 288M  libquantum 240M"
  echo "   total 6.0 GB"
  echo
  df -h "$R" | tail -1
}

# Launch detached and return. A 6 GB pull over a contended link takes long
# enough that an ssh session will not survive it -- the first attempt died to
# "client_loop: send disconnect: Broken pipe" and took wget with it, because it
# ran in the foreground. Same rule as every other long job here.
phase_go() {
  mkdir -p "$DEST" || die "cannot create $DEST"
  if pgrep -f "[g]et_spec_traces.sh __download" >/dev/null 2>&1; then
    die "a download is already running. Use 'status'."
  fi
  echo "launching detached; progress goes to $LOG"
  setsid bash "$0" __download < /dev/null >> "$LOG" 2>&1 &
  disown 2>/dev/null
  sleep 2
  tail -3 "$LOG" 2>/dev/null
  echo
  echo "check with:  bash $0 status"
}

do_download() {
  mkdir -p "$DEST" || die "cannot create $DEST"

  # A capped trace set is a few GB; refuse if the disk cannot take it. /home has
  # been near full all week and a half-written .xz is worse than none, because
  # it looks like a trace until something tries to read it.
  local free_gb
  free_gb=$(df -BG --output=avail "$DEST" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 15 ]; then
    df -h "$DEST" | tail -1
    die "only ${free_gb}G free, want at least 15G before pulling traces"
  fi
  echo "   disk: ${free_gb:-?}G free"

  command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 \
    || die "neither wget nor curl is available"

  local t ok=0 fail=0
  for t in "${TRACES[@]}"; do
    if have "$t"; then echo "   skip (already have) $t"; ok=$((ok + 1)); continue; fi
    if adopt_existing "$t"; then ok=$((ok + 1)); continue; fi
    echo "   fetching $t"
    # Download into a .part file, keep it across runs so an interrupted
    # transfer RESUMES rather than starting over, and only move it into place
    # once it validates -- a truncated .xz looks exactly like a trace until
    # something reads it.
    local tmp="$DEST/.$t.part"
    local want; want=$(remote_size "$t")
    if command -v wget >/dev/null 2>&1; then
      wget -c --progress=dot:giga --timeout=60 --tries=5 --waitretry=10 -O "$tmp" "$BASE/$t" 2>&1 | grep -vE "^\\s*$"
    else
      curl -fsS -C - --retry 3 --max-time 3600 -o "$tmp" "$BASE/$t"
    fi
    if ! validate "$tmp" "$want"; then
      echo "      FAILED -- .part kept, re-run 'go' to resume"
      fail=$((fail + 1)); continue
    fi
    mv "$tmp" "$DEST/$t"
    echo "      ok  $(du -h "$DEST/$t" | cut -f1)"
    ok=$((ok + 1))
  done

  echo
  echo "   downloaded/present: $ok    failed: $fail"
  df -h "$DEST" | tail -1
  [ "$fail" -eq 0 ] || die "$fail trace(s) failed -- re-run 'go' to retry only those"
}

phase_verify() {
  echo "== integrity =="
  local t bad=0 n=0
  for t in "${TRACES[@]}"; do
    if ! have "$t"; then printf '   %-44s MISSING\n' "$t"; bad=$((bad + 1)); continue; fi
    # xz -l by default; DEEP=1 for a full decompression check, which is slow
    # (each of these expands to roughly 10 GB).
    local check
    if [ "${DEEP:-0}" = "1" ]; then check="xz -t"; else check="xz -l"; fi
    if $check "$DEST/$t" >/dev/null 2>&1; then
      printf '   %-44s ok    %s\n' "$t" "$(du -h "$DEST/$t" | cut -f1)"
      n=$((n + 1))
    else
      printf '   %-44s CORRUPT\n' "$t"; bad=$((bad + 1))
    fi
  done
  echo
  echo "   intact: $n   problems: $bad"
  [ "$bad" -eq 0 ] || die "$bad trace(s) missing or corrupt"
  echo "   ChampSim reads .xz natively -- do not decompress."
}

phase_status() {
  echo "== download =="
  if pgrep -f "[g]et_spec_traces.sh __download" >/dev/null 2>&1; then
    echo "   running (pid $(pgrep -f '[g]et_spec_traces.sh __download' | head -1))"
  else
    echo "   not running"
  fi
  echo
  echo "== files =="
  local t done=0 part=0
  for t in "${TRACES[@]}"; do
    if [ -s "$DEST/$t" ]; then
      printf '   %-44s done     %s\n' "$t" "$(du -h "$DEST/$t" | cut -f1)"
      done=$((done + 1))
    elif [ -s "$DEST/.$t.part" ]; then
      printf '   %-44s partial  %s\n' "$t" "$(du -h "$DEST/.$t.part" | cut -f1)"
      part=$((part + 1))
    else
      printf '   %-44s pending\n' "$t"
    fi
  done
  echo
  echo "   complete: $done / ${#TRACES[@]}   in progress: $part"
  echo
  echo "== last log lines =="
  tail -5 "$LOG" 2>/dev/null || echo "   (no log yet)"
  echo
  df -h "$DEST" | tail -1
}

case "${1:-}" in
  plan)       phase_plan ;;
  go)         phase_go ;;
  status)     phase_status ;;
  __download) do_download ;;
  verify)     phase_verify ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
