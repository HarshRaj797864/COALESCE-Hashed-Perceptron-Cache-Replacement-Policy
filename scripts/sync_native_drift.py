#!/usr/bin/env python3
"""How far apart were the threads in the TRACED run itself? Read from the sync
records (synchronised replay, bench/policy_sanity/sync_replay_design_2026-10-18.md).

    sync_native_drift.py OUT_TSV TRACE [TRACE ...]     (one trace per thread, in core order)

A release record carries a number from one counter shared by every thread of
the traced run (champsim_tracer.cpp, sync_seq), so it is a clock of that run.
Each thread's releases give (clock, position) pairs; at a common clock value
the threads' positions differ by how far apart they were in the traced run.
The replay enforces that run's order, so if the replay's drift is this drift,
the replay is faithful to the traced run, and the drift came from the tracing.

Position counts records as ChampSim counts instructions: the leading base
record is not counted; every other record, a sync record included, is.

Two measures, per 10 M-position bin (by the threads' mean position):
  * interpolated: each thread's position at a common clock value, linear
    between its releases. Sound only where releases are dense (lock-heavy
    programs). In a barrier-only program the clock barely ticks between
    barriers, and interpolating across a whole phase INVENTS spread (canneal:
    7-8 M where the threads reach each barrier within 1 M; 2026-10-19).
  * at barriers: a barrier departure is a run of N-1 acquire records (N =
    threads) naming the other threads' arrivals of its generation
    (champsim_tracer.cpp, SC_BARRIER); with the thread's own arrival, the
    last release before the run, they are one generation's N arrivals. The
    spread of their positions: exact, no interpolation.
Also the acquires by what they wait for. Writes OUT_TSV: each
thread's releases, thinned to one per 100,000 positions (core, position, clock).
Plain Python (the server has no numpy); read-only on the traces.
"""
import multiprocessing
import struct
import subprocess
import sys

MAGIC = struct.pack('<Q', 0x53594E4353594E43)
REC = 64
CHUNK = REC << 20                # 64 MB, whole records
Q = struct.Struct('<Q')
KEEP_EVERY = 100_000
BIN = 10_000_000


def read_exact(f, n):
    parts, got = [], 0
    while got < n:
        b = f.read(n - got)
        if not b:
            break
        parts.append(b)
        got += len(b)
    return b''.join(parts)


def scan(job):
    core, path = job
    if path.endswith('.xz'):
        p = subprocess.Popen(['nice', '-n', '19', 'xz', '-dc', path], stdout=subprocess.PIPE, bufsize=1 << 20)
        f = p.stdout
    else:
        p, f = None, open(path, 'rb')
    rec0 = 0
    based = False
    rel = []                     # (position, clock), every release
    acq_own = acq_other = acq_none = 0
    tid = None
    runs = []                    # (own last release clock, [clocks of the releases waited for]): runs of >= 2 acquires
    run, run_end, last_rel = [], -1, None
    while True:
        b = read_exact(f, CHUNK)
        if not b:
            break
        i = b.find(MAGIC)
        while i != -1:
            if i % REC == 24:
                r = i - 24
                idx = rec0 + r // REC
                dm0 = Q.unpack_from(b, r + 16)[0]
                sm0 = Q.unpack_from(b, r + 32)[0]
                kind = Q.unpack_from(b, r + 40)[0]
                if kind != 2 or idx != run_end + 1:
                    if len(run) >= 2:
                        runs.append((last_rel, run))
                    run = []
                if kind == 3 and idx == 0:
                    based = True
                    tid = dm0 & 0xff
                elif kind == 1:
                    rel.append((idx - (1 if based else 0), dm0 >> 8))
                    tid = dm0 & 0xff
                    last_rel = dm0 >> 8
                elif kind == 2:
                    if sm0 == 0:
                        acq_none += 1
                    elif tid is not None and (sm0 & 0xff) == tid:
                        acq_own += 1
                    else:
                        acq_other += 1
                    run.append(sm0)
                    run_end = idx
            i = b.find(MAGIC, i + 1)
        rec0 += len(b) // REC
    if len(run) >= 2:
        runs.append((last_rel, run))
    if p:
        p.wait()
    return core, path, rec0 - (1 if based else 0), rel, (acq_own, acq_other, acq_none), runs


