#!/usr/bin/env python3
"""H6(a) (bench/policy_sanity/h6_lockreq_design_2026-11-14.md): classify each
F-C lock-word request in a coherence event log.

  h6_lockreq.py pairs TRACE... [--max-records N]   > pairs.txt
      (ip, mutex line) of every ACQUIRE sync record (kind 2, mutex != 0) in
      the first N records of each trace (xz or raw; default all)
  h6_lockreq.py qe0 LOG_A LOG_B
      the two run logs line for line with each "(Simulation time: ...)"
      masked; exit 0 if equal
  h6_lockreq.py classify EVENTLOG PAIRS RUNLOG [ADDED]
      QI1, QI2; then R0-R3 (R3G / R3U), take-backs and, given ADDED (C_F-C -
      C_before), the decomposition
  h6_lockreq.py selftest

A trace record is 64 bytes: ip, is_branch, branch_taken, 2 destination and
4 source registers, 2 destination and 4 source memory operands. A sync
record has destination_memory[1] = SYNC_MAGIC; source_memory[1] its kind,
source_memory[2] its mutex.
"""
import collections
import re
import statistics
import struct
import subprocess
import sys
import tempfile
import os

SYNC_MAGIC = 0x53594E4353594E43
MAGIC_B = struct.pack('<Q', SYNC_MAGIC)
REC = struct.Struct('<QBB2B4B2Q4Q')
SK_ACQUIRE = 2
assert REC.size == 64


def open_trace(path):
    if path.endswith('.xz'):
        p = subprocess.Popen(['xz', '-dc', path], stdout=subprocess.PIPE)
        return p.stdout, p
    return open(path, 'rb'), None


def pairs(paths, max_records=None):
    out = set()
    for path in paths:
        f, proc = open_trace(path)
        n, buf = 0, b''
        while True:
            chunk = f.read(64 << 20)
            if not chunk:
                break
            buf += chunk
            usable = len(buf) - len(buf) % 64
            if max_records is not None:
                usable = min(usable, (max_records - n) * 64)
            view = buf[:usable]
            i = view.find(MAGIC_B)
            while i != -1:
                if (i - 24) % 64 == 0:
                    r = REC.unpack_from(view, i - 24)
                    kind, mutex = r[12], r[13]          # source_memory[1], source_memory[2]
                    if kind == SK_ACQUIRE and mutex != 0:
                        out.add((r[0], mutex >> 6))
                i = view.find(MAGIC_B, i + 1)
            n += usable // 64
            buf = buf[usable:]
            if max_records is not None and n >= max_records:
                break
        f.close()
        if proc is not None:
            proc.kill()
            proc.wait()
    for ip, line in sorted(out):
        print(f'{ip:x} {line:x}')
    print(f'# {len(out)} (ip, mutex line) pairs; {len({p[0] for p in out})} ips, {len({p[1] for p in out})} mutex lines', file=sys.stderr)
    return 0


MASK = re.compile(r'\(Simulation time: [^)]*\)')


def qe0(a, b):
    la = [MASK.sub('(Simulation time: -)', ln) for ln in open(a, errors='replace').read().splitlines()]
    lb = [MASK.sub('(Simulation time: -)', ln) for ln in open(b, errors='replace').read().splitlines()]
    if la == lb:
        print(f'QE0 HOLDS: {len(la)} lines equal with the times masked')
        return 0
    diff = [(i, x, y) for i, (x, y) in enumerate(zip(la, lb)) if x != y]
    print(f'QE0 FAILS: {len(la)} against {len(lb)} lines; {len(diff)} differ in the common part')
    for i, x, y in diff[:5]:
        print(f'   line {i + 1}:\n     {x}\n     {y}')
    return 1


def load_pairs(path):
    s = set()
    for ln in open(path):
        p = ln.split()
        if len(p) == 2 and not ln.startswith('#'):
            s.add((int(p[0], 16), int(p[1], 16)))
    return s


def requests_from_log(path):
    req = {}
    for ln in open(path, errors='replace'):
        m = re.match(r'CPU (\d+) LOCK-WORD REQUESTS: measured (\d+) warmup (\d+)', ln)
        if m:
            req[int(m.group(1))] = int(m.group(2))
    return req


def bits(x):
    return bin(x).count('1')


