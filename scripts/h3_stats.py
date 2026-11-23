#!/usr/bin/env python3
"""H3 (bench/policy_sanity/h3_statistics_design_2026-11-14.md): ChampSim's noise
floor from window-shifted runs, and the ranking statistics restated.

  scripts/h3_stats.py noise LOGTOP REFTOP CFGDIR   > bench/policy_sanity/h3_noise_vN.txt
      LOGTOP: the pulled shifted runs (simulator/results/h3/logs: trees
      phaseA_b3_h3w<W>_canneal8[_scaled]); REFTOP: step 5's pulled logs
      (simulator/results/policy/logs); CFGDIR: step 5's configs
      (simulator/results/policy/sync_pol/cfg). Qualifies every run, checks the
      parser against ROWS (env H3_ROWS, default phasea_rows_v29.txt), fits the
      two-way model per class and prints s_e, delta and the pair table.
  scripts/h3_stats.py score ROWS [NOISEFILE]
      every restated statement: tau_b, its exact p, and where the class's delta
      is declared tau_delta, sign agreement, top-1 / top-3, the noise ceiling
      and interval, R1-R4. Without NOISEFILE (or with a class not declared) the
      tie rule is left out and said so.
  scripts/h3_stats.py selftest
"""
import itertools
import json
import math
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import analyze_rows as AR          # noqa: E402

SEED = 20261114
DRAWS = 10000
T975_12 = 2.178812829667228        # t(0.975, 12)
BIN_G6 = 'champsim_g6_1e3060c1'
DONE = 'ChampSim completed all CPUs'
TREE = 'phaseA_b3_p2_'
POLS = ('lru', 'random', 'srrip', 'drrip', 'ship', 'hawkeye', 'mockingjay', 'srrip_bias', 'coalesce')   # = policy_jobs.POLICIES
BASE8 = POLS[:-1]                                                                                    # A6 / C0: the 8 baselines
CLASSES = {
    'fixed': ('phaseA_b3_p2_canneal8', 'canneal8_shared', ('coalesce', 'mockingjay', 'srrip', 'srrip_bias')),
    'scaled': ('phaseA_b3_p2_canneal8_scaled', 'canneal8_scaled_shared', ('srrip', 'srrip_bias', 'mockingjay', 'ship')),
}
WINDOWS = (45_000_000, 47_500_000, 50_000_000, 52_500_000, 55_000_000)
REF_W = 50_000_000
SIM = 100_000_000


def wtag(w):
    return ('%g' % (w / 1e6)).replace('.', 'p')


def run_tree(cls, w):
    return CLASSES[cls][0] if w == REF_W else f'phaseA_b3_h3w{wtag(w)}_canneal8' + ('_scaled' if cls == 'scaled' else '')


def log_path(top, tree, pol):
    return os.path.join(top, tree, 'regime_shared', 'canneal_8core', pol, 'run.log')


# ---------------------------------------------------------------- one log
def roi_max_cycles(txt):
    i = txt.find('Region of Interest Statistics')
    if i < 0:
        return None
    c = [int(x) for x in re.findall(r'^CPU \d+ cumulative IPC: \S+ instructions: \d+ cycles: (\d+)', txt[i:], re.M)]
    return max(c) if c else None


def setting_lines(txt):
    return [ln for ln in txt.splitlines() if re.match(r'^CPU \d+ runs ', ln)]


def counter(txt, name):
    return [int(x) for x in re.findall(r'^LLC COHERENCE DIR ' + re.escape(name) + r':\s*(\d+)\s*$', txt, re.M)]


