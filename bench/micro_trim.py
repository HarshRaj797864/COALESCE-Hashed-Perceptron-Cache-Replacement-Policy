#!/usr/bin/env python3
"""Find coherence_micro's markers in its Pin traces and cut the traces there.

    micro_trim.py RUN_STDOUT TRACE_PREFIX OUTDIR

RUN_STDOUT    the program's own output under Pin (it prints the marker addresses)
TRACE_PREFIX  the tracer's -o prefix: TRACE_PREFIX{0..3}.champsimtrace
OUTDIR        gets t{0..3}.champsimtrace, each starting at its thread's store
              to start_mark (so the four begin together, as the threads leave
              the start barrier together), and prints the instructions to
              simulate: the latest end_mark position, plus a little.

Pin numbers threads in order of creation: trace 0 is the main thread. The
markers say which thread a trace is anyway: each thread stores to its own
line of start_mark, and the line tells the thread.
"""
import re
import sys

import numpy as np

REC = 64
SYNC_MAGIC = 0x53594E4353594E43
DT = np.dtype([('ip', '<u8'), ('br', 'u1'), ('tk', 'u1'), ('dr', 'u1', 2), ('sr', 'u1', 4), ('dm', '<u8', 2), ('sm', '<u8', 4)])
assert DT.itemsize == REC


def first_store_in(path, lo, hi):
    """(record index, line index) of the first record storing into [lo, hi), or (None, None); and the record count."""
    a = np.memmap(path, dtype=DT, mode='r')
    found = (None, None)
    step = 1 << 22
    for s in range(0, len(a), step):
        dm = a['dm'][s:s + step]
        hit = ((dm >= lo) & (dm < hi)).any(axis=1)
        if hit.any():
            i = int(np.argmax(hit))
            addr = int(dm[i][(dm[i] >= lo) & (dm[i] < hi)][0])
            found = (s + i, (addr - lo) // 64)
            break
    return found, len(a)


def main():
    out_txt, prefix, outdir = sys.argv[1:4]
    m = re.search(r'start_mark (0x[0-9a-f]+) end_mark (0x[0-9a-f]+)', open(out_txt).read())
    if not m:
        sys.exit('no marker addresses in ' + out_txt)
    sm, em = int(m.group(1), 16), int(m.group(2), 16)
    starts, ends, lens = {}, {}, {}
    for k in range(4):
        path = f'{prefix}{k}.champsimtrace'
        (si, st), n = first_store_in(path, sm, sm + 4 * 64)
        if si is None:
            sys.exit(f'{path}: no store to start_mark')
        a = np.memmap(path, dtype=DT, mode='r')
        (ei, et), _ = first_store_in(path, em, em + 4 * 64)
        if ei is None or et != st:
            sys.exit(f'{path}: end_mark missing or of another thread ({et} vs {st})')
        starts[st], ends[st], lens[st] = si, ei, n
        with open(f'{outdir}/t{st}.champsimtrace', 'wb') as f:
            # Synchronised replay: a trace cut here starts with a fresh base
            # record -- this thread's first release from here on; every
            # earlier release of it was cut away and counts as done.
            sync = a['dm'][:, 1] == SYNC_MAGIC
            if sync.any():
                tid = k
                rel = np.nonzero(sync[si:] & (a['sm'][si:, 1] == 1))[0]
                base = int(a['dm'][si + rel[0], 0]) if len(rel) else (((1 << 40) << 8) | tid)
                rec = np.zeros(1, dtype=DT)
                rec['ip'] = a['ip'][si]
                rec['dm'][0, 0] = base
                rec['dm'][0, 1] = SYNC_MAGIC
                rec['sm'][0, 1] = 3
                rec.tofile(f)
            np.asarray(a[si:]).tofile(f)
        print(f'thread {st}: trace {path}, start_mark at record {si:,}, end_mark at {ei:,} '
              f'({ei - si:,} after the start), {n - si:,} records kept')
    if sorted(starts) != [0, 1, 2, 3]:
        sys.exit(f'threads found: {sorted(starts)}')
    span = max(ends[t] - starts[t] for t in starts)
    tail = min(lens[t] - starts[t] for t in starts) - span
    print(f'SIMULATE {span + 1000}  (longest start-to-end {span:,}; shortest tail beyond it {tail:,} records)')


if __name__ == '__main__':
    main()
