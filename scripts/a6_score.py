#!/usr/bin/env python3
"""A6, the LLC-size sweep, scored by its pre-registration
(bench/policy_sanity/a6_size_sweep_design_2026-10-14.md).

    a6_score.py check ROWS B3ROWS     Q0 and Q1 only
    a6_score.py score ROWS B3ROWS     Q0, Q1, then the comparison (stops on a failed check)
    a6_score.py selftest              made-up rows with hand-known taus, and injected faults

ROWS = phasea_rows_vN.txt, B3ROWS = b3_rows_vN.txt (pulled; never edited).

Where each (cores, size, regime) comes from (the design's table):
  - a size A6 ran: phaseA_l2_a6_<size>mb (its 2 and 8 MB private rows are Q0's only);
  - 2 MB: shared phaseA_l2_fixed; private phaseA (lru from phaseA_l2_fixed);
  - 2 MB a core: shared phaseA_l2_scaled; private phaseA_scaled_private (lru
    from phaseA_l2_scaled, which phaseA_scaled_private lacks).
Pressure is LRU's LLC hit rate over loads and RFOs (analyze_rows.load_rfo_hit).
"""
import os
import statistics
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_rows as AR   # noqa: E402

POLS = ('lru', 'random', 'srrip', 'drrip', 'ship', 'hawkeye', 'mockingjay', 'srrip_bias')
SIZES = {4: (1, 2, 4, 8, 16), 8: (1, 2, 4, 8, 16, 32)}
A6 = 'phaseA_l2_a6_%dmb'
B3 = ('tree pol wl cores rg st ins rfo_ev rfo_sh wb_ev wb_inv pres_ev pres_co prot_ev prot_co registered selfcheck rmw'
      ' level up_ev up_co up_pres inval_copies stale_fills stale_holders rfo_bounded up_bounded'
      ' rfo_g5 rfo_g5_co up_g5 up_g5_co view_order').split()
PRESSURE_PTS = 5.0       # a matched pair counts only if LRU's two hit rates are within 5 points
NEAR_TIE = 0.005         # every policy within 0.5% of LRU: the order is noise
Q0 = ((4, 2, 'phaseA'), (4, 8, 'phaseA_scaled_private'))     # (cores, size, older private tree)
Q0_POLS = ('hawkeye', 'srrip_bias')


def source(n, size, rg, pol):
    if size == 2:
        return 'phaseA_l2_fixed' if (rg == 'shared' or pol == 'lru') else 'phaseA'
    if size == 2 * n:
        return 'phaseA_l2_scaled' if (rg == 'shared' or pol == 'lru') else 'phaseA_scaled_private'
    return A6 % size


def index(rows):
    return {(r['tree'], r['pol'], r['wl'], r['cores'], r['rg']): r for r in rows if r['wl'] == 'canneal'}


def load_b3(path):
    out = {}
    for line in open(path):
        p = line.split()
        if not p or p[0].startswith('#'):
            continue
        r = dict(zip(B3, p))
        out[(r['tree'], r['pol'], r['wl'], int(r['cores']), r['rg'])] = r
    return out


def gather(rows):
    """{(n, size, rg): {pol: row}} and the list of problems."""
    ix, got, bad = index(rows), {}, []
    for n, sizes in SIZES.items():
        for s in sizes:
            for rg in ('shared', 'private'):
                d = {}
                for pol in POLS:
                    r = ix.get((source(n, s, rg, pol), pol, 'canneal', n, rg))
                    if r is None:
                        bad.append(f'Q1 no row: {pol} canneal {n}c {s} MB {rg} (tree {source(n, s, rg, pol)})')
                    else:
                        d[pol] = r
                got[(n, s, rg)] = d
    return got, bad


