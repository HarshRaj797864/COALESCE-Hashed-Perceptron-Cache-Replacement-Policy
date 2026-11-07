#!/usr/bin/env bash
# Audit every trace on the server for the tracer's thread-indexing bug.
#
#   scp -P 2222 scripts/audit_traces.sh user@your-server:~/
#   ssh -p 2222 user@your-server 'bash ~/audit_traces.sh'
#   # one set only:
#   ssh -n -p 2222 user@your-server 'AUDIT_ROOT=$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy/simulator/traces/ocean_4t bash ~/audit_traces.sh'
#   scp -P 2222 user@your-server:~/trace_audit.txt /tmp/
#
# Read-only. Seeks into each trace and reports what fraction of instruction
# records carry any memory operand.
#
# WHY: champsim_tracer.cpp wrote every thread's memory operands into thread 0's
# buffer while emitting from each thread's own buffer, so traces from any thread
# other than 0 contain instruction pointers and nothing else. Already confirmed
# locally for canneal: big0 carries 60% memory operands, big1 through big4 carry
# 0.0% across their entire 5M records. This establishes how far that extends.
#
# Reading the output:
#   ~30-60%  healthy, the trace carries data accesses
#   0.0%     BROKEN, instruction stream only, no data accesses at all
set +e

R="$HOME/COALESCE-Hashed-Perceptron-Cache-Replacement-Policy"
OUT="$HOME/trace_audit.txt"
PY="$HOME/.audit_traces.py"

# Write the checker to a file and run it. Do NOT feed python via a heredoc that
# is part of a pipeline -- the redirection binds to the last command in the
# pipe, so `tee` eats the script and python blocks on the terminal.
cat > "$PY" << 'PYEOF'
import glob
import os
import struct
import subprocess
import sys

# Must match struct input_instr in simulator/inc/trace_instruction.h:
#   unsigned long long ip                                   -> Q
#   unsigned char      is_branch, branch_taken              -> B B
#   unsigned char      destination_registers[2]             -> 2B
#   unsigned char      source_registers[4]                  -> 4B
#   unsigned long long destination_memory[2]                -> 2Q
#   unsigned long long source_memory[4]                     -> 4Q
FMT = '<QBB2B4B2Q4Q'
SZ = struct.calcsize(FMT)
assert SZ == 64, SZ

# Unpacked field layout, 15 values:
#   0 ip | 1 is_branch | 2 branch_taken | 3-4 dest_reg | 5-8 src_reg
#   9-10 dest_mem | 11-14 src_mem
#
# The memory operands are 9..14 inclusive. An earlier version of this script
# tested `any(v[8:10]) or any(v[10:14])`, i.e. 8..13, which COUNTED
# source_registers[3] as a memory operand and IGNORED source_memory[3]. The
# healthy/broken verdict is unaffected -- a record with every field zero reads
# zero either way, which is what the broken traces were -- but the reported
# percentages on healthy traces were inflated by instructions that merely used
# a fourth source register.
N_FIELDS = 15
MEM_LO, MEM_HI = 9, 15
SAMPLE_N = 30000          # records per sample point

# Where through the file to sample. Deep points guard against a trace that is
# healthy at the head and broken later -- which is what the tracer bug looked
# like before it was understood.
#
# For a COMPRESSED trace this is expensive: an xz stream cannot be seeked, so
# reaching 75% of a 12.8 GB trace means decompressing 9.6 GB. Nine such files on
# a machine already running 18 simulations took over 40 minutes. FAST=1 samples
# shallow points instead, decompressing ~0.6 GB per file. The tracer bug
# produced 0.0% across the ENTIRE file, so a shallow sample still detects it;
# what is lost is the guard against a trace that degrades late.
FAST = os.environ.get('FAST', '0') == '1'
FRACS = (0.02, 0.05) if FAST else (0.50, 0.75)
assert len(struct.unpack(FMT, b'\0' * SZ)) == N_FIELDS

root = sys.argv[1]


def _records(path):
    """Instruction records in a trace, without decompressing it."""
    if path.endswith('.xz'):
        # The xz stream index records the uncompressed size; reading it is
        # instant, where decompressing these is ~10 GB of work per file.
        try:
            out = subprocess.run(['xz', '--robot', '-l', path],
                                 capture_output=True, text=True, timeout=60).stdout
            for line in out.splitlines():
                f = line.split('\t')
                if f and f[0] == 'totals':
                    return int(f[4]) // SZ
        except Exception:  # noqa: BLE001
            return 0
        return 0
    return os.path.getsize(path) // SZ


def sample_plain(path, n_rec, fracs):
    """Seek to each fraction and sample. Cheap: no decompression."""
    out = {}
    with open(path, 'rb') as fh:
        for frac in fracs:
            fh.seek(int(n_rec * frac) * SZ)
            tot = mem = 0
            for _ in range(SAMPLE_N):
                r = fh.read(SZ)
                if len(r) < SZ:
                    break
                tot += 1
                if any(struct.unpack(FMT, r)[MEM_LO:MEM_HI]):
                    mem += 1
            out[frac] = (100.0 * mem / tot) if tot else 0.0
    return out