def classify(evlog, pairfile, runlog, added=None):
    P = load_pairs(pairfile)
    req = requests_from_log(runlog)
    if not req:
        print('no LOCK-WORD REQUESTS lines in the run log: not an F-C run with sync_lock_word request')
        return 1
    own = collections.Counter()              # cpu -> identified request events
    cls = collections.Counter()              # R1, R2, R3G, R3U
    r3cores = collections.Counter()
    bad_kind = collections.Counter()
    s_fills = collections.Counter()          # amendment 1: S (a stale fill, cache.cc:139) with a pair, by access type
    pending = {}                             # line -> list of (waiter cpu, cycle, class) awaiting the next other-core G/U
    takeback = collections.defaultdict(lambda: [0, 0, []])   # class -> [located, lists waiter, gaps]
    n_lines = 0
    with open(evlog, errors='replace') as f:
        for ln in f:
            p = ln.split()
            if len(p) < 13 or p[0] == 'I':
                continue
            n_lines += 1
            kind, cyc, warm, cpu = p[0], int(p[2]), p[3], int(p[4])
            if warm != '0':
                continue
            ip, vline = int(p[6], 16), int(p[7], 16)
            prot, g5 = int(p[10], 16), int(p[12], 16)
            is_req = (ip, vline) in P
            if kind in ('G', 'U'):
                # a take-back: the next G/U on this line by another core, for each waiting request
                if vline in pending:
                    keep = []
                    for (w, c0, k) in pending[vline]:
                        if cpu != w:
                            t = takeback[k]
                            t[0] += 1
                            if g5 & (1 << w):
                                t[1] += 1
                            t[2].append(cyc - c0)
                        else:
                            keep.append((w, c0, k))
                    if keep:
                        pending[vline] = keep
                    else:
                        del pending[vline]
                if not is_req:
                    continue
                own[cpu] += 1
                if g5 != 0:
                    k = 'R3G' if kind == 'G' else 'R3U'
                    r3cores[bits(g5)] += 1
                elif prot != 0:
                    k = 'R2'
                else:
                    k = 'R1'
                cls[k] += 1
                pending.setdefault(vline, []).append((cpu, cyc, k))
            elif is_req:
                # amendment 1: an S is the fill of a request already issued (cache.cc:139), logged at the
                # L2C and / or L1D when another core took the line in flight; it is a request's own fill
                # when it is an RFO, and a load sharing the pair (QI2's concern) when it is not
                if kind == 'S':
                    s_fills[p[9]] += 1
                    if p[9] != 'RFO':
                        bad_kind['S ' + p[9]] += 1
                else:
                    bad_kind[kind] += 1
    total_req = sum(req.values())
    print(f'== {n_lines} measured-or-warm-up event lines read; requests (run log, measured) {total_req:,}: ' + ', '.join(f'CPU {c} {n:,}' for c, n in sorted(req.items())))
    qi1 = [c for c in req if own[c] > req[c]] + [c for c in own if c not in req]
    print(f'   identified request events: ' + ', '.join(f'CPU {c} {own[c]:,}' for c in sorted(set(req) | set(own))))
    print(f'QI1 {"HOLDS" if not qi1 else "FAILS on CPU " + str(sorted(qi1))}: identified events <= measured requests on every CPU')
    print(f'QI2 {"HOLDS" if not bad_kind else "FAILS: " + dict(bad_kind).__repr__()}: no L or W event has a request pair, '
          f'and every S (a stale fill) with one is an RFO (amendment 1); S with a pair by type: {dict(s_fills)}')
    if qi1 or bad_kind:
        print('\nNOT READ: the identification failed (above).')
        return 1
    r0 = total_req - sum(own.values())
    cls['R0'] = r0
    print('\n== the classes (of the measured requests)')
    names = {'R0': 'no event (stayed in the waiter\'s private caches)', 'R1': 'nobody listed', 'R2': 'listed by the protocol view, forgotten by the gem5 rule',
             'R3G': 'an event at the LLC (counts in C)', 'R3U': 'an upgrade event (counts in U, not in C)'}
    for k in ('R0', 'R1', 'R2', 'R3G', 'R3U'):
        print(f'   {k:4} {cls[k]:>9,}  {cls[k] / total_req:6.1%}  {names[k]}')
    if r3cores:
        print('   R3 by other cores listed: ' + ', '.join(f'{n}: {v:,}' for n, v in sorted(r3cores.items())))
    print('\n== take-backs (the next G or U on the line by another core)')
    for k in ('R1', 'R2', 'R3G', 'R3U'):
        t = takeback[k]
        if cls[k] == 0:
            continue
        g = sorted(t[2])
        q = (g[len(g) // 4], statistics.median(g), g[3 * len(g) // 4]) if g else ('-', '-', '-')
        print(f'   {k:4} located {t[0]:,} of {cls[k]:,}; lists the waiter {t[1]:,} ({t[1] / t[0] if t[0] else 0:.1%}); gap cycles q1 / median / q3 {q[0]} / {q[1]} / {q[2]}')
    nonG = {k: cls[k] for k in ('R0', 'R1', 'R2', 'R3U')}
    rest = sum(nonG.values())
    lead = max(nonG, key=nonG.get)
    lead = lead if rest and nonG[lead] >= 0.5 * rest else None
    print('\n== readings (fixed in the note)')
    if lead:
        print(f'   leading cause: {lead} ({nonG[lead]:,} of the {rest:,} requests that add nothing to C)')
    else:
        print(f'   no single cause: ' + ', '.join(f'{k} {v:,}' for k, v in nonG.items()))
    r1t = takeback['R1']
    if rest and cls['R0'] + cls['R1'] >= 0.5 * rest and r1t[0] and r1t[1] >= 0.5 * r1t[0]:
        print('   SUPPORTED: the request goes out before the holder has taken the lock word (R0 + R1 at least half; at least half of R1\'s take-backs list the waiter)')
    if lead == 'R2':
        print('   SUPPORTED: the holder\'s copy was already dropped (R2 leads)')
    if lead == 'R3U':
        print('   SUPPORTED: the request\'s event is an upgrade, which C does not count (R3U leads)')
    if cls['R3G'] >= 0.9 * total_req:
        print('   the request\'s own event is in C for >= 90%: the shortfall lies in displaced events')
    if added is not None:
        print(f'\n== decomposition of C_F-C - C_before = {added:,}: requests\' own events in C (R3G) {cls["R3G"]:,}; the rest {added - cls["R3G"]:+,} (displaced or caused elsewhere)')
    return 0


def selftest():
    d = tempfile.mkdtemp()
    ok = True
    # traces: 2 ACQUIRE records with mutexes, a release, a plain record carrying the magic at the wrong offset
    def rec(ip, dm=(0, 0), sm=(0, 0, 0, 0)):
        return REC.pack(ip, 0, 0, 0, 0, 0, 0, 0, 0, dm[0], dm[1], *sm)
    t = os.path.join(d, 't0')
    with open(t, 'wb') as f:
        f.write(rec(0x400100))
        f.write(rec(0x401000, (0, SYNC_MAGIC), (0, SK_ACQUIRE, 0x7f0000001040, 0)))
        f.write(rec(0x401010, (5, SYNC_MAGIC), (0, 1, 0x7f0000001040, 0)))          # a release: no pair
        f.write(rec(0x401020, (0, SYNC_MAGIC), (0, SK_ACQUIRE, 0, 0)))              # an acquire without a mutex: no pair
        f.write(rec(0x400200, (SYNC_MAGIC, 0), (0, SK_ACQUIRE, 0x7f0000002000, 0)))  # magic at the wrong offset: no pair
        f.write(rec(0x401100, (0, SYNC_MAGIC), (0, SK_ACQUIRE, 0x7f0000002000, 1)))
    subprocess.run(['xz', '-kf', t], check=True)
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
        pairs([t + '.xz'])
    got = buf.getvalue().split('\n')
    want = [f'{0x401000:x} {0x7f0000001040 >> 6:x}', f'{0x401100:x} {0x7f0000002000 >> 6:x}']
    if got[:2] != want or got[2:] != ['']:
        ok = False
        print('selftest: pairs', got)
    with contextlib.redirect_stdout(io.StringIO()):
        pairs([t], max_records=2)
    pf = os.path.join(d, 'pairs')
    open(pf, 'w').write('\n'.join(want) + '\n')
    m1, m2 = 0x7f0000001040 >> 6, 0x7f0000002000 >> 6
    # an event log: cpu 1 asks (U, g5 lists cpu 0 = R3U), cpu 0 takes it back listing cpu 1;
    # cpu 2 asks with nobody listed (R1), cpu 3 takes it back listing cpu 2; cpu 2 asks again, R2;
    # cpu 0 asks R3G on m2; the call's stack push (another line) and a normal load on m1 are not requests
    ev = [
        f'L cpu0_L1D 10 0 0 1 400100 {m1:x} 0 LOAD 0 0 0',
        f'U cpu1_L1D 100 0 1 7 401000 {m1:x} 0 RFO 1 1 1',
        f'G LLC 105 0 1 8 401000 999999 0 RFO 0 0 0',
        f'I cpu1_L1D 150 0 1 0 0 0 {m1:x} 0 0 0',
        f'G LLC 150 0 0 9 400300 {m1:x} 0 RFO 2 2 2',
        f'G LLC 200 0 2 3 401000 {m1:x} 0 RFO 0 0 0',
        f'G LLC 260 0 3 4 400300 {m1:x} 0 RFO 4 4 4',
        f'G LLC 300 0 2 5 401000 {m1:x} 0 RFO 8 0 0',
        f'G LLC 400 0 0 6 401100 {m2:x} 0 RFO 2 2 2',
        f'G LLC 401 1 0 6 401100 {m2:x} 0 RFO 2 2 2',          # warm-up: not counted
        f'S cpu0_L2C 402 0 0 6 401100 {m2:x} 0 RFO 0 0 0',     # amendment 1: the request's own stale fill, L2C then L1D
        f'S cpu0_L1D 403 0 0 6 401100 {m2:x} 0 RFO 0 0 0',
    ]
    ef = os.path.join(d, 'ev')
    open(ef, 'w').write('\n'.join(ev) + '\n')
    rl = os.path.join(d, 'run.log')
    open(rl, 'w').write('CPU 0 LOCK-WORD REQUESTS: measured 1 warmup 1\nCPU 1 LOCK-WORD REQUESTS: measured 3 warmup 0\n'
                        'CPU 2 LOCK-WORD REQUESTS: measured 2 warmup 0\nCPU 3 LOCK-WORD REQUESTS: measured 0 warmup 0\n'
                        'x (Simulation time: 00 hr 01 min 02 sec)\n')
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = classify(ef, pf, rl, added=10)
    out = buf.getvalue()
    for e in ['QI1 HOLDS', "QI2 HOLDS: no L or W event has a request pair, and every S (a stale fill) with one is an RFO (amendment 1); S with a pair by type: {'RFO': 2}", 'R0           2', 'R1           1', 'R2           1', 'R3G          1', 'R3U          1',
              'R3U  located 1 of 1; lists the waiter 1 (100.0%)', 'R1   located 1 of 1; lists the waiter 1 (100.0%); gap cycles q1 / median / q3 60 / 60 / 60',
              'no single cause: R0 2, R1 1, R2 1, R3U 1', 'SUPPORTED: the request goes out before', 'R3G) 1; the rest +9']:
        if e not in out:
            ok = False
            print(f'selftest: missing "{e}"\n{out}')
            break
    if rc != 0:
        ok = False
    # QI1: more events than requests; QI2: a load with a request pair
    open(rl + '2', 'w').write('CPU 0 LOCK-WORD REQUESTS: measured 0 warmup 0\nCPU 1 LOCK-WORD REQUESTS: measured 3 warmup 0\nCPU 2 LOCK-WORD REQUESTS: measured 2 warmup 0\n')
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = classify(ef, pf, rl + '2')
    if rc == 0 or 'QI1 FAILS' not in buf.getvalue() or 'NOT READ' not in buf.getvalue():
        ok = False
        print('selftest: QI1 fault not stopped')
    open(ef + '2', 'w').write('\n'.join(ev + [f'L cpu2_L1D 500 0 2 11 401000 {m1:x} 0 LOAD 0 0 0']) + '\n')
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = classify(ef + '2', pf, rl)
    if rc == 0 or 'QI2 FAILS' not in buf.getvalue():
        ok = False
        print('selftest: QI2 fault not stopped')
    # amendment 1: an S that is a LOAD's fill with a request pair still fails QI2
    open(ef + '3', 'w').write('\n'.join(ev + [f'S cpu2_L1D 500 0 2 11 401000 {m1:x} 0 LOAD 0 0 0']) + '\n')
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = classify(ef + '3', pf, rl)
    if rc == 0 or "QI2 FAILS: {'S LOAD': 1}" not in buf.getvalue():
        ok = False
        print('selftest: QI2 S LOAD fault not stopped')
    # qe0: equal with times masked; a real difference fails
    a, b = os.path.join(d, 'a'), os.path.join(d, 'b')
    open(a, 'w').write('x 1 (Simulation time: 00 hr 01 min 02 sec)\ny\n')
    open(b, 'w').write('x 1 (Simulation time: 05 hr 00 min 09 sec)\ny\n')
    with contextlib.redirect_stdout(io.StringIO()):
        if qe0(a, b) != 0:
            ok = False
            print('selftest: qe0 equal case')
        open(b, 'w').write('x 2 (Simulation time: 05 hr 00 min 09 sec)\ny\n')
        if qe0(a, b) == 0:
            ok = False
            print('selftest: qe0 difference not caught')
    print('selftest PASS' if ok else 'selftest FAIL')
    return 0 if ok else 1


def main(a):
    if a[:1] == ['pairs'] and len(a) > 1:
        mr = None
        if '--max-records' in a:
            i = a.index('--max-records')
            mr = int(a[i + 1])
            a = a[:i] + a[i + 2:]
        return pairs(a[1:], mr)
    if a[:1] == ['qe0'] and len(a) == 3:
        return qe0(a[1], a[2])
    if a[:1] == ['classify'] and len(a) in (4, 5):
        return classify(a[1], a[2], a[3], int(a[4]) if len(a) == 5 else None)
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
