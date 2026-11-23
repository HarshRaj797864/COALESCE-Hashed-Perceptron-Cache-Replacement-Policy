#!/usr/bin/env python3
"""fmm under gem5: the diagnosis's tests (bench/policy_sanity/fmm_gem5_design_2026-11-17.md).

  fmm_diag.py t1 GEM5_RUN_DIR [...]   per CPU: committed instructions, idle fraction, idle cycles; the
                                      run log's warnings naming futex or an unimplemented syscall
  fmm_diag.py t2 LEAD_THREAD RUN_LOG [...]
                                      the replay's positions (heartbeats: retired instructions since the
                                      trace's start) when the core of LEAD_THREAD first passes 50 M; each
                                      core's sync and mutex waiting
  fmm_diag.py t3 RUNS_DIR KEY THREADS the share of window records (W rows of c.t<n>.rtn) in libc lock /
                                      futex / cond / barrier routines, per thread, per gem5-CPUID run
  fmm_diag.py t4 RUNS_DIR KEY NTHREADS  amendment 2: each counter run's role thread (InitParticleList A records
                                      >= 10x every other thread's), gem5-CPUID runs and the host run
  fmm_diag.py selftest
"""
import collections
import os
import re
import sys

LOCKISH = ('lll_lock', 'mutex', 'futex', 'cond', 'barrier')
LEAD_POS = 50_000_000


def t1(dirs):
    for d in dirs:
        st = open(os.path.join(d, 'stats.txt'), errors='replace').read()
        cpus = sorted({int(c) for c in re.findall(r'^system\.cpu(\d+)\.numCycles', st, re.M)})
        print(f'== {d}')
        for c in cpus:
            def val(name):
                m = re.search(rf'^system\.cpu{c}\.{re.escape(name)}\s+(\S+)', st, re.M)
                return m.group(1) if m else '-'
            ins, cyc, idle, idf = val('commitStats0.numInsts'), val('numCycles'), val('exec_context.thread_0.numIdleCycles'), val('exec_context.thread_0.idleFraction')
            print(f'   CPU {c:2d}: committed {int(float(ins)) if ins != "-" else "-":>12} cycles {cyc:>14} idle cycles {idle:>14} idle fraction {idf}')
        log = os.path.join(d, 'run.log')
        warn = collections.Counter()
        if os.path.exists(log):
            for ln in open(log, errors='replace'):
                if re.search(r'futex|unimplemented|unknown syscall', ln, re.I):
                    warn[re.sub(r'\d+', 'N', ln.strip())] += 1
        print('   warnings naming futex or an unimplemented syscall: ' + ('none' if not warn else '; '.join(f'{n} x {w}' for w, n in warn.items())))
    return 0


def heartbeats(text):
    hb = collections.defaultdict(list)
    for m in re.finditer(r'^Heartbeat CPU (\d+) instructions: (\d+) cycles: (\d+)', text, re.M):
        hb[int(m.group(1))].append((int(m.group(3)), int(m.group(2))))
    return hb


def pos_at(series, cyc):
    """a core's position at cycle cyc from its heartbeats: interpolated, or a bound"""
    if not series or cyc < series[0][0]:
        return None, f'< {series[0][1] / 1e6:.1f} M (before its first heartbeat)' if series else 'no heartbeat'
    for (c0, i0), (c1, i1) in zip(series, series[1:]):
        if c0 <= cyc <= c1:
            return i0 + (i1 - i0) * (cyc - c0) / (c1 - c0), None
    return series[-1][1], f'>= {series[-1][1] / 1e6:.1f} M (after its last heartbeat)'


