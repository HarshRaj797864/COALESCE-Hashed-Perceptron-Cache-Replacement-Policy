#!/usr/bin/env bash
# D (bench/policy_sanity/hw_direction_design_2026-11-18.md): the bundle carried to the i7. Laptop only.
#
#   bash scripts/hw_bundle.sh pull   # the 7 traced binaries and their inputs, copied from the server (read-only), md5-checked
#   bash scripts/hw_bundle.sh make   # simulator/results/hw/hw_bundle.tar.gz: scripts, the micro, binaries, inputs, PROGS, MD5S, README
#
# The binaries are the ones the traces were recorded from (sync_server.sh's PROGS, ~/newbench/PROGS, ~/heldout2/PROGS),
# not rebuilt: the same code as traced. Their highest GLIBC symbol version is written to REQUIRES; an i7 with an older C
# library cannot run them as they are, so every program runs on the libraries it was traced with: the server's loader,
# libc, libm, libstdc++, libgcc_s (libs/), invoked through that loader by hw_run.sh (fixed 2026-11-23, before any count).
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
H=user@your-server
P=2222
L="$ROOT/simulator/results/hw/files"
B="$ROOT/simulator/results/hw/hw_bundle"
R=/home/harshraj/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator

FILES="ocean/OCEAN|$R/tracer/splash-3/codes/apps/ocean/contiguous_partitions/OCEAN
canneal/canneal|$R/tracer/pin/canneal
canneal/100000.nets|$R/tracer/pin/100000.nets
barnes/BARNES|/home/harshraj/barnes_std_build/codes/apps/barnes/BARNES
barnes/n16384-p4|$R/tracer/splash-3/codes/apps/barnes/inputs/n16384-p4
radix/RADIX.dyn|/home/harshraj/b3_heldout_build/radix/codes/kernels/radix/RADIX.dyn
lunc/LU.dyn|/home/harshraj/newbench_build/lunc/codes/kernels/lu/non_contiguous_blocks/LU.dyn
fluidanimate/fluidanimate.dyn|/home/harshraj/heldout2_build/fluidanimate/fluidanimate.dyn
fluidanimate/in_35K.fluid|/home/harshraj/heldout2/fluidanimate/inputs/simsmall/in_35K.fluid
vips/vips.dyn|/home/harshraj/heldout2_build/vips/vips.dyn
vips/pomegranate_1600x1200.v|/home/harshraj/heldout2/vips/inputs/simsmall/pomegranate_1600x1200.v
libs/ld-linux-x86-64.so.2|/lib64/ld-linux-x86-64.so.2
libs/libc.so.6|/lib/x86_64-linux-gnu/libc.so.6
libs/libm.so.6|/lib/x86_64-linux-gnu/libm.so.6
libs/libstdc++.so.6|/lib/x86_64-linux-gnu/libstdc++.so.6
libs/libgcc_s.so.1|/lib/x86_64-linux-gnu/libgcc_s.so.1
libs/libdl.so.2|/lib/x86_64-linux-gnu/libdl.so.2
libs/libpthread.so.0|/lib/x86_64-linux-gnu/libpthread.so.0"

# name|anchor_n|dir|stdin|command: the traced runs' arguments; anchor_n = thread 0's creates in the traced run
# (the tracers' "thread 0 calls: ... create N": SPLASH-3 at -p4 3, canneal 4, fluidanimate 4, vips 6)
PROGS="ocean|3|progs/ocean||./OCEAN -n514 -p4 -e1e-7 -r20000 -t28800
canneal|4|progs/canneal||./canneal 4 15000 2000 100000.nets 128
barnes|3|progs/barnes|n16384-p4|./BARNES
radix|3|progs/radix||./RADIX.dyn -p4 -n16777216 -r1024
lunc|3|progs/lunc||./LU.dyn -n1024 -p4 -b16
fluidanimate|4|progs/fluidanimate||./fluidanimate.dyn 4 5 in_35K.fluid out.fluid
vips|6|progs/vips||./vips.dyn --vips-concurrency=4 im_benchmark pomegranate_1600x1200.v output.v"

pull() {
  mkdir -p "$L"
  local paths; paths=$(echo "$FILES" | cut -d'|' -f2 | tr '\n' ' ')
  # shellcheck disable=SC2029
  timeout 120 ssh -p "$P" "$H" "md5sum $paths" > "$L/SERVER_MD5S"
  local name src
  while IFS='|' read -r name src; do
    mkdir -p "$L/$(dirname "$name")"
    timeout 300 scp -q -P "$P" "$H:$src" "$L/$name"
    local want got
    want=$(awk -v s="$src" '$2 == s { print $1 }' "$L/SERVER_MD5S")
    got=$(md5sum < "$L/$name" | cut -d' ' -f1)
    [ -n "$want" ] && [ "$want" = "$got" ] || { echo "STOPPED: $name: md5 $got, the server's $want"; exit 1; }
    echo "   $name  $got"
  done <<< "$FILES"
  echo "pulled: $L (every file equal to the server's)"
}