def qualify(txt, ref_txt, w, cfg_new, cfg_ref, binname):
    """'' if the run qualifies (the design's list), else why not"""
    if DONE not in txt:
        return 'did not complete'
    if re.findall(r'^Warmup Instructions: (\d+)', txt, re.M) != [str(w)]:
        return f'warmup is not {w}'
    if re.findall(r'^Simulation Instructions: (\d+)', txt, re.M) != [str(SIM)]:
        return f'simulation is not {SIM}'
    if re.findall(r'^Number of CPUs: (\d+)', txt, re.M) != ['8']:
        return 'not 8 CPUs'
    if not setting_lines(txt) or setting_lines(txt) != setting_lines(ref_txt):
        return 'its traces differ from the reference run'
    if re.findall(r'^PRIVATE-CACHE COHERENCE LEVEL: (\d+)', txt, re.M) != ['2']:
        return 'not at coherence level 2'
    if not re.search(r'^SYNC REPLAY: on\b', txt, re.M):
        return 'not SYNC REPLAY: on'
    if 'Reached end of trace' in txt:
        return 'a trace wrapped'
    if 'SYNC DEADLOCK' in txt:
        return 'SYNC DEADLOCK'
    for name in ('SELF-CHECK MISMATCHES', 'STALE-HOLDER VIOLATIONS', 'VIEW-ORDER VIOLATIONS UNEXPLAINED'):
        v = counter(txt, name)
        if not v or any(v):
            return f'{name}: {v}'
    if cfg_new is not None:
        try:
            if json.load(open(cfg_new)) != json.load(open(cfg_ref)):
                return 'its config.json differs from the reference config'
        except (OSError, ValueError) as e:
            return f'config: {e}'
    if binname is not None and binname != BIN_G6:
        return f'binary {binname}, not {BIN_G6}'
    return ''


# ---------------------------------------------------------------- the noise floor
def two_way_se(Y):
    """residual sd of the additive model on a policies x windows matrix of ln c"""
    Y = np.asarray(Y, float)
    r, c = Y.shape
    e = Y - Y.mean(axis=1, keepdims=True) - Y.mean(axis=0, keepdims=True) + Y.mean()
    return math.sqrt(float((e ** 2).sum()) / ((r - 1) * (c - 1)))


def noise(logtop, reftop, cfgdir, rows_path):
    rows = AR.load(rows_path)
    ok_all = True
    print('# H3a noise floor (h3_statistics_design_2026-11-14.md); from h3_stats.py noise')
    for cls, (reftree, cfgpfx, pols) in CLASSES.items():
        print(f'\n# class {cls}: reference {reftree}, policies {" ".join(pols)}')
        cyc, bad = {}, []
        for pol in pols:
            ref_log = log_path(reftop, reftree, pol)
            ref_txt = open(ref_log).read() if os.path.exists(ref_log) else ''
            cfg_ref = os.path.join(cfgdir, f'{cfgpfx}_{pol}.json')
            row = [r for r in rows if r['tree'] == reftree and r['pol'] == pol and r['rg'] == 'shared' and r['st'] == 'complete']
            for w in WINDOWS:
                if w == REF_W:
                    lp, txt = ref_log, ref_txt
                    why = qualify(txt, ref_txt, w, None, None, None) if txt else 'no reference log'
                    if not why and (len(row) != 1 or row[0]['max_cyc'] != roi_max_cycles(txt)):
                        why = f'parser: ROI max cycles {roi_max_cycles(txt)} against the row {row[0]["max_cyc"] if row else "missing"}'
                else:
                    lp = log_path(logtop, run_tree(cls, w), pol)
                    if not os.path.exists(lp):
                        why, txt = 'not pulled / not run', ''
                    else:
                        txt = open(lp).read()
                        b = open(lp + '.bin').read().strip() if os.path.exists(lp + '.bin') else 'none'
                        why = qualify(txt, ref_txt, w, os.path.join(os.path.dirname(lp), 'config.json'), cfg_ref, b)
                c = roi_max_cycles(txt) if not why else None
                print(f'run {cls} {w} {pol} {c if c is not None else "-"} {"ok" if not why else "NOT USED: " + why}')
                if why:
                    bad.append((w, pol, why))
                else:
                    cyc[(pol, w)] = c
        if bad:
            ok_all = False
            print(f'class {cls} NOT DECLARED ({len(bad)} of {len(pols) * len(WINDOWS)} runs not used)')
            continue
        Y = [[math.log(cyc[(p, w)]) for w in WINDOWS] for p in pols]
        se = two_way_se(Y)
        delta = T975_12 * math.sqrt(2) * se
        print(f'class {cls} se {se:.6g} delta {delta:.6g} df 12 runs {len(cyc)}')
        print(f'#   delta = {delta:.4%} in log units (about {math.expm1(delta):.3%} in cycles)')
        for a, b in itertools.combinations(pols, 2):
            g = [math.log(cyc[(a, w)] / cyc[(b, w)]) for w in WINDOWS]
            signs = ''.join('+' if x > 0 else ('-' if x < 0 else '0') for x in g)
            stable = 'yes' if len(set(signs)) == 1 and signs[0] != '0' else 'no'
            print(f'pair {cls} {a} {b} signs {signs} stable {stable} gaps ' + ' '.join(f'{x:+.5f}' for x in g))
    return 0 if ok_all else 2


