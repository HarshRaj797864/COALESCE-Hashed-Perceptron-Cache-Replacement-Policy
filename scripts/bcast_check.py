#!/usr/bin/env python3
"""QR: the counter's BROADCAST line and -base0 broadcast, exact checks
(bench/policy_sanity/heldout2_design_2026-11-04.md, Note 5).

    bcast_check.py ident TRACER_DIR COUNTER_PREFIX       # R1
    bcast_check.py base0 COUNTER_PREFIX FROM TO TIDS     # R2 (TIDS: the threads that broadcast, e.g. 0 or 0,1)
    bcast_check.py same OLD_PREFIX NEW_PREFIX            # R3

A COUNTER_PREFIX P names the counter's files P.summary, P.t<tid>.cnt, P.t<tid>.rtn.
TRACER_DIR holds the tracer's pin.err (and raw0.champsimtrace[.xz], if kept).

R1 (bcast_micro SERIAL, one thread; the tracer with -sync 1 -start0 broadcast,
   the counter with -base0 broadcast, same CPUID): the counter's BROADCAST 0
   position equals the tracer's K, BASE0 equals it, and the counter's thread-0
   total equals the tracer's N; the trace's thread 0 holds N - K instruction
   records, if it was kept.
R2 (-base0 broadcast -from FROM -to TO): thread 0's BROADCAST line once, BASE0
   equal to it; a BROADCAST line for exactly the threads in TIDS, one each;
   thread 0's S records = its BROADCAST position and its W records = TO - FROM;
   a pthread_create of thread 0 after the broadcast leaves the base there (its
   W holds libc's pthread_create); at least one broadcast routine hooked.
R3 (no -base0; the committed counter and this one on one program): every
   .cnt and .rtn file equal byte for byte, the summaries equal apart from the
   new BROADCAST and HOOK lines.
"""
import glob
import lzma
import os
import re
import struct
import sys

MAGIC = 0x53594E4353594E43


def summary(prefix):
    lines = open(prefix + '.summary').read().splitlines()
    bc = [tuple(int(x) for x in ln.split()[1:4]) for ln in lines if re.match(r'BROADCAST \d', ln)]
    base0 = [ln.split()[2] for ln in lines if ln.startswith('BASE0 broadcast')]
    creates = [tuple(int(x) for x in ln.split()[1:4]) for ln in lines if re.match(r'CREATE \d', ln)]
    hooks = [ln for ln in lines if ln.startswith('HOOK pthread_cond_broadcast')]
    return lines, bc, base0, creates, hooks


def total(prefix, t):
    last = [ln for ln in open(f'{prefix}.t{t}.cnt') if ln.startswith('T ')]
    return int(last[-1].split()[1]) if last else None


def rtn(prefix, t, kind):
    out = []
    for ln in open(f'{prefix}.t{t}.rtn'):
        p = ln.split()
        if p and p[0] == kind:
            out.append((int(p[1]), p[8], ' '.join(p[9:])))
    return out


def trace_records(d):
    for name in ('raw0.champsimtrace', 'raw0.champsimtrace.xz'):
        p = os.path.join(d, name)
        if os.path.exists(p):
            op = lzma.open if p.endswith('.xz') else open
            n = 0
            with op(p, 'rb') as f:
                while True:
                    b = f.read(64 << 14)
                    if not b:
                        return n
                    for off in range(0, len(b) - 63, 64):
                        if struct.unpack_from('<Q', b, off + 24)[0] != MAGIC:
                            n += 1
    return None


def fail(msg):
    print('   FAILED: ' + msg)
    return 1


def ident(tdir, prefix):
    bad = 0
    err = open(os.path.join(tdir, 'pin.err')).read()
    m1 = re.search(r"start0: thread 0's window opens after (\d+) of its instructions", err)
    m2 = re.search(r'start0: thread 0 executed (\d+) instructions', err)
    if not m1 or not m2:
        return fail('R1: the tracer did not report K and N (pin.err)')
    k, n = int(m1.group(1)), int(m2.group(1))
    _, bc, base0, _, hooks = summary(prefix)
    b0 = [b for b in bc if b[0] == 0]
    if len(b0) != 1:
        return fail(f'R1: {len(b0)} BROADCAST lines for thread 0')
    pos, tot = b0[0][1], total(prefix, 0)
    print(f'   R1 tracer: K {k}, N {n}; counter: BROADCAST 0 at {pos}, BASE0 {",".join(base0) or "-"}, thread 0 total {tot}')
    if pos != k:
        bad += fail(f'R1: the counter places the broadcast at {pos}, the tracer at {k} ({pos - k:+d})')
    if base0 != [str(k)]:
        bad += fail(f'R1: BASE0 is {base0}, not [{k}]')
    if tot != n:
        bad += fail(f'R1: the counter counts {tot} instructions of thread 0, the tracer {n} ({(tot or 0) - n:+d})')
    r = trace_records(tdir)
    if r is not None:
        print(f'   R1 the trace\'s thread 0: {r} instruction records (N - K = {n - k})')
        if r != n - k:
            bad += fail(f'R1: the trace holds {r} records of thread 0, not N - K = {n - k}')
    if not hooks:
        bad += fail('R1: no pthread_cond_broadcast routine hooked')
    print('   R1 holds' if bad == 0 else f'   QR FAILED (R1): {bad} check(s)')
    return bad


