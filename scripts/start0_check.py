#!/usr/bin/env python3
"""QZ: the tracer's -start0 broadcast on a trace set, exact checks
(bench/policy_sanity/heldout2_design_2026-11-04.md, Note 4).

    start0_check.py start0 DIR WORKERS   # traced with -sync 1 -start0 broadcast -max_instr 0
    start0_check.py plain DIR            # the same tracer without -start0 (thread 0 from its start)

DIR holds raw<t>.champsimtrace[.xz] and pin.err (the tracer's messages).

start0:
  Z1 the tracer reports where thread 0's window opened (K) and how many
     instructions thread 0 executed (N);
  Z2 thread 0's first record is its base, and its first instruction record is
     the first instruction of a pthread_cond_broadcast routine the tracer hooked
     (its address, from pin.err); the trace's second record, so nothing of
     thread 0 before the call is in it;
  Z3 thread 0's instruction records number exactly N - K;
  Z4 thread 0's first release is the broadcast's, numbered at or after the
     base, and no release of thread 0 is numbered before the base;
  Z5 every worker 1..WORKERS has exactly one acquire that waits for that
     release, after its own release of the mutex the condition wait gave up.
plain:
  Z6 thread 0's base is the first release number (seq 1) and its instruction
     records number exactly N (the tracer's total for thread 0 is printed only
     with -start0, so N here is the record count, reported).
"""
import lzma
import os
import re
import struct
import sys

REC = 64
MAGIC = 0x53594E4353594E43
SK_RELEASE, SK_ACQUIRE, SK_BASE = 1, 2, 3
U = struct.Struct('<Q')


def records(path):
    op = lzma.open if path.endswith('.xz') else open
    with op(path, 'rb') as f:
        while True:
            b = f.read(REC << 14)
            if not b:
                return
            for off in range(0, len(b) - REC + 1, REC):
                yield b[off:off + REC]


def trace_path(d, t):
    for p in (f'raw{t}.champsimtrace', f'raw{t}.champsimtrace.xz'):
        if os.path.exists(os.path.join(d, p)):
            return os.path.join(d, p)
    return None


def decode(r):
    """(ip, sync) with sync = (kind, release, wait, mutex, ordered) or None."""
    ip = U.unpack_from(r, 0)[0]
    if U.unpack_from(r, 24)[0] != MAGIC:
        return ip, None
    return ip, (U.unpack_from(r, 40)[0], U.unpack_from(r, 16)[0], U.unpack_from(r, 32)[0], U.unpack_from(r, 48)[0], U.unpack_from(r, 56)[0])


def scan(path, stop_after=None):
    """Every sync record with its position, the first instruction record's ip and position, the instruction count."""
    syncs, first_ip, first_pos, n_ins = [], None, None, 0
    for i, r in enumerate(records(path)):
        ip, s = decode(r)
        if s is None:
            if first_ip is None:
                first_ip, first_pos = ip, i
            n_ins += 1
        else:
            syncs.append((i, s))
    return syncs, first_ip, first_pos, n_ins


def fail(msg):
    print('   FAILED: ' + msg)
    return 1


