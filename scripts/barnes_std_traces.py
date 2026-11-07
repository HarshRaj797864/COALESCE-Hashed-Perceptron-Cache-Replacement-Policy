#!/usr/bin/env python3
"""Trace helpers for the standard-barnes experiment (barnes_std.sh). Pure
Python: the server has no numpy. Traces are uncompressed .champsimtrace files.

    barnes_std_traces.py anchor T0 T1 T2 T3
        Where does thread 0's parallel work start? Thread 0 is the program's
        main thread: its trace opens with the serial start-up, which the
        other threads do not have. Prints the number of records to drop from
        the front of T0 so that all four traces start at the same point of
        the program.

        The anchor is the first read-modify-write that threads 1, 2 and 3 all
        make on one address, in thread 1's order: in SPLASH-3 that is
        SlaveStart's lock on Global->CountLock, the first thing every worker
        does. A second shared address checks it.

        An optional fifth argument sets the smallest shift accepted (default
        100,000: barnes's serial start is 10.6 M). The held-out programs pass
        0, since radix's serial start is about 0.16 M (2026-10-14).

    barnes_std_traces.py residual T0 T1 T2 T3
        The same measurement on traces already aligned: prints the shift
        still left (RESIDUAL n), which should be within a few hundred records.

    barnes_std_traces.py mix NAME FILE SKIP COUNT
        Instructions with a load, with a store, and read-modify-writes in
        records SKIP..SKIP+COUNT of FILE, in count_rmw.py's output format
        (which b3_stream_check.py reads), seeking instead of reading through.

    barnes_std_traces.py sample FILE
        The share of records that carry a memory operand, from three places
        in the file. A healthy trace reads 30-60%; the 2026-09 tracer bug
        read 0.0% on every thread but 0.
"""
import os
import struct
import sys

REC = 64
ST = struct.Struct('<QBB2B4B2Q4Q')   # ip, is_branch, taken, 2 dest regs, 4 src regs, 2 dest mem, 4 src mem
CHUNK = 1 << 16                      # records per read


def records(path, skip=0, count=None):
    """Yield (index, fields) for records skip..skip+count."""
    with open(path, 'rb') as f:
        f.seek(skip * REC)
        i = skip
        left = count
        while left is None or left > 0:
            want = CHUNK if left is None else min(CHUNK, left)
            b = f.read(want * REC)
            b = b[:len(b) - len(b) % REC]
            if not b:
                return
            for t in ST.iter_unpack(b):
                yield i, t
                i += 1
            if left is not None:
                left -= len(b) // REC


def rmw_addr(t):
    """The address an instruction both reads and writes, or 0."""
    for d in (t[9], t[10]):
        if d and d in t[11:15]:
            return d
    return 0


def first_rmws(path, limit, want=None):
    """address -> index of its first read-modify-write, over the first `limit`
    records; stops early once every address in `want` has been seen."""
    seen = {}
    missing = set(want) if want else None
    for i, t in records(path, 0, limit):
        a = rmw_addr(t)
        if a and a not in seen:
            seen[a] = i
            if missing is not None:
                missing.discard(a)
                if not missing:
                    break
    return seen