def checks(rows, b3):
    ix = index(rows)
    got, bad = gather(rows)
    # Q0: the older private rows stand in for the frozen binary
    for n, s, old in Q0:
        for pol in Q0_POLS:
            a, b = ix.get((A6 % s, pol, 'canneal', n, 'private')), ix.get((old, pol, 'canneal', n, 'private'))
            if a is None or b is None:
                bad.append(f'Q0 {pol} {n}c {s} MB: row missing ({A6 % s}: {a is not None}, {old}: {b is not None})')
                continue
            for c in ('max_cyc', 'min_cyc', 'ins'):
                if a[c] != b[c]:
                    bad.append(f'Q0 {pol} {n}c {s} MB private: {c} {a[c]} (frozen binary) vs {b[c]} ({old})')
    for n in SIZES:   # LRU: the level-2 row against the older private tree at 2 MB
        a, b = ix.get(('phaseA_l2_fixed', 'lru', 'canneal', n, 'private')), ix.get(('phaseA', 'lru', 'canneal', n, 'private'))
        if a and b and any(a[c] != b[c] for c in ('max_cyc', 'min_cyc', 'ins')):
            bad.append(f'Q0 lru {n}c 2 MB private: phaseA_l2_fixed and phaseA differ')
    # Q1: every row used
    for (n, s, rg), d in got.items():
        for pol, r in d.items():
            tag = f'{pol} canneal {n}c {s} MB {rg} ({r["tree"]})'
            if r['st'] != 'complete':
                bad.append(f'Q1 {tag}: {r["st"]}')
            if r['vm'] != 'ok' or r['tw'] != 'ok':
                bad.append(f'Q1 {tag}: page pool {r["vm"]}, trace wrap {r["tw"]}')
            if r['ins'] < AR.MIN_INSTR_PER_CORE * n:
                bad.append(f'Q1 {tag}: {r["ins"]} instructions')
            if rg == 'private' and (r['inval'] or r['aliased']):
                bad.append(f'Q1 {tag}: private with inval {r["inval"]} aliased {r["aliased"]}')
            if rg == 'shared' and not (r['inval'] and r['aliased']):
                bad.append(f'Q1 {tag}: shared with inval {r["inval"]} aliased {r["aliased"]}')
            if r['tree'] in ('phaseA', 'phaseA_scaled_private'):
                continue          # the older binary: Q0 stands in
            k = (r['tree'], pol, 'canneal', n, rg)
            x = b3.get(k)
            if x is None:
                bad.append(f'Q1 {tag}: no B3 row')
                continue
            if x['level'] != '2' or x['selfcheck'] != '0' or x['stale_holders'] != '0' or x['registered'] != str(3 * n):
                bad.append(f'Q1 {tag}: level {x["level"]} self-check {x["selfcheck"]} stale-holders {x["stale_holders"]} registered {x["registered"]}')
        cyc = defaultdict(list)
        for pol, r in d.items():
            cyc[r['max_cyc']].append(pol)
        for mc, ps in cyc.items():
            if len(ps) > 1:
                bad.append(f'Q1 canneal {n}c {s} MB {rg}: {", ".join(ps)} share max_cycles {mc}')
    return got, bad


def order(d):
    return [p for p in sorted(d, key=lambda p: d[p]['max_cyc'])]


def tau(d1, d2):
    return AR.kendall_tau(order(d1), order(d2))


def spread(d):
    lru = d['lru']['max_cyc']
    return max(abs(r['max_cyc'] / lru - 1) for r in d.values())


def verdict_n(m, c):
    if len(m) < 2:
        return 'undecided', None
    med = statistics.median(m)
    if med < min(c):
        return 'below', med
    if med > max(c):
        return 'above', med
    return 'within', med


def score(got, out=print):
    res = {}
    for n, sizes in SIZES.items():
        out(f'\n== {n} cores: Kendall tau over the 8 baselines ==')
        hr = {(s, rg): AR.load_rfo_hit(got[(n, s, rg)]['lru']) * 100 for s in sizes for rg in ('shared', 'private')}
        M, C = [], []
        out('   matched pairs M (shared s MB vs private n*s MB; counts if LRU hit rates within 5 points):')
        for s in (1, 2, 4):
            a, b = got[(n, s, 'shared')], got[(n, n * s, 'private')]
            t, dp = tau(a, b), abs(hr[(s, 'shared')] - hr[(n * s, 'private')])
            ok = dp <= PRESSURE_PTS
            if ok:
                M.append(t)
            out(f'      shared {s:>2} vs private {n * s:>2}: tau {t:+.2f}; LRU hit {hr[(s, "shared")]:.2f}% vs {hr[(n * s, "private")]:.2f}% '
                f'({dp:.2f} pts){"" if ok else " -- NOT COUNTED (pressure differs)"}'
                f'{"; near tie" if max(spread(a), spread(b)) < NEAR_TIE else ""}')
        out('   controls C (the same factor n inside one regime):')
        for rg in ('private', 'shared'):
            for s in (1, 2, 4):
                if (n, n * s, rg) not in got:
                    continue
                a, b = got[(n, s, rg)], got[(n, n * s, rg)]
                t = tau(a, b)
                C.append(t)
                out(f'      {rg:7} {s:>2} vs {n * s:>2}: tau {t:+.2f}{"; near tie" if max(spread(a), spread(b)) < NEAR_TIE else ""}')
        v, med = verdict_n(M, C)
        res[n] = v
        out(f'   median over M: {"-" if med is None else f"{med:+.2f}"} ({len(M)} counted); C range {min(C):+.2f} .. {max(C):+.2f} '
            f'({len(C)}) -> {v.upper()}')
    vs = list(res.values())
    if all(v == 'below' for v in vs):
        h = 'H1: sharing reorders the policies beyond size and pressure (both n below every control)'
    elif all(v == 'above' for v in vs):
        h = 'H2: sharing reorders the policies less than size does (both n above every control)'
    elif any(v == 'within' for v in vs):
        h = 'H0: not distinguishable from a size effect (an n lies within the controls)'
    else:
        h = 'NONE of H0-H2 as written: ' + ', '.join(f'{n}c {v}' for n, v in res.items())
    out(f'\n== VERDICT: {h} ==')
    return h, res


