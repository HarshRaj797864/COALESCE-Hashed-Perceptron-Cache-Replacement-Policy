#!/usr/bin/env python3
"""A and B (bench/policy_sanity/panel_design_2026-11-18.md): error statistics
across programs, and the smallest bias each span would show.

    python3 scripts/panel_stats.py rows  > bench/policy_sanity/panel_rows_v1.txt
    python3 scripts/panel_stats.py stats bench/policy_sanity/panel_rows_v1.txt
    python3 scripts/panel_stats.py power bench/policy_sanity/panel_rows_v1.txt
    python3 scripts/panel_stats.py selftest

rows: one row per span and counter, read through lock_fix_score's functions
(its parser check first; each F-C rerun must qualify):
  ROW <span> <counter> <x ChampSim per KI> <y gem5 per KI> <set>
  counters S (store misses finding a holder), U (upgrades; gem5 >= 10,000),
  H (S + U), T (traffic); set: scored | apart
"""
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SCORED = ['fluidanimate', 'vips', 'barnes std window', 'barnes std start', 'barnes std force', 'barnes-256',
          'ocean 2 MB', 'canneal 4c 2 MB', 'canneal 8c', 'radix', 'lunc']
ONE_PER_PROGRAM = ['fluidanimate', 'vips', 'barnes std force', 'barnes-256', 'ocean 2 MB', 'canneal 4c 2 MB', 'radix', 'lunc']
APART = ['bodytrack', 'fmm', 'ocean non-contiguous']
COUNTERS = ['S', 'U', 'H', 'T']
NAMES = {'S': 'store misses finding a holder (R_g5)', 'U': 'upgrades', 'H': 'all store-time hand-overs (S + U)', 'T': 'traffic'}
BAND = (0.5, 2.0)
PERMS = 100_000
SEED = 20261118


def rows():
    import lock_fix_score as L
    D, B, sp = L.spans()
    if not L.parser_check(verbose=False):
        sys.exit('the parser check failed: nothing is read')
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    umin = getattr(L, 'U_MIN_GEM5', None) or getattr(B, 'U_MIN_GEM5')
    out = []
    for label, role, tree, (_, ga, gb), logroot, _, _ in sp:
        if label not in SCORED + APART:
            continue
        w = B.window(Gr, ga, gb)
        sub = tree[len('phaseA_b3_'):]
        newroot = os.path.join(L.NEW, 'phaseA_b3_fc_' + sub)
        if not os.path.isdir(newroot):
            sys.exit(f'{label}: no F-C rerun pulled')
        ot = open(D.runlog(logroot, tree)).read()
        nt = open(D.runlog(L.NEW, os.path.basename(newroot))).read()
        why = L.qualify(ot, nt)
        if why:
            sys.exit(f'{label}: the F-C rerun does not qualify -- {why}')
        c = L.counts(nt)
        ki = lambda v: 1000.0 * v / c['ins']
        gk = lambda v: 1000.0 * v / w['insts']
        G = w['ss_getx'] + w['mt_getx']
        s = 'scored' if label in SCORED else 'apart'
        tag = label.replace(' ', '_')
        out.append(f'ROW {tag} S {ki(c["C"]):.6f} {gk(G):.6f} {s}')
        if c['up'] is not None and w['ss_upgrade'] >= umin:
            out.append(f'ROW {tag} U {ki(c["up"]):.6f} {gk(w["ss_upgrade"]):.6f} {s}')
        if c['up'] is not None:
            out.append(f'ROW {tag} H {ki(c["C"] + c["up"]):.6f} {gk(G + w["ss_upgrade"]):.6f} {s}')
        out.append(f'ROW {tag} T {ki(c["tot"] - c["wr"]):.6f} {gk(w["demand_acc"]):.6f} {s}')
    print('# panel rows (panel_design_2026-11-18.md): ROW span counter x_ChampSim_perKI y_gem5_perKI set')
    print('\n'.join(out))
    return 0


def read_rows(path):
    r = {}
    for ln in open(path):
        q = ln.split()
        if q and q[0] == 'ROW':
            r[(q[1].replace('_', ' '), q[2])] = (float(q[3]), float(q[4]), q[5])
    return r


def ranks(v):
    o = sorted(range(len(v)), key=lambda i: v[i])
    rk = [0.0] * len(v)
    i = 0
    while i < len(o):
        j = i
        while j + 1 < len(o) and v[o[j + 1]] == v[o[i]]:
            j += 1
        for k in range(i, j + 1):
            rk[o[k]] = (i + j) / 2.0 + 1
        i = j + 1
    return rk


def pearson(a, b):
    n = len(a)
    ma, mb = sum(a) / n, sum(b) / n
    sa = math.sqrt(sum((x - ma) ** 2 for x in a))
    sb = math.sqrt(sum((y - mb) ** 2 for y in b))
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / (sa * sb) if sa and sb else float('nan')


def spearman(a, b):
    return pearson(ranks(a), ranks(b))


def perm_p(a, b, perms=PERMS, seed=SEED):
    """two-sided: the share of permutations of b with |rho| >= |observed rho|"""
    rho = spearman(a, b)
    ra, rb = ranks(a), ranks(b)
    rnd = random.Random(seed)
    hit = 0
    rbp = list(rb)
    for _ in range(perms):
        rnd.shuffle(rbp)
        if abs(pearson(ra, rbp)) >= abs(rho) - 1e-12:
            hit += 1
    return (hit + 1) / (perms + 1)


