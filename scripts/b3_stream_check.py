#!/usr/bin/env python3
"""Did gem5 and the traces run the same instruction stream?

A B3 comparison divides a ChampSim rate by a gem5 rate. That means something
only if the two simulators ran the same program. This compares what each one
executed, per 1,000 instructions, in the same window: instructions with a
load, with a store, and read-modify-write instructions.

    b3_stream_check.py extract GEM5_ROOT > bench/policy_sanity/gem5_mix_vN.txt
    b3_stream_check.py window NAME MIX [FROM TO] >> a TRACE_MIX file
    b3_stream_check.py check TRACE_MIX GEM5_MIX

extract  reads every stats.txt under GEM5_ROOT (pulled by pull_results.sh) and
         prints one row per run: the committed instructions and the Ruby
         Sequencer's request counts.
window   one TRACE_MIX row, named NAME, for records FROM..TO (default 50 M to
         150 M) of a trace, from trace_mix.c's running counts (a .mix file,
         written beside each synchronised-replay trace by sync_server.sh):
         the counts at TO minus the counts at FROM. Added 2026-11-01 for
         step 4's programs (newbench_design_2026-10-19.md).
check    compares, for each workload, the trace counts with gem5's counts
         between its 50 M and 150 M stops. Exit 1 if a workload differs.

TRACE_MIX holds count_rmw.py's output for records 50 M..150 M of each thread
(verify_b3.sh, section 4):   <name> records N loads L stores S rmw R ...

How gem5's counters map (src/mem/ruby/system/Sequencer.cc, makeRequest):
    an instruction with a load    LD + RMW_Read + Locked_RMW_Read
    an instruction with a store   ST + Locked_RMW_Write
    a read-modify-write           RMW_Read + Locked_RMW_Read
An unlocked RMW's load is RMW_Read and its store an ordinary ST; a locked
RMW is Locked_RMW_Read then Locked_RMW_Write. The gem5 runs use
TimingSimpleCPU, which sends every access to Ruby, so these count executed
instructions. canneal agrees to 0.1% on all three, which checks the mapping.
"""
import os
import re
import sys

TYPES = ('LD', 'ST', 'RMW_Read', 'Locked_RMW_Read', 'Locked_RMW_Write', 'IFETCH')
TOL = 0.05          # a rate may differ by this fraction ...
ABS_RMW = 0.05      # ... or, for RMWs, by this many per 1,000 instructions

