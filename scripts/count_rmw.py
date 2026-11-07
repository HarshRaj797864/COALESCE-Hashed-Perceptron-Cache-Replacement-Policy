#!/usr/bin/env python3
"""Count read-modify-write instructions in a ChampSim trace, read from stdin.

    xz -dc trace.xz | count_rmw.py SKIP COUNT        (records)

An RMW is an instruction one of whose destination memory addresses is also a
source memory address -- what ooo_cpu.cc (f23e03f) issues as an RFO. This
counts them straight from the trace, independently of the simulator, to check
the simulator's "RMW LOADS ISSUED AS RFO" counter (verify_b3.sh).

Prints: records read, with a load, with a store, RMW instructions, RMW per KI.
Uses numpy when it is there; plain Python otherwise (slower, same answer --
tested against each other on a synthetic trace).
"""
import struct
import sys

REC = 64


def main():
    skip, count = int(sys.argv[1]), int(sys.argv[2])
    force_py = len(sys.argv) > 3 and sys.argv[3] == '--python'
    f = sys.stdin.buffer
    left = skip * REC
    while left > 0:                                  # a pipe cannot seek
        b = f.read(min(left, 1 << 24))
        if not b:
            sys.exit("trace ended inside the skipped part")
        left -= len(b)
    try:
        if force_py:
            raise ImportError
        import numpy as np
        dt = np.dtype([('ip', '<u8'), ('br', 'u1'), ('tk', 'u1'), ('dr', 'u1', 2), ('sr', 'u1', 4), ('dm', '<u8', 2), ('sm', '<u8', 4)])
        assert dt.itemsize == REC
        how = 'numpy'
    except ImportError:
        np = None
        how = 'python'
    n = loads = stores = rmw = 0
    rec = struct.Struct('<QBB2B4B2Q4Q')
    while n < count:
        want = min(count - n, 1 << 20) * REC
        b = f.read(want)
        while len(b) % REC and len(b) < want:        # a short read mid-record
            more = f.read(want - len(b))
            if not more:
                break
            b += more
        b = b[:len(b) - len(b) % REC]
        if not b:
            break
        if np is not None:
            a = np.frombuffer(b, dtype=dt)
            dm, sm = a['dm'], a['sm']
            loads += int((sm != 0).any(axis=1).sum())
            stores += int((dm != 0).any(axis=1).sum())
            hit = np.zeros(len(a), dtype=bool)
            for i in range(2):
                d = dm[:, i]
                hit |= (d != 0) & (sm == d[:, None]).any(axis=1)
            rmw += int(hit.sum())
            n += len(a)
        else:
            for t in rec.iter_unpack(b):
                d = [x for x in t[9:11] if x]
                s = [x for x in t[11:15] if x]
                loads += bool(s)
                stores += bool(d)
                rmw += any(x in s for x in d)
                n += 1
    print(f"records {n} loads {loads} stores {stores} rmw {rmw} rmw_per_ki {1000 * rmw / max(n, 1):.4f} ({how})")


if __name__ == '__main__':
    main()