def t2_one(lead, path):
    text = open(path, errors='replace').read()
    thread = {}
    for c, p in re.findall(r'^CPU (\d+) runs (\S+)$', text, re.M):
        m = re.search(r'raw(\d+)(?:_aligned)?\.champsimtrace', os.path.basename(p))
        thread[int(c)] = int(m.group(1)) if m else None
    core = next((c for c, t in thread.items() if t == lead), None)
    if core is None:
        return f'no core replays thread {lead}'
    hb = heartbeats(text)
    first = next(((cy, i) for cy, i in hb.get(core, []) if i >= LEAD_POS), None)
    if first is None:
        return f'core {core} (thread {lead}) never passes {LEAD_POS:,} in its heartbeats'
    cyc = first[0]
    held = {int(c): (int(a), int(r), int(h)) for c, a, r, h in re.findall(r'^CPU (\d+) SYNC ACQUIRES: (\d+) RELEASES: (\d+) CYCLES HELD: (\d+)', text, re.M)}
    mut = {int(c): int(w) for c, _, w in re.findall(r'^CPU (\d+) MUTEX ACQUIRES: (\d+) CYCLES WAITING FOR A MUTEX: (\d+)', text, re.M)}
    out = [f'core {core} (thread {lead}) passes {first[1] / 1e6:.1f} M at cycle {cyc:,}; the other cores then:']
    below = above25 = 0
    others = 0
    for c in sorted(thread):
        p, why = pos_at(hb.get(c, []), cyc)
        s = f'{p / 1e6:7.1f} M' if p is not None else why
        if c != core and thread[c] not in (0,):
            others += 1
            # amendment 1: below 10 M = interpolated below it, or before the core's first heartbeat
            if p is None:
                below += why.startswith('<') and hb.get(c) and hb[c][0][1] <= 10_500_000
                above25 += why.startswith('>=')
            else:
                below += p < 10e6
                above25 += p > 25e6
        h = held.get(c, ('-', '-', '-'))
        out.append(f'      core {c:2d} thread {thread[c]}: {s}; sync cycles held {h[2]}, mutex waiting {mut.get(c, "-")}')
    out.append(f'   workers other than thread {lead} (thread 0 aside): {below} of {others} below 10 M, {above25} above 25 M')
    return '\n'.join(out)


def t2(lead, paths):
    for p in paths:
        print(f'== {p}')
        print('   ' + t2_one(int(lead), p))
    return 0


def t3(runs_dir, key, threads):
    tids = [int(x) for x in threads.split(',')]
    for k in ('1', '2', '3'):
        d = os.path.join(runs_dir, f'{key}__gem5__{k}')
        row = []
        for t in tids:
            f = os.path.join(d, f'c.t{t}.rtn')
            if not os.path.exists(f):
                row.append(f't{t} -')
                continue
            tot = lk = 0
            top = collections.Counter()
            for ln in open(f, errors='replace'):
                q = ln.split()
                if len(q) < 10 or q[0] != 'W':
                    continue
                n = int(q[1])
                tot += n
                name = ' '.join(q[9:])
                if q[8].startswith('libc') and any(w in name.lower() for w in LOCKISH):
                    lk += n
                    top[name] += n
            row.append(f't{t} {100 * lk / tot:.2f}%' if tot else f't{t} no W rows')
        print(f'{key} run {k}: ' + '; '.join(row))
    return 0


def role_thread(run_dir, n):
    """(role thread or None, {t: InitParticleList A records})"""
    cnt = {}
    for t in range(n):
        f = os.path.join(run_dir, f'c.t{t}.rtn')
        c = 0
        if os.path.exists(f):
            for ln in open(f, errors='replace'):
                q = ln.split()
                if len(q) >= 10 and q[0] == 'A' and q[8].startswith('FMM') and q[9] == 'InitParticleList':
                    c += int(q[1])
        cnt[t] = c
    top = max(cnt, key=cnt.get)
    rest = max((v for t, v in cnt.items() if t != top), default=0)
    return (top if cnt[top] > 0 and cnt[top] >= 10 * rest else None), cnt


def t4(runs_dir, key, n):
    n = int(n)
    for kind in ('gem5', 'host'):
        for k in ('1', '2', '3'):
            d = os.path.join(runs_dir, f'{key}__{kind}__{k}')
            if not os.path.isdir(d):
                continue
            r, cnt = role_thread(d, n)
            print(f'{key} {kind} run {k}: role thread {r if r is not None else "none (no single role thread)"}; '
                  + ' '.join(f't{t}:{v}' for t, v in cnt.items()))
    return 0