def load_noise(path):
    """{class: (se, delta)} for declared classes; {(class, a, b): (signs, stable)}"""
    cl, pairs = {}, {}
    if not path:
        return cl, pairs
    for line in open(path):
        p = line.split()
        if len(p) >= 6 and p[0] == 'class' and p[2] == 'se':
            cl[p[1]] = (float(p[3]), float(p[5]))
        elif len(p) >= 8 and p[0] == 'pair':
            pairs[(p[1], p[2], p[3])] = (p[5], p[7] == 'yes')
    return cl, pairs


# ---------------------------------------------------------------- statistics
_I = {}


def pairs_idx(n):
    if n not in _I:
        _I[n] = np.triu_indices(n, 1)
    return _I[n]


def taub(x, y):
    x, y = np.asarray(x, float), np.asarray(y, float)
    I, J = pairs_idx(len(x))
    sx, sy = np.sign(x[I] - x[J]), np.sign(y[I] - y[J])
    n0 = len(I)
    den = math.sqrt((n0 - int((sx == 0).sum())) * (n0 - int((sy == 0).sum())))
    return float((sx * sy).sum()) / den if den else float('nan')


_P = {}


def perms(n):
    if n not in _P:
        _P[n] = np.array(list(itertools.permutations(range(n))), dtype=np.int16)
    return _P[n]


def exact_p(x, y):
    """two-sided p of tau_b under every assignment of y's values to the items (x held)"""
    x, y = np.asarray(x, float), np.asarray(y, float)
    n = len(x)
    I, J = pairs_idx(n)
    sx = np.sign(x[I] - x[J]).astype(np.int32)
    n0 = len(I)
    rank = np.unique(y, return_inverse=True)[1].astype(np.int16)        # ties kept, as integers
    den = math.sqrt((n0 - int((sx == 0).sum())) * (n0 - int((np.sign(y[I] - y[J]) == 0).sum())))
    if not den:
        return float('nan')
    obs = abs(taub(x, y))
    P, hits = perms(n), 0
    for k in range(0, len(P), 40320):
        Y = rank[P[k:k + 40320]]
        sy = np.sign(Y[:, I] - Y[:, J]).astype(np.int32)
        hits += int((np.abs(sy @ sx) / den >= obs - 1e-12).sum())
    return hits / len(P)


def tau_delta(la, lb, da, db):
    """(tau_delta, agree, disagree, tied in A, tied in B) with pairwise ties under da / db"""
    la, lb = np.asarray(la, float), np.asarray(lb, float)
    I, J = pairs_idx(len(la))
    ga, gb = la[I] - la[J], lb[I] - lb[J]
    sa, sb = np.abs(ga) >= da, np.abs(gb) >= db
    both = sa & sb
    agree = int((both & (np.sign(ga) == np.sign(gb))).sum())
    dis = int((both & (np.sign(ga) != np.sign(gb))).sum())
    n0 = len(I)
    ta, tb = n0 - int(sa.sum()), n0 - int(sb.sum())
    den = math.sqrt((n0 - ta) * (n0 - tb))
    return ((agree - dis) / den if den else float('nan')), agree, dis, ta, tb


def top1(la, lb, da, db, names):
    ia, ib = int(np.argmin(la)), int(np.argmin(lb))
    if da is None:
        return ia == ib, names[ia], names[ib]
    return (lb[ia] - lb[ib] < db) and (la[ib] - la[ia] < da), names[ia], names[ib]


def top3(la, lb):
    return len(set(np.argsort(la)[:3].tolist()) & set(np.argsort(lb)[:3].tolist()))


