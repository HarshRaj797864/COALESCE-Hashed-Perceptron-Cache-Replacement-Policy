#!/usr/bin/env python3
"""E (bench/policy_sanity/second_protocol_design_2026-11-18.md): a second gem5
protocol, MESI_Two_Level. Checks, fixed before any of its runs exists.

    e2_check.py ql0 ORIG_DIR NEW_DIR [GSRC G2]   (server) one run's config.ini against its MESI_Three_Level original
    e2_check.py ql1 TWO_DIR THREE_DIR            (server) the micro: r8 - r4 of G and U, both protocols
    e2_check.py selftest

QL0: every section outside system.ruby equal to the original's (ORIG's
directory read as NEW's, and GSRC's path as G2's), lines naming a
system.ruby object aside; NEW has system.ruby.l1_cntrl<N>.L1Dcache and
.L1Icache for each original l1_cntrl<N> and no l0_cntrl; the new L1D's size
and assoc = the original's l1_cntrl<N>.cache, the new L1I's = the original's
l0_cntrl<N>.Icache; the L2's size, assoc and replacement policy type equal;
randomization false. Exit 0 = PASS, 1 = FAIL.

QL1: for each of the 10 cases, from DIR/<case>_r4 and DIR/<case>_r8 (each
ended, one statistics dump read: the first), G = L2 SS.L1_GETX + MT.L1_GETX
and U = SS.L1_UPGRADE; holds if |dG_two - dG_three| <= 1 and |dU_two -
dU_three| <= 1 on every case (d = r8 - r4). Hand counts (4 rounds) reported.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hset_check import secs, kv, first_diff  # noqa: E402

CASES = ['pp_lock', 'pp_store', 'pp_rmw', 'readers', 'upgrade', 'ctl', 'priv_E', 'priv_S', 'llc_out', 'offchip']
# per 4 rounds (micro_results_2026-10-18.md, gem5's rule for priv_E / priv_S): G, U
HAND = {'pp_lock': (12, 0), 'pp_store': (12, 0), 'pp_rmw': (12, 0), 'readers': (4, 0), 'upgrade': (0, 4),
        'ctl': (4, 0), 'priv_E': (0, 0), 'priv_S': (4, 0), 'llc_out': (0, 0), 'offchip': (0, 0)}
C = 'system.ruby.L2Cache_Controller.'


def ql0(orig_dir, new_dir, gsrc=None, g2=None, out=print):
    a = secs(os.path.join(orig_dir, 'config.ini'), orig_dir, new_dir)
    b = secs(os.path.join(new_dir, 'config.ini'))
    if gsrc and g2:
        pat = re.compile(re.escape(gsrc.rstrip('/')) + r'(?=/|\s|$)')   # the tree's path, never a longer name (gem5_b3)
        a = {s: [pat.sub(g2.rstrip('/'), ln) for ln in v] for s, v in a.items()}
    ruby = lambda s: s == 'system.ruby' or s.startswith('system.ruby.')
    keep = lambda v: [ln for ln in v if 'system.ruby' not in ln.split('=', 1)[-1]]
    bad = []
    na, nb = {s for s in a if not ruby(s)}, {s for s in b if not ruby(s)}
    bad += [f'[{s}] missing in the new run' for s in sorted(na - nb)]
    bad += [f'[{s}] only in the new run' for s in sorted(nb - na)]
    bad += [f'[{s}]: {first_diff(keep(a[s]), keep(b[s]))}' for s in sorted(na & nb) if keep(a[s]) != keep(b[s])]
    l1o = sorted(s for s in a if re.fullmatch(r'system\.ruby\.l1_cntrl\d+', s))
    if not l1o:
        bad.append('no system.ruby.l1_cntrl<N> in the original')
    if not any(re.fullmatch(r'system\.ruby\.l0_cntrl\d+', s) for s in a):
        bad.append('the original has no l0_cntrl: not a MESI_Three_Level run')
    if any(re.fullmatch(r'system\.ruby\.l0_cntrl\d+', s) for s in b):
        bad.append('the new run has an l0_cntrl: not MESI_Two_Level')
    l1n = sorted(s for s in b if re.fullmatch(r'system\.ruby\.l1_cntrl\d+', s))
    if l1n != l1o:
        bad.append(f'l1 controllers {len(l1n)} in the new run, {len(l1o)} in the original')
    for s in l1o:
        n = s[len('system.ruby.'):]
        o_d, o_i = kv(a.get(f'{s}.cache', [])), kv(a.get(f'system.ruby.{n.replace("l1_", "l0_")}.Icache', []))
        n_d, n_i = kv(b.get(f'{s}.L1Dcache', [])), kv(b.get(f'{s}.L1Icache', []))
        for what, o, nw in (('L1D vs the original l1 cache', o_d, n_d), ('L1I vs the original l0 Icache', o_i, n_i)):
            for k in ('size', 'assoc'):
                if not o.get(k) or o.get(k) != nw.get(k):
                    bad.append(f'{n} {what}: {k} {nw.get(k)} (original {o.get(k)})')
    lo, ln_ = kv(a.get('system.ruby.l2_cntrl0.L2cache', [])), kv(b.get('system.ruby.l2_cntrl0.L2cache', []))
    for k in ('size', 'assoc'):
        if not lo.get(k) or lo.get(k) != ln_.get(k):
            bad.append(f'L2 {k} {ln_.get(k)} (original {lo.get(k)})')
    po = kv(a.get('system.ruby.l2_cntrl0.L2cache.replacement_policy', [])).get('type')
    pn = kv(b.get('system.ruby.l2_cntrl0.L2cache.replacement_policy', [])).get('type')
    if not po or po != pn:
        bad.append(f'L2 replacement policy {pn} (original {po})')
    if kv(b.get('system.ruby', [])).get('randomization') != 'false':
        bad.append('randomization is not false')
    for x in bad[:14]:
        out('   QL0: ' + x)
    out(f'QL0 {"PASS" if not bad else "FAIL"}: MESI_Two_Level, {len(l1o)} private L1(s) as the original\'s l1 (data) and l0 (instructions)'
        + ('' if not bad else f'; {len(bad)} problem(s)'))
    return not bad


def first_block(stats):
    s, blocks = {}, 0
    for line in open(stats):
        if 'Begin Simulation Statistics' in line:
            blocks += 1
            if blocks > 1:
                break
            continue
        p = line.split()
        if len(p) >= 2 and re.fullmatch(r'-?[0-9.e+]+', p[1]) and p[0] not in s:
            s[p[0]] = float(p[1])
    return s


def counts(run):
    log, st = os.path.join(run, 'run.log'), os.path.join(run, 'stats.txt')
    if not (os.path.exists(log) and 'Exiting @ tick' in open(log, errors='replace').read() and os.path.exists(st)):
        return None
    s = first_block(st)
    return int(s.get(C + 'SS.L1_GETX', 0) + s.get(C + 'MT.L1_GETX', 0)), int(s.get(C + 'SS.L1_UPGRADE', 0))


def ql1(two, three, out=print):
    bad = 0
    for c in CASES:
        v = {(d, r): counts(os.path.join(d, f'{c}_r{r}')) for d in (two, three) for r in (4, 8)}
        if any(x is None for x in v.values()):
            out(f'{c:9s} MISSING an ended run ({", ".join(f"{os.path.basename(d.rstrip(chr(47)))} r{r}" for (d, r), x in v.items() if x is None)})')
            bad += 1
            continue
        dg2, du2 = (v[(two, 8)][i] - v[(two, 4)][i] for i in (0, 1))
        dg3, du3 = (v[(three, 8)][i] - v[(three, 4)][i] for i in (0, 1))
        ok = abs(dg2 - dg3) <= 1 and abs(du2 - du3) <= 1
        bad += not ok
        out(f'{c:9s} dG two {dg2}, three {dg3}; dU two {du2}, three {du3} -- {"ok" if ok else "FAILS"}'
            f' (hand G {HAND[c][0]}, U {HAND[c][1]}; reported)')
    out(f'QL1 {"holds" if bad == 0 else "FAILS"}: {len(CASES) - bad} of {len(CASES)}')
    return 0 if bad == 0 else 1


def selftest():
    import tempfile
    ok = bad = 0

    def check(name, got, want):
        nonlocal ok, bad
        g = got == want
        ok, bad = ok + g, bad + (not g)
        print(f'   {"ok  " if g else "FAIL"}  {name}: {got} (want {want})')

    orig = '''[root]
type=Root
children=system

[system]
type=System
children=cpu0 ruby

[system.cpu0]
type=BaseTimingSimpleCPU
dcache_port=system.ruby.l0_cntrl0.sequencer.in_ports[1]
max_insts_any_thread=50000000

[system.cpu0.workload]
type=Process
cmd=/x/CANNEAL 4
cwd=@GSRC@
errout=@ODIR@/cerr

[system.ruby]
type=RubySystem
children=l0_cntrl0 l1_cntrl0 l2_cntrl0
randomization=false

[system.ruby.l0_cntrl0]
type=L0Cache_Controller

[system.ruby.l0_cntrl0.Icache]
type=RubyCache
assoc=8
size=32768

[system.ruby.l0_cntrl0.Dcache]
type=RubyCache
assoc=8
size=32768

[system.ruby.l1_cntrl0]
type=L1Cache_Controller

[system.ruby.l1_cntrl0.cache]
type=RubyCache
assoc=8
size=524288

[system.ruby.l2_cntrl0.L2cache]
type=RubyCache
assoc=16
size=2097152

[system.ruby.l2_cntrl0.L2cache.replacement_policy]
type=TreePLRURP
'''
    new = '''[root]
type=Root
children=system

[system]
type=System
children=cpu0 ruby

[system.cpu0]
type=BaseTimingSimpleCPU
dcache_port=system.ruby.l1_cntrl0.sequencer.in_ports[1]
max_insts_any_thread=50000000

[system.cpu0.workload]
type=Process
cmd=/x/CANNEAL 4
cwd=@G2@
errout=@NDIR@/cerr

[system.ruby]
type=RubySystem
children=l1_cntrl0 l2_cntrl0
randomization=false

[system.ruby.l1_cntrl0]
type=L1Cache_Controller

[system.ruby.l1_cntrl0.L1Icache]
type=RubyCache
assoc=8
size=32768

[system.ruby.l1_cntrl0.L1Dcache]
type=RubyCache
assoc=8
size=524288

[system.ruby.l2_cntrl0.L2cache]
type=RubyCache
assoc=16
size=2097152

[system.ruby.l2_cntrl0.L2cache.replacement_policy]
type=TreePLRURP
'''
    q = lambda *a: ql0(*a, out=lambda x: None)
    with tempfile.TemporaryDirectory() as t:
        gs, g2 = os.path.join(t, 'gem5'), os.path.join(t, 'gem5_two')
        o, n = os.path.join(t, 'gem5_b3', 'o'), os.path.join(t, 'gem5_b3', 'e2', 'o')
        os.makedirs(o)
        os.makedirs(n)
        sub = lambda x: x.replace('@GSRC@', gs).replace('@G2@', g2).replace('@ODIR@', o).replace('@NDIR@', n)

        def put(text):
            open(os.path.join(n, 'config.ini'), 'w').write(sub(text))
        open(os.path.join(o, 'config.ini'), 'w').write(sub(orig))
        put(new)
        check('QL0 passes (the output path under gem5_b3 is not rewritten as the tree)', q(o, n, gs, g2), True)
        check('QL0 without the tree mapping fails (cwd)', q(o, n), False)
        put(new.replace('size=524288', 'size=32768'))
        check('QL0 with L1D 32 kB fails', q(o, n, gs, g2), False)
        put(new.replace('max_insts_any_thread=50000000', 'max_insts_any_thread=150000000'))
        check('QL0 with another stop fails', q(o, n, gs, g2), False)
        put(new.replace('randomization=false', 'randomization=true'))
        check('QL0 with randomization fails', q(o, n, gs, g2), False)
        put(new.replace('type=TreePLRURP', 'type=LRURP'))
        check('QL0 with another L2 policy fails', q(o, n, gs, g2), False)
        put(orig.replace('cwd=@GSRC@', 'cwd=@G2@').replace('@ODIR@', '@NDIR@'))
        check('QL0 on a MESI_Three_Level run fails', q(o, n, gs, g2), False)

        def stats(d, g, u):
            os.makedirs(d)
            open(os.path.join(d, 'run.log'), 'w').write('Exiting @ tick 5 because exiting with last active thread context\n')
            open(os.path.join(d, 'stats.txt'), 'w').write(
                '---------- Begin Simulation Statistics ----------\n'
                f'{C}SS.L1_GETX  {g[0]}  0.0%\n{C}MT.L1_GETX  {g[1]}  0.0%\n{C}SS.L1_UPGRADE  {u}  0.0%\n'
                '---------- End Simulation Statistics   ----------\n'
                '---------- Begin Simulation Statistics ----------\n'
                f'{C}SS.L1_GETX  999  0.0%\n')
        two, three = os.path.join(t, 'two'), os.path.join(t, 'three')
        for c in CASES:
            g, u = HAND[c]
            stats(os.path.join(two, f'{c}_r4'), (1, 2), 0)
            stats(os.path.join(two, f'{c}_r8'), (1 + g, 2), u)
            stats(os.path.join(three, f'{c}_r4'), (3, 0), 1)
            stats(os.path.join(three, f'{c}_r8'), (3 + g + (1 if c == 'readers' else 0), 0), 1 + u)
        silent = lambda x: None
        check('QL1 holds (a difference of 1 allowed)', ql1(two, three, out=silent), 0)
        import shutil
        shutil.rmtree(os.path.join(two, 'priv_S_r8'))
        stats(os.path.join(two, 'priv_S_r8'), (1, 2), 0)
        check('QL1 fails when priv_S differs by 4', ql1(two, three, out=silent), 1)
        shutil.rmtree(os.path.join(two, 'ctl_r4'))
        check('QL1 fails on a missing run', ql1(two, three, out=silent), 1)
    print(f'== selftest: {ok} hold, {bad} fail ==')
    return 1 if bad else 0


def main(a):
    if len(a) in (3, 5) and a[0] == 'ql0':
        return 0 if ql0(*a[1:]) else 1
    if len(a) == 3 and a[0] == 'ql1':
        return ql1(a[1], a[2])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