def pos_at(rel, clock):
    """Position of a thread at a clock value: linear between its releases."""
    lo, hi = 0, len(rel) - 1
    if clock <= rel[0][1]:
        return rel[0][0]
    if clock >= rel[hi][1]:
        return rel[hi][0]
    while hi - lo > 1:
        m = (lo + hi) // 2
        if rel[m][1] <= clock:
            lo = m
        else:
            hi = m
    (p0, c0), (p1, c1) = rel[lo], rel[hi]
    return p0 + (p1 - p0) * (clock - c0) / (c1 - c0) if c1 != c0 else p0


def barrier_gens(res):
    """{bin: [spread]} over barrier generations: a run of exactly N-1 acquires
    naming N-1 other threads' releases, plus the thread's own last release."""
    n = len(res)
    where = {}                                   # release clock -> position
    for r in res:
        for pos, clk in r[3]:
            where[clk] = pos
    out, seen = {}, set()
    for core, path, _, rel, _, runs in res:
        for own, waits in runs:
            if own is None or len(waits) != n - 1 or len({w & 0xff for w in waits}) != n - 1:
                continue
            clks = tuple(sorted([own] + [w >> 8 for w in waits]))
            if clks in seen or any(c not in where for c in clks):
                continue
            seen.add(clks)                       # every thread's departure names the same generation
            ps = [where[c] for c in clks]
            out.setdefault(int(sum(ps) / n // BIN), []).append((max(ps) - min(ps)) / 1e6)
    return out


def main():
    out, traces = sys.argv[1], sys.argv[2:]
    with multiprocessing.Pool(min(len(traces), 8)) as pool:
        res = sorted(pool.map(scan, list(enumerate(traces))))
    with open(out, 'w') as fo:
        fo.write('core\tposition\tclock\n')
        for core, path, n, rel, acq, _ in res:
            last = -KEEP_EVERY
            for pos, clk in rel:
                if pos >= last + KEEP_EVERY:
                    fo.write(f'{core}\t{pos}\t{clk}\n')
                    last = pos
    for core, path, n, rel, acq, _ in res:
        print(f'   core {core}: {path.rsplit("/", 1)[-1]}: {n:,} positions, {len(rel):,} releases; '
              f'acquires waiting on its own release {acq[0]:,}, on another thread\'s {acq[1]:,}, on none {acq[2]:,}')
    rels = [r[3] for r in res]
    if any(len(r) < 2 for r in rels):
        print('   too few releases in some thread to compare positions')
        return
    clocks = sorted({c for r in rels for _, c in r})
    lo = max(r[0][1] for r in rels)
    hi = min(r[-1][1] for r in rels)
    clocks = [c for c in clocks if lo <= c <= hi]
    if len(clocks) > 200_000:            # thin evenly
        step = len(clocks) / 200_000
        clocks = [clocks[int(k * step)] for k in range(200_000)]
    bins = {}
    for c in clocks:
        ps = [pos_at(r, c) for r in rels]
        bins.setdefault(int(sum(ps) / len(ps) // BIN), []).append((max(ps) - min(ps)) / 1e6)
    sp = barrier_gens(res)
    print('   traced run: threads apart (M positions), by mean position;  interpolated  |  at barriers')
    for k in sorted(set(bins) | set(sp)):
        a = sorted(bins.get(k, []))
        b = sorted(sp.get(k, []))
        fa = f'median {a[len(a) // 2]:6.2f}   max {a[-1]:6.2f}   ({len(a):6d})' if a else ' ' * 36
        fb = f'median {b[len(b) // 2]:6.2f}   max {b[-1]:6.2f}   ({len(b):6d})' if b else 'none'
        print(f'      {k * 10:4d}-{k * 10 + 10:<4d} M   {fa}  |  {fb}')


if __name__ == '__main__':
    main()