make_bundle() {
  [ -s "$L/SERVER_MD5S" ] || { echo "STOPPED: run 'pull' first"; exit 1; }
  rm -rf "$B"; mkdir -p "$B/progs"
  cp "$ROOT/scripts/hw_run.sh" "$ROOT/scripts/hw_anchor_shim.c" "$ROOT/scripts/hw_score.py" "$ROOT/bench/coherence_micro.c" "$B/"
  # the none4 / none3 cases (the note's build record, part 1): while C's runs need the tree's micro unchanged, they are
  # inserted into the bundle's copy only, after the s16 line, exactly as checked (step tables, masked disassembly)
  if ! grep -q '"none4"' "$B/coherence_micro.c"; then
    grep -c 'else if (!strcmp(c, "s16"))' "$B/coherence_micro.c" | grep -qx 1 || { echo "STOPPED: no single s16 line to insert after"; exit 1; }
    awk '{ print } /else if \(!strcmp\(c, "s16"\)\)/ {
      print "  /* D (hw_direction_design_2026-11-18.md): steps with no operation, the"
      print "   * barrier-only controls for the 4-step and the 3-step cases */"
      print "  else if (!strcmp(c, \"none4\")) { S(NONE, NONE, NONE, NONE, W_STEP); S(NONE, NONE, NONE, NONE, W_STEP); S(NONE, NONE, NONE, NONE, W_STEP); S(NONE, NONE, NONE, NONE, W_STEP); }"
      print "  else if (!strcmp(c, \"none3\")) { S(NONE, NONE, NONE, NONE, W_STEP); S(NONE, NONE, NONE, NONE, W_STEP); S(NONE, NONE, NONE, NONE, W_STEP); }" }' \
      "$B/coherence_micro.c" > "$B/coherence_micro.c.new" && mv "$B/coherence_micro.c.new" "$B/coherence_micro.c"
  fi
  grep -q '"none4"' "$B/coherence_micro.c" && grep -q '"none3"' "$B/coherence_micro.c" || { echo "STOPPED: the bundle's micro lacks none4 / none3"; exit 1; }
  local name src
  while IFS='|' read -r name src; do
    case "$name" in
      libs/*) mkdir -p "$B/libs"; cp "$L/$name" "$B/$name" ;;
      *) mkdir -p "$B/progs/$(dirname "$name")"; cp "$L/$name" "$B/progs/$name" ;;
    esac
  done <<< "$FILES"
  chmod +x "$B/libs/ld-linux-x86-64.so.2"
  chmod +x "$B"/progs/*/*.dyn "$B/progs/ocean/OCEAN" "$B/progs/canneal/canneal" "$B/progs/barnes/BARNES"
  echo "$PROGS" > "$B/PROGS"
  : > "$B/REQUIRES"
  for f in "$B"/progs/*/*; do
    file -b "$f" | grep -q '^ELF' || continue
    echo "${f#"$B"/} $(objdump -T "$f" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1) $(objdump -T "$f" | grep -o 'GLIBCXX_[0-9.]*' | sort -uV | tail -1)" >> "$B/REQUIRES"
  done
  cat > "$B/README" <<'EOF'
D, the hardware direction check: what to do on the i7 (an idle machine, about an hour in all)

 0. tar xzf hw_bundle.tar.gz && cd hw_bundle && md5sum -c MD5S
    Needs: gcc, perf (linux-tools for the running kernel), python3, taskset, sudo for one sysctl.
    The programs run on their own libraries (libs/, the ones they were traced with), whatever the machine's are.
 1. bash hw_run.sh record
    Send back hw_out/machine/ (a tar of it). Nothing else runs until the event names (EVENTS) come back.
 2. sudo sysctl kernel.perf_event_paranoid=0          (for this session only)
    If the governor can be set: sudo cpupower frequency-set -g performance (recorded either way)
 3. bash hw_run.sh qh EVENTS                         (about 10-20 min; the machine otherwise idle)
    python3 hw_score.py qh hw_out/qh                 (writes hw_out/QH_HELD only if QH holds)
 4. Only if QH held:  bash hw_run.sh progs EVENTS PROGS   (7 programs x 10 runs)
 5. tar czf hw_out.tar.gz hw_out   and bring it back as it is. Do not edit or rerun anything by hand.
EOF
  (cd "$B" && find . -type f ! -name MD5S | sort | xargs md5sum > MD5S)
  tar -C "$(dirname "$B")" -czf "$ROOT/simulator/results/hw/hw_bundle.tar.gz" hw_bundle
  echo "bundle: $ROOT/simulator/results/hw/hw_bundle.tar.gz ($(du -h "$ROOT/simulator/results/hw/hw_bundle.tar.gz" | cut -f1))"
  cat "$B/REQUIRES"
}

case "${1:-}" in
  pull) pull ;;
  make) make_bundle ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