def check_start0(d, workers):
    bad = 0
    err = open(os.path.join(d, 'pin.err')).read()
    m1 = re.search(r"start0: thread 0's window opens after (\d+) of its instructions.*base release seq (\d+)", err)
    m2 = re.search(r"start0: thread 0 executed (\d+) instructions; its window opened after (\d+)", err)
    if not m1 or not m2:
        return fail('Z1: the tracer did not report the window (pin.err)')
    k, seq_base, n, k2 = int(m1.group(1)), int(m1.group(2)), int(m2.group(1)), int(m2.group(2))
    if k != k2:
        bad += fail(f'Z1: two window positions, {k} and {k2}')
    print(f'   Z1 thread 0: window opened after {k} of its {n} instructions; base release seq {seq_base}')
    hooks = {int(a, 16): (rtn, img) for rtn, a, img in re.findall(r'sync: pthread_cond_broadcast \(routine (\S+)\) at ([0-9a-f]+) in (\S+)', err)}
    if not hooks:
        return fail('Z2: no pthread_cond_broadcast routine was hooked')
    p0 = trace_path(d, 0)
    syncs, ip0, pos0, n0 = scan(p0)
    if not syncs or syncs[0][0] != 0 or syncs[0][1][0] != SK_BASE:
        bad += fail('Z2: thread 0\'s first record is not its base')
    else:
        base = syncs[0][1][1]
        if base != (seq_base << 8):
            bad += fail(f'Z2: the base record holds {base:#x}, the tracer reported seq {seq_base}')
    if ip0 in hooks and pos0 == 1:
        print(f'   Z2 thread 0: record 0 its base, record 1 the first instruction of {hooks[ip0][0]} ({ip0:#x}, {os.path.basename(hooks[ip0][1])})')
    else:
        bad += fail(f'Z2: thread 0\'s first instruction record (position {pos0}) is at {ip0:#x}, not the start of a hooked broadcast '
                    f'({", ".join(hex(a) for a in hooks)})')
    if n0 == n - k:
        print(f'   Z3 thread 0: {n0} instruction records = {n} - {k}')
    else:
        bad += fail(f'Z3: thread 0 has {n0} instruction records, {n} - {k} = {n - k} expected')
    rels0 = [s for _, s in syncs if s[0] == SK_RELEASE]
    early = [s for s in rels0 if (s[1] >> 8) < seq_base]
    if early:
        bad += fail(f'Z4: {len(early)} releases of thread 0 are numbered before its base')
    if not rels0:
        return bad + fail('Z4: thread 0 has no release')
    bc = rels0[0][1]
    if (bc & 0xff) != 0 or (bc >> 8) < seq_base or rels0[0][3] != 0:
        bad += fail(f'Z4: thread 0\'s first release {bc:#x} is not a broadcast at or after the base')
    unl = [s for s in rels0[1:] if s[3] != 0]
    mutex = unl[0][3] if unl else 0
    print(f'   Z4 thread 0: first release {bc:#x} (seq {bc >> 8}, no mutex: the broadcast); its next mutex release on {mutex:#x}; '
          f'{len(rels0)} releases, none before the base')
    for t in range(1, workers + 1):
        p = trace_path(d, t)
        if p is None:
            bad += fail(f'Z5: no trace of thread {t}')
            continue
        st, _, _, nt = scan(p)
        waits = [(i, s) for i, s in st if s[0] == SK_ACQUIRE and s[2] == bc]
        gave_up = [i for i, s in st if s[0] == SK_RELEASE and s[3] == mutex and mutex]
        if len(waits) != 1:
            bad += fail(f'Z5: thread {t} has {len(waits)} acquires waiting for {bc:#x}')
        elif not gave_up or gave_up[0] > waits[0][0]:
            bad += fail(f'Z5: thread {t}\'s wait for {bc:#x} does not follow its release of {mutex:#x}')
        else:
            print(f'   Z5 thread {t}: waits for {bc:#x} at record {waits[0][0]}, after its release of the mutex at record {gave_up[0]} '
                  f'({nt} instruction records)')
    return bad


def check_plain(d):
    bad = 0
    err = open(os.path.join(d, 'pin.err')).read()
    if 'start0' in err:
        bad += fail('Z6: the tracer printed start0 messages without -start0')
    syncs, ip0, pos0, n0 = scan(trace_path(d, 0))
    if not syncs or syncs[0][0] != 0 or syncs[0][1][0] != SK_BASE or syncs[0][1][1] != (1 << 8):
        bad += fail('Z6: thread 0\'s first record is not the base of release seq 1')
    creates = sum(1 for _, s in syncs if s[0] == SK_RELEASE and s[3] == 0 and (s[1] >> 8) < 8)
    b0 = f'base seq {syncs[0][1][1] >> 8} at record {syncs[0][0]}' if syncs and syncs[0][1][0] == SK_BASE else 'no base first'
    print(f'   Z6 thread 0 without -start0: {b0}, first instruction at record {pos0}, {n0} instruction records, '
          f'{len(syncs)} sync records ({creates} early releases: its creates)')
    return bad


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == 'start0':
        bad = check_start0(sys.argv[2], int(sys.argv[3]))
    elif len(sys.argv) >= 3 and sys.argv[1] == 'plain':
        bad = check_plain(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
    part = 'Z1-Z5' if sys.argv[1] == 'start0' else 'Z6'
    print(f'   {part} ' + ('hold' if part == 'Z1-Z5' else 'holds') if bad == 0 else f'   QZ FAILED ({part}): {bad} check(s)')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