# label, prefix of its trace-count names, gem5 run stopped at 50 M, at 150 M,
# threads, and (where the trace's locked RMWs per 1,000 instructions were
# counted) that number, which gem5's must be within 10% of.
# barnes_4t is listed twice: the traces are of a 256-body-leaf build
# (b3_barnes_stream_2026-10-12.md), so they are checked against gem5's run of
# that program -- and against the standard run, which they must NOT match.
WORKLOADS = (
    ('ocean', 'ocean_4t_', 'l2_2MB_mi50M/ocean_4c', 'l2_2MB_mi150M/ocean_4c', 4, None),
    ('canneal', 'canneal_4t_', 'canneal/l2_2MB_mi50M/canneal_4c', 'canneal/l2_2MB_mi150M/canneal_4c', 4, None),
    ('barnes256', 'barnes_4t', 'barnes_leaf256/l2_2MB_mi50M/barnes_4c', 'barnes_leaf256/l2_2MB_mi150M/barnes_4c', 4, 10.49),
    ('barnes-std', 'barnes_4t', 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi150M/barnes_4c', 4, None),
    # the standard barnes, traced 2026-10-13 (b3_barnes_std_design_2026-10-13.md).
    # None = from the program's start; thread 0's row there holds its serial start.
    ('bstd-start', 'barnes_std_4t_start_', None, 'barnes/l2_2MB_mi50M/barnes_4c', 4, None),
    ('bstd-force', 'barnes_std_4t_force_', 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi100M/barnes_4c', 4, None),
    ('bstd-window', 'barnes_std_4t_window_', 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi150M/barnes_4c', 4, None),
    # held-out programs (b3_heldout_design_2026-10-14.md): gem5 stopped when a
    # worker reaches 50 M and 150 M; the traces' window is records 50-150 M of
    # each aligned trace
    ('radix', 'radix_4t_window_', 'heldout/radix/l2_2MB_mi830M/radix_4c', 'heldout/radix/l2_2MB_mi930M/radix_4c', 4, None),   # traces skip 780 M
    ('waternsq', 'waternsq_4t_window_', 'heldout/waternsq/l2_2MB_mi50M/waternsq_4c', 'heldout/waternsq/l2_2MB_mi150M/waternsq_4c', 4, None),
    ('fmm', 'fmm_4t_window_', 'heldout/fmm/l2_2MB_mi50M/fmm_4c', 'heldout/fmm/l2_2MB_mi150M/fmm_4c', 4, None),
)
# The held-out design's rule (b3_heldout_design_2026-10-14.md): read-modify-
# writes within 5% gate; loads and stores within 5% are expected, a miss up to
# 8% is reported and scored with the miss stated (gem5 counts memory micro-ops,
# 3-6% more on floating-point code), beyond 8% nothing is scored.
HELD_OUT = {'radix', 'waternsq', 'fmm'}
# canneal at 8 cores (b3_canneal8_design_2026-10-14.md): threads 1-8 of
# canneal_8t against gem5's 8 workers, the same 5% rule as canneal at 4
WORKLOADS = WORKLOADS + (('canneal8', 'canneal_8t_', 'canneal8/l2_2MB_mi50M/canneal_8c', 'canneal8/l2_2MB_mi150M/canneal_8c', 8, None),)
# step 4's new programs (newbench_design_2026-10-19.md, "Same stream": "as for
# the held-out programs"): records 50-150 M of each aligned trace against gem5
# stopped when a worker reaches 50 M and 150 M; the held-out rule. radiosity
# and lunc are listed so the check names them while they have no traces.
NEWBENCH = ('fft', 'lu', 'raytrace', 'streamcluster', 'volrend', 'radiosity', 'lunc')
WORKLOADS = WORKLOADS + tuple((p, f'{p}_4t_window_', f'newbench/{p}/l2_2MB_mi50M/{p}_4c', f'newbench/{p}/l2_2MB_mi150M/{p}_4c', 4, None)
                              for p in NEWBENCH)
HELD_OUT = HELD_OUT | set(NEWBENCH)
HELD_OUT_SOFT = 0.08
KNOWN_DIFFERENT = {'barnes-std': 'expected: the barnes_4t traces are of a 256-body-leaf build, this gem5 run the standard one'}


def extract(root):
    print('# run insts ' + ' '.join(TYPES))
    for d, _, files in sorted(os.walk(root)):
        if 'stats.txt' not in files or '.prev_' in os.path.relpath(d, root):
            continue   # .prev_: a stopped run kept as <dir>.prev_<time> (heldout2_design Note 3), never read
        c = dict.fromkeys(TYPES, 0)
        insts = 0
        for ln in open(os.path.join(d, 'stats.txt')):
            m = re.match(r'system\.ruby\.RequestType\.([A-Za-z_]+)\.latency_hist_seqr::samples\s+(\d+)', ln)
            if m and m.group(1) in c:
                c[m.group(1)] = int(m.group(2))
            m = re.match(r'system\.cpu\d+\.commitStats0\.numInsts\s+(\d+)', ln)
            if m:
                insts += int(m.group(1))
        print(os.path.relpath(d, root), insts, ' '.join(str(c[t]) for t in TYPES))


def read_gem5(path):
    rows = {}
    for ln in open(path):
        p = ln.split()
        if not p or p[0].startswith('#'):
            continue
        rows[p[0]] = dict(zip(('insts',) + TYPES, map(int, p[1:])))
    return rows


def read_trace(path):
    rows = {}
    for ln in open(path):
        m = re.match(r'\s*(\S+)\s+records (\d+) loads (\d+) stores (\d+) rmw (\d+)', ln)
        if m:
            rows[m.group(1)] = tuple(int(x) for x in m.groups()[1:])
    return rows


def check(trace_path, gem5_path):
    trace, gem5 = read_trace(trace_path), read_gem5(gem5_path)
    bad = 0
    print('per 1,000 instructions, window 50-150 M          trace      gem5   gem5/trace')
    for wl, prefix, a, b, nthreads, locked in WORKLOADS:
        t = [v for k, v in sorted(trace.items()) if k.startswith(prefix)]
        if not t or (a is not None and a not in gem5) or b not in gem5:
            print(f'  {wl:11s} -> NOT CHECKED (no trace counts, or a gem5 run is missing)')
            bad += 1
            continue
        n = sum(x[0] for x in t) / 1000
        tr = [sum(x[i] for x in t) / n for i in (1, 2, 3)]
        w = {k: gem5[b][k] - (gem5[a][k] if a is not None else 0) for k in gem5[b]}
        ki = w['insts'] / 1000
        g = [(w['LD'] + w['RMW_Read'] + w['Locked_RMW_Read']) / ki, (w['ST'] + w['Locked_RMW_Write']) / ki,
             (w['RMW_Read'] + w['Locked_RMW_Read']) / ki]
        differs = []
        soft = []
        for name, x, y in zip(('with a load', 'with a store', 'read-modify-write'), tr, g):
            off = abs(y - x) > TOL * x and not (name == 'read-modify-write' and abs(y - x) <= ABS_RMW)
            note = '   <-- differs' if off else ''
            if off and wl in HELD_OUT and name != 'read-modify-write' and abs(y - x) <= HELD_OUT_SOFT * x:
                soft.append(name)
                off = False
                note = '   <-- differs by under 8%: scored, with the miss stated'
            if off:
                differs.append(name)
            print(f'  {wl:11s} {name:20s}           {x:9.3f} {y:9.3f}   {y / x if x else float("nan"):8.3f}{note}')
        gl = w['Locked_RMW_Read'] / ki
        if locked is None:
            print(f'  {wl:11s} of which locked (gem5 only)              {gl:9.3f}')
        else:
            off = abs(gl - locked) > 0.10 * locked
            if off:
                differs.append('locked read-modify-write')
            print(f'  {wl:11s} {"locked RMW":20s}           {locked:9.3f} {gl:9.3f}   {gl / locked:8.3f}{"   <-- differs (10% allowed)" if off else ""}')
        part = '' if len(t) >= nthreads else f' ({len(t)} of {nthreads} threads counted on the trace side)'
        if differs and wl in KNOWN_DIFFERENT:
            verdict = 'not the same stream (' + KNOWN_DIFFERENT[wl] + ')'
        elif differs:
            verdict = 'NOT THE SAME STREAM: ' + ', '.join(differs) + part
            bad += 1
        elif wl in KNOWN_DIFFERENT:
            verdict = 'UNEXPECTED: these match, and they should not'
            bad += 1
        elif part:
            verdict = 'agrees, but NOT ESTABLISHED' + part
            bad += 1
        elif soft:
            verdict = 'same stream by the held-out rule; ' + ', '.join(soft) + ' 5-8% apart, stated with the score'
        else:
            verdict = 'same stream (every rate within 5%)'
        print(f'  {wl:11s} -> {verdict}')
    return 1 if bad else 0


def window(name, mix, first=50_000_000, last=150_000_000):
    # trace_mix.c: "C idx loads stores rmw branches ip hash", cumulative over
    # records [0, idx). Sync records count as records, never as accesses.
    at = {}
    with open(mix) as f:
        for ln in f:
            p = ln.split()
            if p and p[0] == 'C':
                at[int(p[1])] = tuple(int(x) for x in p[2:5])
    if first not in at or last not in at:
        print(f'{mix}: no running count at record {first if first not in at else last} (trace too short, or another step)', file=sys.stderr)
        return 1
    n = last - first
    ld, st, rmw = (at[last][i] - at[first][i] for i in range(3))
    print(f'{name} records {n} loads {ld} stores {st} rmw {rmw} rmw_per_ki {1000 * rmw / n:.4f} (trace_mix.c)')
    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'extract':
        extract(sys.argv[2])
        return 0
    if len(sys.argv) in (4, 6) and sys.argv[1] == 'window':
        return window(sys.argv[2], sys.argv[3], *(int(x) for x in sys.argv[4:6]))
    if len(sys.argv) == 4 and sys.argv[1] == 'check':
        return check(sys.argv[2], sys.argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
