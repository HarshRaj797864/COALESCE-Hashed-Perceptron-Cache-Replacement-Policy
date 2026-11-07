#!/usr/bin/env python3
"""Cut the first N instructions off a trace that has sync records, keeping it
replayable (synchronised replay, bench/policy_sanity/sync_replay_design_2026-10-18.md).

    sync_cut.py IN OUT N        (IN, OUT: .champsimtrace or .champsimtrace.xz)

Drops the first N instruction records (sync records among them are dropped
too and not counted), then writes a fresh base record and the rest. The base
says which of this thread's releases count as done: every one it made in the
part cut away. A thread's releases are numbered in its program order, so that
is everything up to the highest one cut; with none cut, the original base
stands. Used to drop thread 0's serial start, as the anchor alignment of the
barnes and held-out traces did, without losing the sync records' meaning.

Plain Python (the server has no numpy): only the records cut are parsed; the
rest is copied as bytes.
"""
import struct
import subprocess
import sys

REC = struct.Struct('<QBB2B4B2Q4Q')     # ip, branch, taken, 2 dst regs, 4 src regs, 2 dst mem, 4 src mem
MAGIC = 0x53594E4353594E43
CHUNK = 1 << 26                          # bytes


def opener(path, mode):
    if path.endswith('.xz'):
        if mode == 'r':
            p = subprocess.Popen(['xz', '-dc', path], stdout=subprocess.PIPE)
            return p.stdout, p
        f = open(path, 'wb')
        p = subprocess.Popen(['xz', '-1', '-T1', '-c'], stdin=subprocess.PIPE, stdout=f)
        return p.stdin, p
    return open(path, mode + 'b'), None


def read_exact(f, n):
    b = b''
    while len(b) < n:
        more = f.read(n - len(b))
        if not more:
            break
        b += more
    return b


def main():
    src, dst, n_cut = sys.argv[1], sys.argv[2], int(sys.argv[3])
    fin, pin = opener(src, 'r')
    fout, pout = opener(dst, 'w')
    first = read_exact(fin, REC.size)
    if len(first) < REC.size:
        sys.exit(f'{src}: empty')
    r = REC.unpack(first)
    if r[10] != MAGIC or r[12] != 3:
        sys.exit(f'{src}: no base record at its start -- not a -sync 1 trace')
    base = r[9]
    tid = base & 0xff
    max_cut = None
    cut = 0
    pending = b''          # a parsed chunk's records after the cut point
    while cut < n_cut:
        b = read_exact(fin, min(CHUNK, (n_cut - cut + 1024) * REC.size))
        if not b:
            break
        whole = len(b) // REC.size * REC.size
        for off in range(0, whole, REC.size):
            r = REC.unpack_from(b, off)
            if r[10] == MAGIC:
                if r[12] == 1:
                    s = r[9] >> 8
                    max_cut = s if max_cut is None else max(max_cut, s)
                continue
            cut += 1
            if cut == n_cut:
                pending = b[off + REC.size:]
                break
        else:
            pending = b[whole:]
            if cut < n_cut:
                continue
        break
    if cut < n_cut:
        sys.exit(f'{src}: only {cut:,} instructions, fewer than {n_cut:,}')
    new_base = base if max_cut is None else (((max_cut + 1) << 8) | tid)
    ip = REC.unpack_from(pending, 0)[0] if len(pending) >= REC.size else 0
    fout.write(REC.pack(ip, 0, 0, 0, 0, 0, 0, 0, 0, new_base, MAGIC, 0, 3, 0, 0))
    fout.write(pending)
    kept = len(pending)
    while True:
        b = fin.read(CHUNK)
        if not b:
            break
        fout.write(b)
        kept += len(b)
    fout.close()
    if pout:
        pout.wait()
    if pin:
        pin.wait()
    print(f'{src}: cut {cut:,} instructions; base {hex(base)} -> {hex(new_base)}; {kept // REC.size:,} records kept -> {dst}', file=sys.stderr)


if __name__ == '__main__':
    main()
