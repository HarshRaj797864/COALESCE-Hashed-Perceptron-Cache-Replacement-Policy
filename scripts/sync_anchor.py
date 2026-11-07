#!/usr/bin/env python3
"""Where does thread 0's parallel section start? From the sync records alone.

    sync_anchor.py THREAD0_TRACE WORKER_TRACE [WORKER_TRACE ...]

A created thread's trace begins with its base record and an acquire on the
release its pthread_create made (champsim_tracer.cpp: create_wait), so the
workers' first acquires name thread 0's thread creations. The parallel section
starts at the LAST of them: this prints the number of instructions thread 0
executes before that release (sync records are not counted, as sync_cut.py
counts), the cut for sync_cut.py:

    CREATES <release ids>
    CUT <instructions>

It replaces the old anchor (barnes_std_traces.py anchor), which needs raw,
unsynchronised traces; checked against it on the programs it aligned
(bench/policy_sanity/newbench_design_2026-10-19.md). Plain Python, read-only.
"""
import struct
import subprocess
import sys

MAGIC = struct.pack('<Q', 0x53594E4353594E43)
REC = 64
CHUNK = REC << 20
Q = struct.Struct('<Q')


def stream(path):
    if path.endswith('.xz'):
        p = subprocess.Popen(['xz', '-dc', path], stdout=subprocess.PIPE, bufsize=1 << 20)
        return p.stdout, p
    return open(path, 'rb'), None


def read_exact(f, n):
    parts, got = [], 0
    while got < n:
        b = f.read(n - got)
        if not b:
            break
        parts.append(b)
        got += len(b)
    return b''.join(parts)


def first_wait(path):
    """The wait id of a trace's first acquire record (its create_wait), or None."""
    f, p = stream(path)
    b = read_exact(f, REC * 16)
    if p:
        p.kill()
        p.wait()
    for off in range(0, len(b) - REC + 1, REC):
        if b[off + 24:off + 32] == MAGIC and Q.unpack_from(b, off + 40)[0] == 2:
            return Q.unpack_from(b, off + 32)[0]
    return None


def instructions_before(path, release_id):
    """Instructions (non-sync records) before the record announcing release_id."""
    f, p = stream(path)
    rec0 = syncs = 0
    try:
        while True:
            b = read_exact(f, CHUNK)
            if not b:
                return None
            i = b.find(MAGIC)
            while i != -1:
                if i % REC == 24:
                    r = i - 24
                    if Q.unpack_from(b, r + 40)[0] == 1 and Q.unpack_from(b, r + 16)[0] == release_id:
                        return rec0 + r // REC - syncs
                    syncs += 1
                i = b.find(MAGIC, i + 1)
            rec0 += len(b) // REC
    finally:
        if p:
            p.kill()
            p.wait()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    t0, workers = sys.argv[1], sys.argv[2:]
    creates = []
    for w in workers:
        c = first_wait(w)
        if c is None:
            sys.exit(f'{w}: no create_wait at its start -- not a -sync 1 trace of a created thread')
        creates.append(c)
    tids = {c & 0xff for c in creates}
    if len(tids) != 1:
        sys.exit(f'the workers were created by different threads: {sorted(tids)}')
    last = max(creates, key=lambda c: c >> 8)
    n = instructions_before(t0, last)
    if n is None:
        sys.exit(f'{t0}: no release {last:#x} -- is this the creating thread?')
    print('CREATES ' + ' '.join(f'{c:#x}' for c in sorted(creates, key=lambda c: c >> 8)))
    print(f'CUT {n}')


if __name__ == '__main__':
    main()
