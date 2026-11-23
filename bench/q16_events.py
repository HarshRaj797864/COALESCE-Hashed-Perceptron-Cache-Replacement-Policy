#!/usr/bin/env python3
"""Q16's diagnosis (q16_results_2026-11-13.md): the private copies invalidated
on coherence_micro's X lines, by cache and core, and the event that caused each.

    q16_events.py EVENTS RUN_OUT [--selftest]

EVENTS   a run's per-request event log (COHERENCE_EVENT_LOG; bench/micro_champsim.sh KEEP_EVENTS=1)
RUN_OUT  the program's output under Pin (it prints X's address)

The X lines are as the harness counts them: virtual lines X .. X + 63, and the
physical lines the G and U events on them name. An I line (a private copy
invalidated) is written by dir_invalidate_line just before the G or U line of
the request that caused it, so each I line is charged to the next G or U line.
"""
import re
import sys
from collections import Counter


def analyse(ev_lines, x_addr):
    X = x_addr >> 6
    rows = [l.split() for l in ev_lines]
    phys = set()
    for p in rows:
        if len(p) >= 12 and p[0] in ('G', 'U') and p[9] != 'TRANSLATION' and X <= int(p[7], 16) < X + 64:
            phys.add(p[8])
    by_cache, by_core_cache, causes = Counter(), Counter(), Counter()
    pending = []
    for p in rows:
        if not p:
            continue
        if p[0] == 'I' and len(p) > 8:
            if p[8] in phys:
                pending.append(p)
        elif p[0] in ('G', 'U') and len(p) >= 12:
            for q in pending:
                kind = q[1].split('_', 1)[1] if '_' in q[1] else q[1]
                by_cache[kind] += 1
                by_core_cache[(int(q[4]), kind)] += 1
                causes[(p[0], p[1], p[4], X <= int(p[7], 16) < X + 64)] += 1
            pending = []
    return by_cache, by_core_cache, causes, len(pending)


def report(by_cache, by_core_cache, causes, orphans):
    print('I lines on the X lines, by cache kind:', dict(by_cache), ' total', sum(by_cache.values()))
    cores = sorted({c for c, _ in by_core_cache})
    print('by core (L1D, L2C):', ' '.join(f'{c}:{by_core_cache[(c, "L1D")]},{by_core_cache[(c, "L2C")]}' for c in cores))
    print('caused by (kind, cache, cpu, on an X line):', dict(causes))
    print('I lines with no G or U line after them:', orphans)


def selftest():
    X = 0x1000 << 6
    ev = [
        'L cpu0_L1D 10 0 0 1 400 1000 9000 LOAD 0 0 0',
        'I cpu0_L1D 20 0 0 0 0 0 9000 0 0 0',
        'I cpu0_L2C 20 0 0 0 0 0 9000 0 0 0',
        'I cpu1_L2C 20 0 1 0 0 0 9000 0 0 0',
        'U cpu15_L1D 21 0 15 7 400 1000 9000 RFO 3 3 3',
        'I cpu2_L1D 30 0 2 0 0 0 7777 0 0 0',          # not an X line
        'G cpu3_LLC 31 0 3 8 400 5000 7777 RFO 4 4 4',  # not on X
    ]
    a = analyse(ev, X)
    ok = (dict(a[0]) == {'L1D': 1, 'L2C': 2} and a[1][(0, 'L1D')] == 1 and a[1][(1, 'L2C')] == 1
          and dict(a[2]) == {('U', 'cpu15_L1D', '15', True): 3} and a[3] == 0)
    print('SELF-TEST ' + ('PASSES' if ok else 'FAILS'), a)
    return 0 if ok else 1


def main():
    if '--selftest' in sys.argv:
        return selftest()
    ev_path, out_path = sys.argv[1:3]
    m = re.search(r'X (0x[0-9a-f]+)', open(out_path).read())
    if not m:
        sys.exit('no X address in ' + out_path)
    with open(ev_path) as f:
        report(*analyse(f, int(m.group(1), 16)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
