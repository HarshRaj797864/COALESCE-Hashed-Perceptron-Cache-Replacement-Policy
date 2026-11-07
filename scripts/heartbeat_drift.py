#!/usr/bin/env python3
"""How far apart do a run's cores drift? (drift_finding_2026-10-18.md; P1 of
sync_replay_design_2026-10-18.md)

    scripts/heartbeat_drift.py [--bins] RUN_LOG [RUN_LOG ...]

From the heartbeat lines ("Heartbeat CPU n instructions: I cycles: C", one
every 10 M instructions per core), each core's instruction count at the same
cycle, at 200 points between the last core's first heartbeat and the first
core's last; prints the spread between the most and least advanced core
(median and max, in millions of instructions). With --bins, also per 10 M of
the cores' mean position, to set beside sync_native_drift.py's bins.
"""
import collections
import re
import sys


def interp(x, xs, ys):
    if x <= xs[0]:
        return ys[0]
    for i in range(1, len(xs)):
        if x <= xs[i]:
            return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - xs[i - 1]) / (xs[i] - xs[i - 1])
    return ys[-1]


def samples(path):
    """(mean position, spread in M) at 200 points, or None."""
    hb = collections.defaultdict(list)
    for line in open(path, errors='replace'):
        m = re.match(r'Heartbeat CPU (\d+) instructions: (\d+) cycles: (\d+)', line)
        if m:
            hb[int(m.group(1))].append((int(m.group(3)), int(m.group(2))))
    if len(hb) < 2 or min(len(v) for v in hb.values()) < 2:
        return None
    lo = max(v[0][0] for v in hb.values())
    hi = min(v[-1][0] for v in hb.values())
    if hi <= lo:
        return None
    out = []
    for k in range(200):
        c = lo + (hi - lo) * k / 199
        pos = [interp(c, [x[0] for x in v], [x[1] for x in v]) for v in hb.values()]
        out.append((sum(pos) / len(pos), (max(pos) - min(pos)) / 1e6))
    return out


def drift(path):
    s = samples(path)
    if s is None:
        return None
    spreads = sorted(x[1] for x in s)
    return spreads[len(spreads) // 2], spreads[-1]


def main():
    args = sys.argv[1:]
    bins = '--bins' in args
    for p in (a for a in args if a != '--bins'):
        d = drift(p)
        print(f'{p}: ' + ('too few heartbeats' if d is None else f'cores apart: median {d[0]:.2f} M, max {d[1]:.2f} M instructions'))
        if bins and d is not None:
            b = collections.defaultdict(list)
            for m, sp in samples(p):
                b[int(m // 10_000_000)].append(sp)
            for k in sorted(b):
                v = sorted(b[k])
                print(f'      {k * 10:4d}-{k * 10 + 10:<4d} M   median {v[len(v) // 2]:6.2f}   max {v[-1]:6.2f}   ({len(v)} samples)')


if __name__ == '__main__':
    main()