def base0(prefix, frm, to, tids):
    bad = 0
    want = sorted(int(x) for x in tids.split(','))
    _, bc, b0line, creates, hooks = summary(prefix)
    for h in hooks:
        print('   R2 ' + h)
    if not hooks:
        bad += fail('R2: no pthread_cond_broadcast routine hooked')
    have = sorted(b[0] for b in bc)
    if have != want:
        bad += fail(f'R2: BROADCAST lines for threads {have}, expected {want} (one each)')
    z = [b for b in bc if b[0] == 0]
    if len(z) != 1:
        return bad + fail(f'R2: {len(z)} BROADCAST lines for thread 0')
    k = z[0][1]
    if b0line != [str(k)]:
        bad += fail(f'R2: BASE0 is {b0line}, not [{k}]')
    w = sum(c for c, _, _ in rtn(prefix, 0, 'W'))
    s = sum(c for c, _, _ in rtn(prefix, 0, 'S'))
    print(f'   R2 thread 0: broadcast at {k}, BASE0 {",".join(b0line)}; S {s} records (= {k}?), W {w} records (= {to - frm}?)')
    if s != k:
        bad += fail(f'R2: thread 0\'s S holds {s} records, its broadcast is at {k}')
    if w != to - frm:
        bad += fail(f'R2: thread 0\'s W holds {w} records, not {to - frm}')
    late = [c for c in creates if c[0] == 0 and c[1] > k]
    if late:
        wc = sum(c for c, img, name in rtn(prefix, 0, 'W') if img.startswith('libc.so') and name == 'pthread_create')
        print(f'   R2 thread 0 creates at {late[0][1]}, after its broadcast; its W holds {wc} records of libc\'s pthread_create')
        if not (k + frm <= late[0][1] < k + to) or wc == 0:
            bad += fail('R2: the create after the broadcast is not inside the window based at the broadcast (the base moved?)')
    for t in want:
        if t != 0:
            print(f'   R2 thread {t}: BROADCAST at {next(b[1] for b in bc if b[0] == t)}')
    print('   R2 holds' if bad == 0 else f'   QR FAILED (R2): {bad} check(s)')
    return bad


def same(old, new):
    bad, n = 0, 0
    for f in sorted(glob.glob(old + '.t*.cnt') + glob.glob(old + '.t*.rtn')):
        g = new + f[len(old):]
        n += 1
        if not os.path.exists(g):
            bad += fail(f'R3: no {os.path.basename(g)} from the new counter')
        elif open(f, 'rb').read() != open(g, 'rb').read():
            bad += fail(f'R3: {os.path.basename(f)} differs')
    extra = set(glob.glob(new + '.t*.cnt') + glob.glob(new + '.t*.rtn')) - {new + f[len(old):] for f in glob.glob(old + '.t*')}
    if extra:
        bad += fail(f'R3: the new counter wrote {len(extra)} files the old one did not')
    drop = re.compile(r'^(BROADCAST|HOOK) ')
    so = [ln for ln in open(old + '.summary').read().splitlines()]
    sn = [ln for ln in open(new + '.summary').read().splitlines() if not drop.match(ln)]
    added = len(open(new + '.summary').read().splitlines()) - len(sn)
    if so != sn:
        bad += fail('R3: the summaries differ apart from the BROADCAST and HOOK lines')
    print(f'   R3 {n} count files equal byte for byte; summaries equal apart from {added} BROADCAST / HOOK lines'
          if bad == 0 else f'   QR FAILED (R3): {bad} check(s)')
    if bad == 0:
        print('   R3 holds')
    return bad


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == 'ident':
        bad = ident(a[1], a[2])
    elif len(a) == 5 and a[0] == 'base0':
        bad = base0(a[1], int(a[2]), int(a[3]), a[4])
    elif len(a) == 3 and a[0] == 'same':
        bad = same(a[1], a[2])
    else:
        print(__doc__)
        sys.exit(2)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