def sample_xz(path, n_rec, fracs):
    """Stream once through `xz -dc`, taking a sample at each fraction.

    A compressed stream cannot be seeked, so the choice is decompress-per-sample
    or one pass that collects every sample on the way through. One pass is taken
    here: two samples of a 12.8 GB trace would otherwise decompress ~16 GB
    instead of ~10 GB. `xz -dc -T0` is used rather than Python's lzma module
    because it is C and threaded, several times faster on this data.
    """
    targets = sorted(int(n_rec * f) for f in fracs)
    by_off = {int(n_rec * f): f for f in fracs}
    out = {}
    proc = subprocess.Popen(['xz', '-dc', '-T0', path],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        idx = 0          # record index reached
        ti = 0           # next target
        cur = None       # fraction currently being sampled
        tot = mem = 0
        carry = b''
        while ti < len(targets) or cur is not None:
            chunk = proc.stdout.read(1 << 20)
            if not chunk:
                break
            buf = carry + chunk
            whole = len(buf) // SZ
            for i in range(whole):
                if cur is None and ti < len(targets) and idx >= targets[ti]:
                    cur = by_off[targets[ti]]
                    tot = mem = 0
                if cur is not None:
                    if any(struct.unpack(FMT, buf[i * SZ:(i + 1) * SZ])[MEM_LO:MEM_HI]):
                        mem += 1
                    tot += 1
                    if tot >= SAMPLE_N:
                        out[cur] = 100.0 * mem / tot
                        cur = None
                        ti += 1
                idx += 1
            carry = buf[whole * SZ:]
        if cur is not None and tot:
            out[cur] = 100.0 * mem / tot
    finally:
        proc.stdout.close()
        proc.terminate()
        proc.wait(timeout=10)
    return {f: out.get(f, 0.0) for f in fracs}


def sample(path, n_rec, fracs):
    try:
        return (sample_xz if path.endswith('.xz') else sample_plain)(path, n_rec, fracs), None
    except Exception as e:  # noqa: BLE001
        return None, str(e)


# Compressed sets are included. They were not, and once barnes_4t and
# canneal_4t were compressed to reclaim 107 GB they silently dropped out of the
# audit -- it reported "44 healthy" for what was really 44 of 53 trace files,
# with nine unchecked and nothing saying so.
paths = []
for pat in ("*.champsimtrace", "*/*.champsimtrace",
            "*.champsimtrace.xz", "*/*.champsimtrace.xz"):
    paths.extend(glob.glob(os.path.join(root, pat)))
paths = sorted(set(paths))

if not paths:
    print(f"no traces under {root}")
    raise SystemExit(0)

lo_lbl, hi_lbl = (f"{int(FRACS[0]*100)}%", f"{int(FRACS[1]*100)}%")
if FAST:
    print("FAST mode: shallow sample points, ~0.6 GB decompressed per xz trace.")
    print("Detects the all-zero tracer bug; does NOT guard against late degradation.\n")
print(f"{'trace':<46}{'records':>12}{lo_lbl:>8}{hi_lbl:>8}  verdict")
print("-" * 88)

broken, healthy = [], []
for pi, p in enumerate(paths, 1):
    rel = os.path.relpath(p, root)
    # stderr so it reaches the terminal even though stdout is redirected to the
    # report file; xz traces take minutes each and silence reads as a hang.
    print(f"[{pi}/{len(paths)}] {rel}", file=sys.stderr, flush=True)
    n = _records(p)
    if n == 0:
        print(f"{rel:<46}{n:>12}  EMPTY OR UNREADABLE")
        broken.append(rel)
        continue
    res, err = sample(p, n, FRACS)
    if err:
        print(f"{rel:<46}{n:>12}  unreadable: {err}")
        broken.append(rel)
        continue
    mid, hi = res[FRACS[0]], res[FRACS[1]]
    is_broken = mid < 0.5 and hi < 0.5
    (broken if is_broken else healthy).append(rel)
    verdict = "BROKEN - no data accesses" if is_broken else "ok"
    tag = " (xz)" if p.endswith(".xz") else ""
    print(f"{rel + tag:<46}{n:>12}{mid:>7.1f}%{hi:>7.1f}%  {verdict}", flush=True)

print()
print(f"healthy: {len(healthy)}")
print(f"BROKEN:  {len(broken)}")
for b in broken:
    print(f"    {b}")
PYEOF

# AUDIT_ROOT narrows the audit to one trace set, e.g. a newly generated one.
# Without it every set is audited, and the xz-compressed ones take hours.
ROOT="${AUDIT_ROOT:-$R/simulator/traces}"
[ -d "$ROOT" ] || { echo "ERROR: no directory $ROOT" >&2; exit 1; }
echo "auditing traces under $ROOT ..."
echo
# stdout to the report file, stderr (progress) straight to the terminal, so a
# long run is visibly working rather than apparently hung.
echo "   xz traces stream through decompression and take minutes each."
echo "   FAST=1 samples shallow points instead (~15x quicker)."
echo
python3 -u "$PY" "$ROOT" > "$OUT"
echo
cat "$OUT"
rm -f "$PY"

echo
echo "Written to $OUT"