def summary(pairs):
    x = [p[0] for p in pairs]
    y = [p[1] for p in pairs]
    lr = [math.log(a / b) for a, b in pairs]
    n = len(pairs)
    inb = sum(BAND[0] <= a / b <= BAND[1] for a, b in pairs)
    gm = math.exp(sum(abs(v) for v in lr) / n)
    med = math.exp(sorted(abs(v) for v in lr)[n // 2] if n % 2 else sum(sorted(abs(v) for v in lr)[n // 2 - 1:n // 2 + 1]) / 2)
    nrmse = math.sqrt(sum((a - b) ** 2 for a, b in pairs) / n) / (sum(y) / n)
    return {'n': n, 'inband': inb, 'rho': spearman(x, y), 'p': perm_p(x, y) if n >= 4 else float('nan'),
            'r_log': pearson([math.log(v) for v in x], [math.log(v) for v in y]), 'gm': gm, 'med': med, 'nrmse': nrmse}


def stats(path):
    R = read_rows(path)
    claim = {}
    for cset, names in (('scored', SCORED), ('one per program', ONE_PER_PROGRAM)):
        print(f'== the {cset} set ({len(names)} spans)')
        for k in COUNTERS:
            pairs = [R[(s, k)][:2] for s in names if (s, k) in R]
            if len(pairs) < 3:
                print(f'   {k} {NAMES[k]}: n {len(pairs)}, too few')
                continue
            m = summary(pairs)
            claim[(cset, k)] = m
            print(f'   {k} {NAMES[k]}: n {m["n"]}, in the band {m["inband"]} of {m["n"]}; Spearman rho {m["rho"]:+.3f} (p {m["p"]:.5f}{" = the floor 1 / (permutations + 1)" if m["p"] <= 1.5 / (PERMS + 1) else ""}, {PERMS:,} permutations);'
                  f' Pearson r of logs {m["r_log"]:+.3f}; geometric-mean error x{m["gm"]:.3f}; median |error| x{m["med"]:.3f}; NRMSE {m["nrmse"]:.3f}')
    s, o = claim.get(('scored', 'S')), claim.get(('one per program', 'S'))
    ok = s and o and s['rho'] >= 0.7 and s['p'] < 0.05 and o['rho'] >= 0.7
    print('== reading (fixed in the note): "ChampSim orders programs by store-time sharing as gem5 does" '
          + ('MAY be said' if ok else 'may NOT be said') + f' (S: rho {s["rho"]:+.3f}, p {s["p"]:.4f}; one per program rho {o["rho"]:+.3f}; needs >= 0.7, < 0.05, >= 0.7)')
    print('== apart (never in a statistic)')
    for sname in APART:
        v = [f'{k} {R[(sname, k)][0] / R[(sname, k)][1]:.3f}' for k in COUNTERS if (sname, k) in R]
        print(f'   {sname}: ' + ', '.join(v))
    return 0


def power(path):
    R = read_rows(path)
    print('== B2: the smallest bias in ChampSim\'s count that takes a span out of the band (2 / R_g5 up, 0.5 / R_g5 down)')
    hi, lo = [], []
    for sname in SCORED:
        x, y, _ = R[(sname, 'S')]
        r = x / y
        inb = BAND[0] <= r <= BAND[1]
        print(f'   {sname:18s} R_g5 {r:.3f}' + (f'   detectable: inflated x{2 / r:.2f}, deflated x{0.5 / r:.2f}' if inb else '   (outside the band)'))
        if inb:
            hi.append(2 / r)
            lo.append(0.5 / r)
    md = lambda v: sorted(v)[len(v) // 2] if len(v) % 2 else sum(sorted(v)[len(v) // 2 - 1:len(v) // 2 + 1]) / 2
    print(f'   medians over the {len(hi)} agreeing spans: inflated x{md(hi):.2f}, deflated x{md(lo):.2f}')
    return 0


def selftest():
    ok = bad = 0

    def check(name, got, want, tol=1e-9):
        nonlocal ok, bad
        good = abs(got - want) <= tol
        ok, bad = ok + good, bad + (not good)
        print(f'   {"ok  " if good else "FAIL"}  {name}: {got:.6f} (want {want:.6f})')

    check('ranks with a tie', sum(ranks([10, 20, 20, 5])), 10.0)
    check('rank of the tie', ranks([10, 20, 20, 5])[1], 3.5)
    check('Spearman, same order', spearman([1, 2, 3, 4], [10, 30, 50, 90]), 1.0)
    check('Spearman, reversed', spearman([1, 2, 3, 4], [9, 7, 5, 1]), -1.0)
    check('Spearman, one swap of 4 (1 - 6*2/60)', spearman([1, 2, 3, 4], [1, 3, 2, 4]), 0.8)
    # 5 points in order: |rho| = 1 occurs for 2 of 120 permutations -> p ~ 2/120
    check('permutation p, perfect order of 5', perm_p([1, 2, 3, 4, 5], [1, 2, 3, 4, 5], perms=60000, seed=1), 2 / 120, tol=0.003)
    m = summary([(2.0, 1.0), (1.0, 2.0), (1.0, 1.0)])
    check('geometric-mean error (ln 2, ln 2, 0 -> x2^(2/3))', m['gm'], 2 ** (2 / 3))
    check('median |error| factor', m['med'], 2.0)
    check('NRMSE (sqrt(2/3) / (4/3))', m['nrmse'], math.sqrt(2 / 3) / (4 / 3))
    check('in the band (2.0, 0.5, 1.0 all in)', m['inband'], 3)
    print(f'== selftest: {ok} hold, {bad} fail ==')
    return 1 if bad else 0


def main(a):
    if a == ['rows']:
        return rows()
    if len(a) == 2 and a[0] == 'stats':
        return stats(a[1])
    if len(a) == 2 and a[0] == 'power':
        return power(a[1])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