def anchor(paths, residual=False, min_offset=100_000):
    """The first read-modify-write address that threads 1-3 share AND thread 0
    touches. Threads 1-3 are searched over their first ANCHOR_WORKER_RECORDS
    records (default 500,000, as for barnes), thread 0 over 60 M.

    2026-10-14, for the held-out programs: thread 0 must touch the anchor.
    fmm's workers first share an address inside the thread-start code, which
    thread 0 never runs; and radix's workers generate keys for millions of
    records before their second shared lock, so the window is a setting.
    barnes's anchor is unchanged: its first shared address (CountLock) is
    one thread 0 touches."""
    t0, others = paths[0], paths[1:]
    limit = int(os.environ.get('ANCHOR_WORKER_RECORDS', 500_000))
    firsts = [first_rmws(p, limit) for p in others]
    common = [a for a in sorted(firsts[0], key=firsts[0].get) if all(a in f for f in firsts[1:])]
    if len(common) < 2:
        sys.exit(f'anchor: threads 1-3 share {len(common)} read-modify-write address(es) in their first {limit:,} records; need 2')
    z = first_rmws(t0, 60_000_000, want=set(common))
    usable = [a for a in common if a in z]
    skipped = len(common) - len(usable)
    if len(usable) < 2:
        sys.exit(f'anchor: of {len(common)} addresses threads 1-3 share, thread 0 touches {len(usable)} in its first 60 M records; need 2')
    a1 = usable[0]
    # The check must be a different point of the program, not the same lock's
    # next field: the first usable address thread 1 reaches 5,000 records on.
    later = [a for a in usable if firsts[0][a] >= firsts[0][a1] + 5000]
    if not later:
        sys.exit('anchor: no second shared address 5,000 records after the anchor to check it with')
    a2 = later[0]
    # ANCHOR_MAX_SPREAD (default 1,000): a trace that skips the start
    # (radix skips 780 M) begins where each worker's own count says, and
    # radix's workers then reach their first barrier 1,234 records apart
    # (rehearsal, 2026-10-14); the held-out pipeline allows 10,000.
    max_spread = int(os.environ.get('ANCHOR_MAX_SPREAD', 1000))
    spread = max(f[a1] for f in firsts) - min(f[a1] for f in firsts)
    if spread > max_spread:
        sys.exit(f'anchor: threads 1-3 reach the anchor {a1:#x} at {[f[a1] for f in firsts]} -- more than {max_spread:,} records apart')
    off = z[a1] - firsts[0][a1]
    drift = (z[a2] - off) - firsts[0][a2]
    if skipped:
        print(f'skipped {skipped} address(es) threads 1-3 share before the anchor and thread 0 does not touch')
    print(f'anchor {a1:#x}: thread 0 at record {z[a1]}, threads 1-3 at {[f[a1] for f in firsts]}')
    print(f'check  {a2:#x}: thread 0 at record {z[a2]} (after the shift {z[a2] - off}), threads 1-3 at {[f[a2] for f in firsts]}')
    if residual:
        print(f'RESIDUAL {off}')
        return
    if off < min_offset or off < 0:
        sys.exit(f'anchor: thread 0 would be shifted by {off} records (at least {min_offset} expected) -- the traces are not as expected')
    if abs(drift) > 100_000:
        sys.exit(f'anchor: after the shift the second address is {drift} records off thread 1 -- the anchor is not the same program point')
    print(f'OFFSET {off}')


def mix(name, path, skip, count):
    n = loads = stores = rmw = 0
    for _, t in records(path, skip, count):
        loads += any(t[11:15])
        stores += bool(t[9] or t[10])
        rmw += bool(rmw_addr(t))
        n += 1
    print(f'{name} records {n} loads {loads} stores {stores} rmw {rmw} rmw_per_ki {1000 * rmw / max(n, 1):.4f} (python)')


def sample(path):
    total = os.path.getsize(path) // REC
    out = []
    for frac in (0.02, 0.5, 0.9):
        n = m = 0
        for _, t in records(path, int(total * frac), 200_000):
            m += bool(t[9] or t[10] or any(t[11:15]))
            n += 1
        out.append(100.0 * m / max(n, 1))
    print(f'{os.path.basename(path)} records {total} with-a-memory-operand ' + ' '.join(f'{x:.1f}%' for x in out) + f' min {min(out):.1f}')


def main():
    a = sys.argv[1:]
    if len(a) in (5, 6) and a[0] == 'anchor':
        anchor(a[1:5], min_offset=int(a[5]) if len(a) == 6 else 100_000)
    elif len(a) == 5 and a[0] == 'residual':
        anchor(a[1:], residual=True)
    elif len(a) == 5 and a[0] == 'mix':
        mix(a[1], a[2], int(a[3]), int(a[4]))
    elif len(a) == 2 and a[0] == 'sample':
        sample(a[1])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