def taub_rows(X, Y):
    """tau over rows of two (draws x n) arrays without ties"""
    n = X.shape[1]
    I, J = pairs_idx(n)
    return (np.sign(X[:, I] - X[:, J]) * np.sign(Y[:, I] - Y[:, J])).sum(axis=1) / len(I)


def ceiling(la, lb, sa, sb):
    """(5th percentile of the pooled ceiling, its median, the 2.5 / 97.5 noise interval of tau(A', B'))"""
    rng = np.random.default_rng(SEED)
    la, lb = np.asarray(la, float), np.asarray(lb, float)
    n = len(la)
    A1 = la + rng.normal(0, sa, (DRAWS, n))
    A2 = la + rng.normal(0, sa, (DRAWS, n))
    B1 = lb + rng.normal(0, sb, (DRAWS, n))
    B2 = lb + rng.normal(0, sb, (DRAWS, n))
    ceil = np.concatenate([taub_rows(A1, A2), taub_rows(B1, B2)])
    iv = taub_rows(A1, B1)
    return float(np.percentile(ceil, 5)), float(np.median(ceil)), (float(np.percentile(iv, 2.5)), float(np.percentile(iv, 97.5)))


def boot_median(v):
    v = np.asarray(v, float)
    rng = np.random.default_rng(SEED)
    idx = rng.integers(0, len(v), (DRAWS, len(v)))
    med = np.median(v[idx], axis=1)
    return float(np.median(v)), float(np.percentile(med, 2.5)), float(np.percentile(med, 97.5))


# ---------------------------------------------------------------- the rankings
def rank(rows, tree, rg, wl=None, cores=None, pols=POLS):
    d = {r['pol']: r['max_cyc'] for r in rows if r['tree'] == tree and r['rg'] == rg and r['st'] == 'complete'
         and r['pol'] in pols and (wl is None or r['wl'] == wl) and (cores is None or r['cores'] == cores)}
    return d


def compare(label, A, B, ca=None, cb=None, cl=None, out=print):
    """A, B: {pol: max_cyc}; ca / cb: the classes whose delta / s_e apply (None: no tie rule).
    Returns (tau_b, the R2 label or None when no tie rule applies)."""
    names = sorted(set(A) & set(B))
    la = np.log([A[p] for p in names])
    lb = np.log([B[p] for p in names])
    t, p = taub(la, lb), exact_p(la, lb)
    beyond = 'beyond chance (p < 0.05)' if p < 0.05 else 'NOT beyond chance (p >= 0.05)'
    out(f'   {label}: tau_b {t:+.3f} over {len(names)}, exact p {p:.3g} -- {beyond}')
    use = cl is not None and ca in cl and cb in cl
    lab = None
    if (ca or cb) and not use:
        out('      no tie rule: the class\'s delta is not declared')
    if use:
        (sea, da), (seb, db) = cl[ca], cl[cb]
        td, ag, dis, ta, tb = tau_delta(la, lb, da, db)
        t1, ba, bb = top1(la, lb, da, db, names)
        q05, med, iv = ceiling(la, lb, sea, seb)
        lab = 'WITHIN NOISE' if t >= q05 else 'BELOW THE NOISE CEILING'
        out(f'      tau_delta {td:+.3f}; separated in both: {ag} agree, {dis} disagree; tied: {ta} in A, {tb} in B '
            f'(delta {da:.4%} / {db:.4%})')
        out(f'      top-1 {"agrees" if t1 else "differs"} ({ba} / {bb}, under delta); top-3 overlap {top3(la, lb)} of 3')
        out(f'      noise ceiling: median {med:+.3f}, 5th percentile {q05:+.3f}; noise interval {iv[0]:+.3f} .. {iv[1]:+.3f} -> {lab}')
    else:
        t1, ba, bb = top1(la, lb, None, None, names)
        out(f'      top-1 {"agrees" if t1 else "differs"} ({ba} / {bb}); top-3 overlap {top3(la, lb)} of 3')
    return t, lab


