#!/usr/bin/env python3
"""Summarise a coherence event log (COHERENCE_EVENT_LOG=<file>, 9eb1067).

    coherence_events.py LOG [--range LO HI] [--top N]

One line per event, written by cache.cc:
    kind cache cycle warmup cpu instr_id ip v_line line type protocol_others presence_others
    L, G, W   a load, RFO or writeback accepted at the LLC
    U         an upgrade: a store or RFO that hit a private copy while another core was listed
    S         a fill dropped as stale
    I         a private copy invalidated (cache cycle warmup cpu 0 0 0 line dirty 0 0)

A HAND-OVER here is a G or a U that found another core in the protocol view:
the events R_b and U are built from. Only the measured phase is counted.

--range LO HI   also report the share of hand-overs on lines whose virtual
                address is in [LO, HI) (hex), e.g. a lock array
--top N         how many lines to list (default 12)
"""
import collections
import sys


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith('-'):
        print(__doc__, file=sys.stderr)
        return 2
    path, lo, hi, top = args[0], None, None, 12
    i = 1
    while i < len(args):
        if args[i] == '--range':
            lo, hi = int(args[i + 1], 16) >> 6, int(args[i + 2], 16) >> 6
            i += 3
        elif args[i] == '--top':
            top = int(args[i + 1])
            i += 2
        else:
            print(__doc__, file=sys.stderr)
            return 2

    kinds = collections.Counter()
    per_instr = collections.Counter()        # (cpu, instr_id, line) -> hand-overs
    per_line = collections.Counter()         # line -> hand-overs
    split = collections.Counter()            # (kind, cache level, request type) -> hand-overs
    vline = {}                               # line -> a virtual line seen for it
    stale = collections.Counter()
    for ln in open(path):
        p = ln.split()
        if len(p) < 12 or p[3] != '0':   # 13 fields since 2026-10-19 (the gem5-rule view)
            continue
        k = p[0]
        kinds[k] += 1
        if k == 'I':
            continue
        line = p[8]
        if p[7] != '0':
            vline.setdefault(line, int(p[7], 16))
        if k == 'S':
            stale[(p[1].split('_')[-1], p[9])] += 1
        elif k in 'GU' and p[10] != '0':
            per_instr[(p[4], p[5], line)] += 1
            per_line[line] += 1
            split[(k, p[1].split('_')[-1], p[9])] += 1

    total = sum(per_line.values())
    print('events in the measured phase: ' + '  '.join(f'{k} {kinds[k]}' for k in 'LGWUSI'))
    print(f'hand-overs: {total}   (G {sum(n for (k, _, _), n in split.items() if k == "G")}, U {sum(n for (k, _, _), n in split.items() if k == "U")})')
    if not total:
        return 0
    h = collections.Counter(per_instr.values())
    print(f'  instructions with a hand-over: {len(per_instr)}   -> {total / len(per_instr):.3f} each;  by count: {dict(sorted(h.items()))}')
    print(f'  lines with a hand-over: {len(per_line)}')
    for key, n in sorted(split.items(), key=lambda kv: -kv[1]):
        print(f'  {n:9d} {100 * n / total:5.1f}%  {key[0]} at {key[1]}, {key[2]}')
    acc = 0
    print(f'the {top} lines with the most hand-overs:')
    for line, n in per_line.most_common(top):
        acc += n
        v = vline.get(line)
        print(f'  {n:9d} {100 * n / total:5.1f}%  cumulative {100 * acc / total:5.1f}%   virtual {(v << 6) if v is not None else 0:#x}')
    if lo is not None:
        inr = sum(n for line, n in per_line.items() if line in vline and lo <= vline[line] < hi)
        nlines = sum(1 for line in per_line if line in vline and lo <= vline[line] < hi)
        print(f'in [{lo << 6:#x}, {hi << 6:#x}): {inr} hand-overs = {100 * inr / total:.1f}%, on {nlines} lines')
    ts = sum(stale.values())
    if ts:
        print(f'stale fills dropped: {ts}   ' + '  '.join(f'{c} {t} {n}' for (c, t), n in sorted(stale.items(), key=lambda kv: -kv[1])[:6]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