def selftest():
    ok = bad = 0

    def expect(name, cond, detail=''):
        nonlocal ok, bad
        ok, bad = ok + bool(cond), bad + (not cond)
        print(f'   {"ok  " if cond else "FAIL"}  {name}' + ('' if cond else f': {detail}'))

    log = '\n'.join(['CPU 0 runs /x/raw0_aligned.champsimtrace.xz', 'CPU 1 runs /x/raw1.champsimtrace.xz', 'CPU 2 runs /x/raw7.champsimtrace.xz',
                     'Heartbeat CPU 2 instructions: 40000000 cycles: 100', 'Heartbeat CPU 2 instructions: 50000005 cycles: 200',
                     'Heartbeat CPU 0 instructions: 10000000 cycles: 50', 'Heartbeat CPU 0 instructions: 60000000 cycles: 250',
                     'Heartbeat CPU 1 instructions: 30000000 cycles: 300',
                     'CPU 1 SYNC ACQUIRES: 5 RELEASES: 5 CYCLES HELD: 999', 'CPU 1 MUTEX ACQUIRES: 3 CYCLES WAITING FOR A MUTEX: 7', ''])
    import tempfile
    d = tempfile.mkdtemp(prefix='fmm_diag_')
    p = os.path.join(d, 'run.log')
    open(p, 'w').write(log)
    t = t2_one(7, p)
    expect('T2 lead core and cycle', 'core 2 (thread 7) passes 50.0 M at cycle 200' in t, t)
    expect('T2 interpolation (core 0: 10 M at 50, 60 M at 250 -> 47.5 M at 200)', 'core  0 thread 0:    47.5 M' in t, t)
    expect('T2 before a first heartbeat at 30 M: bounded, not counted below 10 M', '< 30.0 M (before its first heartbeat)' in t
           and '0 of 1 below 10 M, 0 above 25 M' in t, t)
    t_ = t2_one(7, p) if open(p, 'w').write(log.replace('instructions: 30000000 cycles: 300', 'instructions: 10000003 cycles: 300')) else ''
    expect('T2 before a first heartbeat at 10 M: counted below 10 M', '1 of 1 below 10 M' in t_, t_)
    expect('T2 sync and mutex waiting read', 'sync cycles held 999, mutex waiting 7' in t, t)
    os.makedirs(os.path.join(d, 'k__gem5__1'))
    open(os.path.join(d, 'k__gem5__1', 'c.t1.rtn'), 'w').write(
        'W 900 1 1 0 1 1 0 FMM.dyn ComputeForces\nW 100 1 1 0 1 1 0 libc.so.6 __lll_lock_wait\nA 5000 1 1 0 1 1 0 libc.so.6 pthread_mutex_lock\n')
    import io
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()) as o:
        t3(d, 'k', '1')
    expect('T3 share of window records in libc lock routines', 't1 10.00%' in o.getvalue(), o.getvalue())
    os.makedirs(os.path.join(d, 'r'))
    for t, v in ((0, 50), (1, 100), (2, 2000)):
        open(os.path.join(d, 'r', f'c.t{t}.rtn'), 'w').write(f'A {v} 1 1 0 1 1 0 FMM.dyn InitParticleList\nA 9999 1 1 0 1 1 0 libc.so.6 InitParticleList\n')
    r, cnt = role_thread(os.path.join(d, 'r'), 3)
    expect('T4 role thread at >= 10x (2000 vs 100), libc rows ignored', r == 2 and cnt == {0: 50, 1: 100, 2: 2000}, (r, cnt))
    open(os.path.join(d, 'r', 'c.t1.rtn'), 'w').write('A 300 1 1 0 1 1 0 FMM.dyn InitParticleList\n')
    r, _ = role_thread(os.path.join(d, 'r'), 3)
    expect('T4 no single role thread below 10x (2000 vs 300)', r is None, r)
    print(f'== selftest: {ok} hold, {bad} fail ==')
    return 1 if bad else 0


def main(a):
    if a[:1] == ['t1'] and len(a) >= 2:
        return t1(a[1:])
    if a[:1] == ['t2'] and len(a) >= 3:
        return t2(a[1], a[2:])
    if a[:1] == ['t3'] and len(a) == 4:
        return t3(*a[1:])
    if a[:1] == ['t4'] and len(a) == 4:
        return t4(*a[1:])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