def score(rows_path, noise_path):
    rows = AR.load(rows_path)
    cl, pr = load_noise(noise_path)
    T = lambda s: TREE + s  # noqa: E731
    print('== H3 (h3_statistics_design_2026-11-14.md)')
    for c in ('fixed', 'scaled'):
        print(f'   class {c}: ' + (f's_e {cl[c][0]:.4%}, delta {cl[c][1]:.4%} (log units)' if c in cl else 'delta NOT DECLARED (no tie rule)'))
    SZ = (('fixed 2 MB', '', 'fixed'), ('2 MB a core', '_scaled', 'scaled'))
    res = {}

    print('\n== P11 restated (shared vs private at one size)')
    for c in (4, 8):
        for sz, suf, k in SZ:
            res[('P11', c, k)] = compare(f'canneal {c}c, {sz}', rank(rows, T(f'canneal{c}{suf}'), 'shared'),
                                         rank(rows, T(f'canneal{c}{suf}'), 'private'), k, k, cl)[1]
    print('\n== the size controls (one regime, fixed 2 MB vs 2 MB a core)')
    for wl, c in (('canneal', 4), ('canneal', 8), ('ocean', 4)):
        for rg in ('private', 'shared'):
            compare(f'{wl} {c}c, {rg}', rank(rows, T(f'{wl}{c}'), rg), rank(rows, T(f'{wl}{c}_scaled'), rg), 'fixed', 'scaled', cl)
    print('\n== P13 restated (ocean, shared vs private)')
    for sz, suf, k in SZ:
        compare(f'ocean 4c, {sz}', rank(rows, T(f'ocean4{suf}'), 'shared'), rank(rows, T(f'ocean4{suf}'), 'private'), k, k, cl)
    print('\n== P14 restated (canneal 4c fixed shared, 64 vs 16 LLC MSHRs)')
    compare('64 vs 16', rank(rows, T('canneal4_mshr64'), 'shared'), rank(rows, T('canneal4'), 'shared'), 'fixed', 'fixed', cl)

    print('\n== P12 restated (canneal fixed 2 MB: ln(1 + best gain) shared minus private)')
    for c in (4, 8):
        gs, gp = rank(rows, T(f'canneal{c}'), 'shared'), rank(rows, T(f'canneal{c}'), 'private')
        ls_ = math.log(gs['lru'] / min(gs.values()))
        lp_ = math.log(gp['lru'] / min(gp.values()))
        d = ls_ - lp_
        thr = math.sqrt(2) * cl['fixed'][1] if 'fixed' in cl else None
        print(f'   canneal {c}c: {d:+.4f} (shared {math.expm1(ls_):+.2%}, private {math.expm1(lp_):+.2%})'
              + (f'; robust if > sqrt(2) delta = {thr:.4f}: {"ROBUST" if d > thr else "NOT ROBUST"}' if thr else '; no tie rule'))

    print('\n== synchronised (step 5) vs drifting (the level-2 A5 rerun), shared')
    sd = []
    for wl, c in (('canneal', 4), ('canneal', 8), ('canneal', 16), ('ocean', 4)):
        for sz, suf, k in SZ:
            old = 'phaseA_l2_fixed' if k == 'fixed' else 'phaseA_l2_scaled'
            B = rank(rows, old, 'shared', wl, c)
            if not B:
                print(f'   {wl} {c}c, {sz}: no drifting rows')
                continue
            sd.append(compare(f'{wl} {c}c, {sz}', rank(rows, T(f'{wl}{c}{suf}'), 'shared'), B, k, k, cl)[0])
    m, lo, hi = boot_median(sd)
    print(f'   median over {len(sd)}: {m:+.3f}, bootstrap 95% {lo:+.3f} .. {hi:+.3f}')

    print('\n== A6 restated (8 baselines; drifting traces, b3v4 binary: no tie rule)')
    import a6_score as A6S
    got, bad = A6S.gather(rows)
    if bad:
        print(f'   A6 rows missing: {bad[:3]}')
    else:
        for n, sizes in A6S.SIZES.items():
            hr = {(s, rg): AR.load_rfo_hit(got[(n, s, rg)]['lru']) * 100 for s in sizes for rg in ('shared', 'private')}
            M, C = [], []
            for s in (1, 2, 4):
                a, b = got[(n, s, 'shared')], got[(n, n * s, 'private')]
                counted = abs(hr[(s, 'shared')] - hr[(n * s, 'private')]) <= A6S.PRESSURE_PTS
                t = compare(f'{n}c matched shared {s} vs private {n * s}' + ('' if counted else ' (not counted by A6: pressure)'),
                            {p: r['max_cyc'] for p, r in a.items()}, {p: r['max_cyc'] for p, r in b.items()})[0]
                if counted:
                    M.append(t)
            for rg in ('private', 'shared'):
                for s in (1, 2, 4):
                    if (n, n * s, rg) in got:
                        C.append(compare(f'{n}c control {rg} {s} vs {n * s}', {p: r['max_cyc'] for p, r in got[(n, s, rg)].items()},
                                         {p: r['max_cyc'] for p, r in got[(n, n * s, rg)].items()})[0])
            for nm, v in (('matched (counted)', M), ('controls', C)):
                if v:
                    m, lo, hi = boot_median(v)
                    print(f'   {n}c {nm}: median {m:+.3f} over {len(v)}, bootstrap 95% {lo:+.3f} .. {hi:+.3f}')

    print('\n== C0 restated (invalidation latency L against 0; level-2 drifting; 8 baselines; no tie rule)')
    for L in (20, 50, 100):
        for wl, c in (('canneal', 4), ('canneal', 8), ('ocean', 4)):
            A = rank(rows, f'phaseA_l2_c0_{L}c', 'shared', wl, c, BASE8)
            B = rank(rows, 'phaseA_l2_fixed', 'shared', wl, c, BASE8)
            if A and B:
                compare(f'L {L}: {wl} {c}c', A, B)
            else:
                print(f'   L {L}: {wl} {c}c: rows missing')

    print('\n== R1: COALESCE\'s place (fixed 2 MB, shared)')
    for c in (8, 16):
        d = rank(rows, T(f'canneal{c}'), 'shared')
        o = sorted(d, key=d.get)
        lc = {p: math.log(d[p]) for p in d}
        first = o[0]
        gap = lc[o[1]] - lc[first]
        print(f'   canneal {c}c: 1st {first}, 2nd {o[1]} at {math.expm1(gap):+.2%}')
        if 'fixed' not in cl:
            print('      no tie rule: delta_fixed not declared')
            continue
        dl = cl['fixed'][1]
        tied = [p for p in o[1:] if lc[p] - lc[first] < dl]
        ok = gap >= dl
        if c == 8 and first == 'coalesce':
            key = ('fixed', 'coalesce', o[1]) if ('fixed', 'coalesce', o[1]) in pr else ('fixed', o[1], 'coalesce')
            sg = pr.get(key)
            if sg is None:
                ok, why = False, f'no window table for coalesce / {o[1]}'
            else:
                ok, why = ok and sg[1], f'signs over the 5 windows {sg[0]} ({"stable" if sg[1] else "NOT stable"})'
            print(f'      {why}')
        verdict = f'"{first} is 1st"' if ok else f'"tied for first: {", ".join([first] + tied) if tied else first + " (sign not stable)"}"'
        print(f'      gap {gap:.4%} vs delta {dl:.4%} -> the paper writes {verdict}')

    print('\n== R4: P11\'s explanation at 2 MB a core')
    labs = [res[('P11', c, 'scaled')] for c in (4, 8)]
    if 'scaled' not in cl:
        print('   not decided: delta_scaled not declared')
    else:
        sup = all(x == 'WITHIN NOISE' for x in labs)
        print(f'   canneal 4c / 8c at 2 MB a core read {labs[0]} / {labs[1]} -> '
              + ('SUPPORTED: the sentence stays' if sup else 'NOT SUPPORTED: the sentence is withdrawn; the failure stands without that explanation'))
    return 0