def report(got, out=print):
    out('\n== Reported: same-size cross-regime tau (shared s vs private s) ==')
    for n, sizes in SIZES.items():
        out(f'   {n}c: ' + '; '.join(f'{s} MB {tau(got[(n, s, "shared")], got[(n, s, "private")]):+.2f}' for s in sizes))
    out('\n== Reported: each configuration, ranked (speedup over LRU, gap to the next; LRU load+RFO hit) ==')
    for n, sizes in SIZES.items():
        for rg in ('shared', 'private'):
            for s in sizes:
                d = got[(n, s, rg)]
                lru = d['lru']['max_cyc']
                o = order(d)
                cells = []
                for i, p in enumerate(o):
                    g = f'/{d[o[i + 1]]["max_cyc"] / d[p]["max_cyc"] - 1:+.2%}' if i + 1 < len(o) else ''
                    cells.append(f'{p} {lru / d[p]["max_cyc"] - 1:+.2%}{g}')
                out(f'   {n}c {rg:7} {s:>2} MB  hit {AR.load_rfo_hit(d["lru"]) * 100:5.2f}%  spread {spread(d):.2%}: ' + ', '.join(cells))


# ---------------------------------------------------------------- self-test
def _row(tree, pol, n, rg, cyc, hit=50):
    r = dict(tree=tree, pol=pol, wl='canneal', cores=n, rg=rg, st='complete', vm='ok', tw='ok',
             max_cyc=cyc, min_cyc=cyc, ins=100_000_000 * n + 1, load_acc=1000, load_hit=hit * 10,
             tot_acc=1000, tot_hit=hit * 10, wr_acc=0, wr_hit=0, rfo_acc=0, rfo_hit=0, tr_acc=0, tr_hit=0,
             aliased=1 if rg == 'shared' else 0, inval=1 if rg == 'shared' else 0)
    return r


def _make(orders, hits):
    """orders[(n, s, rg)] = policy list fastest first; hits[(n, s, rg)] = LRU hit %."""
    rows, b3 = [], {}
    for (n, s, rg), o in orders.items():
        for i, pol in enumerate(o):
            t = source(n, s, rg, pol)
            rows.append(_row(t, pol, n, rg, 1_000_000 + 1000 * i + s, hits[(n, s, rg)]))
            b3[(t, pol, 'canneal', n, rg)] = dict(level='2', selfcheck='0', stale_holders='0', registered=str(3 * n))
    for n, s, old in Q0:   # Q0 rows equal the older tree
        for pol in Q0_POLS:
            src = next(r for r in rows if r['tree'] == old and r['pol'] == pol and r['cores'] == n and r['rg'] == 'private')
            rows.append(dict(src, tree=A6 % s))
    return rows, b3


