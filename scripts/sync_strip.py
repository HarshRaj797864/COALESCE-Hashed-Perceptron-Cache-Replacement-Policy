#!/usr/bin/env python3
"""Part C (bench/policy_sanity/breadth_bc_design_2026-11-10.md): remove the
sync records from a synchronised trace, so that a ChampSim without the
extension (upstream's own binary) can replay the thread's instructions.

    sync_strip.py strip IN OUT      (.champsimtrace or .champsimtrace.xz)
    sync_strip.py count IN          read-only: the same counts, nothing written
    sync_strip.py selftest          a made-up trace with hand-known records

A sync record (sync_replay.h) is a 64-byte trace record whose second
destination-memory field holds the magic "SYNCSYNC"; its second source-memory
field is the kind (1 release, 2 acquire, 3 base). Every such record is
dropped, the base record included; every other record is copied byte for
byte, in order. Prints: records in, sync records by kind, records out.
Plain Python (the server has no numpy).
"""
import io
import os
import struct
import subprocess
import sys
import tempfile

REC = struct.Struct('<QBB2B4B2Q4Q')     # ip, branch, taken, 2 dst regs, 4 src regs, 2 dst mem, 4 src mem
SIZE = REC.size                          # 64
MAGIC = 0x53594E4353594E43               # "SYNCSYNC"
KINDS = {1: 'release', 2: 'acquire', 3: 'base'}
DST1 = 10                                # index of destination_memory[1] in REC's fields
SRC1 = 12                                # index of source_memory[1]
CHUNK = SIZE * (1 << 20)                 # 64 MB of records at a time


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


def strip_stream(fin, fout):
    """-> (records in, {kind: count}, records out, odd trailing bytes)"""
    n_in = 0
    n_out = 0
    kinds = {}
    tail = b''
    while True:
        buf = tail + read_exact(fin, CHUNK)
        if not buf:
            break
        whole = len(buf) - len(buf) % SIZE
        tail = buf[whole:]
        buf = buf[:whole]
        if not buf:
            break
        out = bytearray()
        for off in range(0, whole, SIZE):
            n_in += 1
            dst1, = struct.unpack_from('<Q', buf, off + 8 + 1 + 1 + 2 + 4 + 8)   # after ip, 2 bytes, 2 regs, 4 regs, dst mem[0]
            if dst1 == MAGIC:
                kind, = struct.unpack_from('<Q', buf, off + 8 + 1 + 1 + 2 + 4 + 16 + 8)   # source_memory[1]
                kinds[kind] = kinds.get(kind, 0) + 1
                continue
            out += buf[off:off + SIZE]
            n_out += 1
        if fout is not None and out:
            fout.write(out)
    return n_in, kinds, n_out, len(tail)


def report(src, n_in, kinds, n_out, odd):
    ks = ', '.join(f'{KINDS.get(k, f"kind {k}")} {v}' for k, v in sorted(kinds.items()))
    n_sync = sum(kinds.values())
    print(f'{src}: {n_in} records in; {n_sync} sync records ({ks or "none"}); {n_out} records out'
          + (f'; {odd} odd trailing bytes IGNORED' if odd else ''))
    assert n_in == n_sync + n_out


def strip(src, dst):
    fin, pin = opener(src, 'r')
    fout, pout = opener(dst, 'w')
    r = strip_stream(fin, fout)
    fout.close()
    if pout is not None:
        pout.wait()
        if pout.returncode:
            sys.exit(f'xz failed writing {dst}')
    if pin is not None:
        pin.wait()
    report(src, *r)
    return r


def count(src):
    fin, pin = opener(src, 'r')
    r = strip_stream(fin, None)
    if pin is not None:
        pin.wait()
    report(src, *r)
    return r


def make_record(ip, dst1=0, src1=0, tag=0):
    return REC.pack(ip, 0, 0, 0, 0, 0, 0, 0, 0, tag, dst1, 0, src1, 0, 0)


def selftest():
    # a hand-made trace: base, 4 plain, release, 3 plain, acquire, 2 plain = 12 records, 3 sync
    recs = [make_record(0x1000, MAGIC, 3, 0x300), make_record(0x10, tag=1), make_record(0x11, tag=2),
            make_record(0x12, tag=3), make_record(0x13, tag=4), make_record(0x2000, MAGIC, 1, 0x100),
            make_record(0x14, tag=5), make_record(0x15, tag=6), make_record(0x16, tag=7),
            make_record(0x3000, MAGIC, 2, 0x200), make_record(0x17, tag=8), make_record(0x18, tag=9)]
    plain = [r for r in recs if REC.unpack(r)[DST1] != MAGIC]
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        for ext in ('', '.xz'):
            src = os.path.join(d, 'in.champsimtrace' + ext)
            dst = os.path.join(d, 'out.champsimtrace' + ext)
            data = b''.join(recs)
            if ext:
                subprocess.run(['xz', '-c'], input=data, stdout=open(src, 'wb'), check=True)
            else:
                open(src, 'wb').write(data)
            n_in, kinds, n_out, odd = strip(src, dst)
            got = subprocess.run(['xz', '-dc', dst], capture_output=True, check=True).stdout if ext else open(dst, 'rb').read()
            ok = (n_in, kinds, n_out, odd) == (12, {1: 1, 2: 1, 3: 1}, 9, 0) and got == b''.join(plain)
            bad += not ok
            print(f'   {"ok  " if ok else "FAIL"} strip{ext or " (raw)"}: 12 in, base 1 release 1 acquire 1, 9 out, bytes equal: {got == b"".join(plain)}')
            c = count(src)
            ok = c == (n_in, kinds, n_out, odd)
            bad += not ok
            print(f'   {"ok  " if ok else "FAIL"} count{ext or " (raw)"} equals strip')
        # no sync records at all: byte-identical copy
        src = os.path.join(d, 'plain.champsimtrace'); dst = os.path.join(d, 'plain_out.champsimtrace')
        open(src, 'wb').write(b''.join(plain) + b'\x01\x02')     # plus 2 odd bytes
        n_in, kinds, n_out, odd = strip(src, dst)
        ok = (n_in, kinds, n_out, odd) == (9, {}, 9, 2) and open(dst, 'rb').read() == b''.join(plain)
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} a trace without sync records copies byte for byte; 2 odd bytes reported')
        # a chunk boundary: 1,048,576 records a chunk; 1,048,580 records with a sync record astride it
        big = os.path.join(d, 'big.champsimtrace'); bigo = os.path.join(d, 'big_out.champsimtrace')
        n = (1 << 20) + 4
        with open(big, 'wb') as f:
            for i in range(n):
                f.write(make_record(0x2000, MAGIC, 1) if i in ((1 << 20) - 1, 1 << 20) else make_record(i))
        n_in, kinds, n_out, odd = strip(big, bigo)
        ok = (n_in, kinds, n_out, odd) == (n, {1: 2}, n - 2, 0) and os.path.getsize(bigo) == (n - 2) * SIZE
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} sync records on both sides of a chunk boundary: {n} in, 2 dropped, {n - 2} out')
    print(f'== selftest {"PASSES" if not bad else f"FAILS ({bad})"} ==')
    return bad


def main(argv):
    if len(argv) == 2 and argv[1] == 'selftest':
        return 1 if selftest() else 0
    if len(argv) == 4 and argv[1] == 'strip':
        strip(argv[2], argv[3]); return 0
    if len(argv) == 3 and argv[1] == 'count':
        count(argv[2]); return 0
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