# ---------------------------------------------------------------- selftest
def selftest():
    ok = True

    def check(name, cond):
        nonlocal ok
        print(f'   {"ok  " if cond else "FAIL"} {name}')
        ok = ok and bool(cond)

    x = np.arange(9.0)
    y = x.copy()
    # 8 discordant pairs: tau = 20/36
    y = np.array([1, 0, 3, 2, 5, 4, 7, 6, 8.0])                 # 4 swaps -> 4 discordant
    check('tau_b of 4 adjacent swaps over 9 = 28/36', abs(taub(x, y) - 28 / 36) < 1e-12)
    y8 = np.array([2, 1, 0, 5, 4, 3, 6, 7, 8.0])                 # two reversed triples: 3 + 3 discordant = 6
    check('tau_b of two reversed triples = 24/36', abs(taub(x, y8) - 24 / 36) < 1e-12)
    yd = np.array([3, 1, 2, 0, 4, 5, 8, 6, 7.0])
    nd = sum(1 for i in range(9) for j in range(i + 1, 9) if (yd[i] - yd[j]) * (x[i] - x[j]) < 0)
    check(f'tau_b by brute force ({nd} discordant)', abs(taub(x, yd) - (36 - 2 * nd) / 36) < 1e-12)
    # exact p, no ties: tau 20/36 -> 0.0446 (the research report); 10/36 -> one-sided 0.179
    y20 = None
    for cand in itertools.permutations(range(9)):
        if abs(taub(x, np.array(cand, float)) - 20 / 36) < 1e-12:
            y20 = np.array(cand, float)
            break
    p20 = exact_p(x, y20)
    check(f'exact p at tau 20/36 = 0.0446 (got {p20:.4f})', abs(p20 - 0.0446) < 5e-5)
    y10 = next(np.array(c, float) for c in itertools.permutations(range(9)) if abs(taub(x, np.array(c, float)) - 10 / 36) < 1e-12)
    p10 = exact_p(x, y10)
    check(f'exact p at tau 10/36: two-sided {p10:.4f} = 2 x one-sided 0.179', abs(p10 / 2 - 0.179) < 5e-4)
    check('exact p of identical orders = 2 / 9!', abs(exact_p(x, x) - 2 / 362880) < 1e-15)
    # ties: tau_b against a brute-force enumeration on 6 items
    a6 = np.array([1, 1, 2, 3, 3, 4.0])
    b6 = np.array([2, 1, 1, 4, 3, 3.0])
    tb = taub(a6, b6)
    I, J = np.triu_indices(6, 1)
    nc = sum(1 for i, j in zip(I, J) if (a6[i] - a6[j]) * (b6[i] - b6[j]) > 0)
    nd = sum(1 for i, j in zip(I, J) if (a6[i] - a6[j]) * (b6[i] - b6[j]) < 0)
    t1 = sum(1 for i, j in zip(I, J) if a6[i] == a6[j])
    t2 = sum(1 for i, j in zip(I, J) if b6[i] == b6[j])
    check('tau_b with ties = (nc - nd) / sqrt((n0 - t1)(n0 - t2))', abs(tb - (nc - nd) / math.sqrt((15 - t1) * (15 - t2))) < 1e-12)
    cnt = sum(1 for pm in itertools.permutations(range(6)) if abs(taub(a6, b6[list(pm)])) >= abs(tb) - 1e-12)
    check('exact p with ties = brute force over 6!', abs(exact_p(a6, b6) - cnt / 720) < 1e-12)
    # the two-way model: an exact additive table has s_e 0; one perturbed cell gives the hand value
    Y = np.add.outer([0.0, 0.01, 0.02, 0.03], [0.0, -0.02, 0.05, 0.01, 0.0])
    check('two-way s_e of an additive table = 0', two_way_se(Y) < 1e-12)
    Y2 = Y.copy()
    Y2[1, 2] += 0.012
    # one cell +h: residuals h(1 - 1/r)(1 - 1/c) at it; sum of squares h^2 (r-1)(c-1)/(rc)
    h, r, c = 0.012, 4, 5
    check('two-way s_e with one perturbed cell = h / sqrt(r c)', abs(two_way_se(Y2) - h / math.sqrt(r * c)) < 1e-12)
    # tau_delta: A = 0, 0.001, 0.010, 0.020; B = 0.0005, 0, 0.020, 0.010 (ln); delta 0.005
    la, lb = np.array([0, 0.001, 0.010, 0.020]), np.array([0.0005, 0, 0.020, 0.010])
    td, ag, dis, ta, tb_ = tau_delta(la, lb, 0.005, 0.005)
    # separated in A: (0,2)(0,3)(1,2)(1,3)(2,3); in B: (0,2)(0,3)(1,2)(1,3)(2,3); (2,3) disagrees
    check(f'tau_delta: 4 agree, 1 disagree, 1 tied each ({ag}, {dis}, {ta}, {tb_})', (ag, dis, ta, tb_) == (4, 1, 1, 1))
    check('tau_delta = 3/5', abs(td - 3 / 5) < 1e-12)
    t1v, ba, bb = top1(la, lb, 0.005, 0.005, list('abcd'))
    check('top-1 under delta: a and b within delta -> agrees', t1v and (ba, bb) == ('a', 'b'))
    t1n, _, _ = top1(la, lb, None, None, list('abcd'))
    check('top-1 without delta: a vs b -> differs', not t1n)
    check('top-3 overlap: {a, b, c} and {b, a, d} share 2', top3(la, lb) == 2)
    # the draws are reproducible
    c1 = ceiling(np.arange(9) * 0.01, np.arange(9) * 0.01, 0.002, 0.002)
    c2 = ceiling(np.arange(9) * 0.01, np.arange(9) * 0.01, 0.002, 0.002)
    check('ceiling: the same seed gives the same numbers', c1 == c2)
    c3 = ceiling(np.arange(9) * 0.0001, np.arange(9) * 0.0001, 0.002, 0.002)
    check(f'ceiling: gaps far below the noise put the 5th percentile near 0 ({c3[0]:+.3f}) and far above it at 1 ({c1[0]:+.3f})',
          c3[0] < 0.2 and c1[0] == 1.0)
    m, lo, hi = boot_median([0.5, 0.6, 0.7, 0.8, 0.9])
    check('bootstrap median: the median, an interval around it', m == 0.7 and lo <= 0.7 <= hi)
    # qualify: a made-up log
    ref = 'CPU 0 runs a\nCPU 1 runs b\n'
    good = (f'Warmup Instructions: 45000000\nSimulation Instructions: 100000000\nNumber of CPUs: 8\n{ref}'
            'PRIVATE-CACHE COHERENCE LEVEL: 2\nSYNC REPLAY: on (8 threads)\n'
            'LLC COHERENCE DIR SELF-CHECK MISMATCHES:          0\nLLC COHERENCE DIR STALE-HOLDER VIOLATIONS:          0\n'
            'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:          0\nChampSim completed all CPUs\n'
            'Region of Interest Statistics\n\nCPU 0 cumulative IPC: 0.5 instructions: 100000001 cycles: 200\n'
            'CPU 1 cumulative IPC: 0.5 instructions: 100000001 cycles: 210\n')
    check('qualify: a good log', qualify(good, ref, 45_000_000, None, None, BIN_G6) == '')
    check('ROI max cycles = the largest CPU line', roi_max_cycles(good) == 210)
    for nm, bad_txt, w in (('another warmup', good, 47_500_000),
                           ('a wrapped trace', good + 'Reached end of trace\n', 45_000_000),
                           ('a deadlock', good + 'SYNC DEADLOCK\n', 45_000_000),
                           ('other traces', good.replace('runs b', 'runs c'), 45_000_000),
                           ('level 0', good.replace('LEVEL: 2', 'LEVEL: 0'), 45_000_000),
                           ('an unexplained violation', good.replace('UNEXPLAINED:          0', 'UNEXPLAINED:          2'), 45_000_000),
                           ('incomplete', good.replace('ChampSim completed all CPUs', ''), 45_000_000)):
        check(f'qualify refuses {nm}', qualify(bad_txt, ref, w, None, None, BIN_G6) != '')
    check('qualify refuses another binary', qualify(good, ref, 45_000_000, None, None, 'champsim_fc_a2e88e46') != '')
    print('SELF-TEST PASSES' if ok else 'SELF-TEST FAILS')
    return ok


def main(a):
    if a[:1] == ['noise'] and len(a) == 4:
        return noise(a[1], a[2], a[3], os.environ.get('H3_ROWS', os.path.join(ROOT, 'bench/policy_sanity/phasea_rows_v29.txt')))
    if a[:1] == ['score'] and len(a) in (2, 3):
        return score(a[1], a[2] if len(a) == 3 else None)
    if a == ['selftest']:
        return 0 if selftest() else 1
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