def selftest():
    fails = 0

    def expect(name, cond):
        nonlocal fails
        print(f'   {"ok  " if cond else "FAIL"} {name}')
        fails += 0 if cond else 1

    P = list(POLS)
    R = list(reversed(POLS))
    swap1 = P[:]; swap1[0], swap1[1] = swap1[1], swap1[0]           # tau 1 - 2/28 = +0.929
    flat = {(n, s, rg): 50 for n, sz in SIZES.items() for s in sz for rg in ('shared', 'private')}
    # case A: shared always P, private always R -> M = -1, C = +1 (both regimes) -> H1
    oa = {(n, s, rg): (P if rg == 'shared' else R) for n, sz in SIZES.items() for s in sz for rg in ('shared', 'private')}
    rows, b3 = _make(oa, flat)
    got, bad = checks(rows, b3)
    expect('A: the made-up rows pass every check', not bad)
    h, res = score(got, out=lambda *_: None)
    expect('A: matched -1 below controls +1 at both n -> H1', h.startswith('H1') and res == {4: 'below', 8: 'below'})
    # case B: everything the same order -> M = C = +1 -> H0
    rows, b3 = _make({k: P for k in oa}, flat)
    got, bad = checks(rows, b3)
    h, res = score(got, out=lambda *_: None)
    expect('B: one order everywhere -> H0 (within)', h.startswith('H0') and res == {4: 'within', 8: 'within'})
    # case C: matched pairs equal, every control differs. Three disjoint single swaps O1, O2, O4 of P:
    #   shared s = O_s and private n*s = O_s (s = 1, 2, 4); every other size P. Each control then
    #   compares P with an O (tau 1 - 2/28) or two O's (1 - 4/28) -> M = +1 above every control -> H2
    def sw(i):
        o = P[:]; o[i], o[i + 1] = o[i + 1], o[i]; return o
    O = {1: sw(0), 2: sw(2), 4: sw(4)}
    oc = {}
    for n, sz in SIZES.items():
        for s in sz:
            oc[(n, s, 'shared')] = O.get(s, P)
            oc[(n, s, 'private')] = O[s // n] if s % n == 0 and s // n in O else P
    rows, b3 = _make(oc, flat)
    got, bad = checks(rows, b3)
    expect('C: rows pass', not bad)
    h, res = score(got, out=lambda *_: None)
    t = tau({p: {'max_cyc': i} for i, p in enumerate(swap1)}, {p: {'max_cyc': i} for i, p in enumerate(P)})
    expect(f'C: one swap gives tau {t:+.3f} = 1 - 2/28', abs(t - (1 - 2 / 28)) < 1e-9)
    expect('C: matched +1 above every control (+0.93 / +0.86) at both n -> H2', h.startswith('H2') and res == {4: 'above', 8: 'above'})
    # case D: pressure differs by > 5 points on two of three matched pairs at 8c -> 8c undecided -> neither H1 nor H2
    hd = dict(flat)
    hd[(8, 1, 'shared')] = 60; hd[(8, 2, 'shared')] = 40
    rows, b3 = _make(oa, hd)
    got, bad = checks(rows, b3)
    h, res = score(got, out=lambda *_: None)
    expect('D: two pairs excluded at 8c -> 8c undecided; no H1', res[8] == 'undecided' and not h.startswith('H1'))
    # injected faults: each must be named by the checks
    faults = [
        ('private row with an invalidation', lambda rs, b: next(r for r in rs if r['rg'] == 'private' and r['tree'] == A6 % 1).update(inval=3)),
        ('shared row with no aliased fill', lambda rs, b: next(r for r in rs if r['rg'] == 'shared' and r['tree'] == A6 % 4).update(aliased=0)),
        ('trace wrapped', lambda rs, b: next(r for r in rs if r['tree'] == A6 % 16).update(tw='WRAP')),
        ('two policies share max_cycles', lambda rs, b: [r.update(max_cyc=5) for r in rs if r['tree'] == A6 % 32 and r['rg'] == 'shared' and r['pol'] in ('lru', 'ship')]),
        ('Q0: the frozen binary differs from the older private row', lambda rs, b: next(r for r in rs if r['tree'] == A6 % 8 and r['pol'] == 'hawkeye' and r['cores'] == 4).update(max_cyc=7)),
        ('level 0 in a B3 row', lambda rs, b: next(v for k, v in b.items() if k[0] == 'phaseA_l2_scaled').update(level='0')),
        ('self-check non-zero', lambda rs, b: next(v for k, v in b.items() if k[0] == A6 % 1).update(selfcheck='4')),
        ('a missing row', lambda rs, b: rs.remove(next(r for r in rs if r['tree'] == A6 % 4 and r['pol'] == 'mockingjay' and r['cores'] == 8 and r['rg'] == 'private'))),
        ('too few instructions', lambda rs, b: next(r for r in rs if r['tree'] == 'phaseA').update(ins=5)),
    ]
    for name, f in faults:
        rows, b3 = _make(oa, flat)
        f(rows, b3)
        _, bad = checks(rows, b3)
        expect(f'fault caught: {name} ({bad[0][:70] if bad else "NOT CAUGHT"})', bool(bad))
    print(f'== selftest {"PASSES" if not fails else f"FAILS ({fails})"} ==')
    return fails


def main(argv):
    if len(argv) == 2 and argv[1] == 'selftest':
        return 1 if selftest() else 0
    if len(argv) != 4 or argv[1] not in ('check', 'score'):
        sys.exit(__doc__)
    rows, b3 = AR.load(argv[2]), load_b3(argv[3])
    got, bad = checks(rows, b3)
    print(f'== Q0 and Q1: {len(bad)} problem(s) ==')
    for b in bad:
        print('   ' + b)
    if bad:
        print('== STOPPED: a check failed; nothing is scored ==')
        return 1
    print('   Q0 holds: hawkeye and srrip_bias 4c private at 2 and 8 MB equal the older rows; Q1 holds on every row used')
    if argv[1] == 'check':
        return 0
    score(got)
    report(got)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
