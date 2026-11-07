#!/usr/bin/env python3
"""Validation round, 2026-10-17: the policy-ranking numbers recomputed.

    scripts/verify_rankings.py ROWS            # a phasea_rows_vN.txt
    scripts/verify_rankings.py --logs LOGS_ROOT ROWS   # also check every row against its raw log

Written for this round, without reusing analyze_rows.py. It checks:
  1. rows that must be identical are (the same run on two binaries, a
     control re-run, a configuration two trees share);
  2. every Kendall tau and LRU gain the documents state for A5, C0 and the
     16-core repeat, recomputed by brute force over all pairs;
  3. with --logs: every row's numbers against its raw run.log, parsed here.
Rows: variant policy workload cores regime status vmem wrap max_cycles
min_cycles instrs llc_load_acc llc_load_hit llc_total_acc llc_total_hit
llc_write_acc llc_write_hit llc_rfo_acc llc_rfo_hit llc_tr_acc llc_tr_hit
aliased_fills invals
"""
import itertools
import os
import re
import sys

COLS = ('variant policy workload cores regime status vmem wrap max_cycles min_cycles instrs '
        'llc_load_acc llc_load_hit llc_total_acc llc_total_hit llc_write_acc llc_write_hit '
        'llc_rfo_acc llc_rfo_hit llc_tr_acc llc_tr_hit aliased_fills invals').split()
B8 = ['lru', 'srrip', 'drrip', 'ship', 'hawkeye', 'mockingjay', 'srrip_bias', 'random']


def load(path):
    rows = {}
    for line in open(path):
        p = line.split()
        if len(p) != len(COLS):
            continue
        r = dict(zip(COLS, p))
        for k in COLS[8:]:
            r[k] = int(r[k])
        r['cores'] = int(r['cores'])
        key = (r['variant'], r['policy'], r['workload'], r['cores'], r['regime'])
        if key in rows:
            print(f'DUPLICATE ROW {key}')
        rows[key] = r
    return rows


def get(rows, tree, pol, wl, n, rg):
    r = rows.get((tree, pol, wl, n, rg))
    if r is None or r['status'] != 'complete' or r['vmem'] != 'ok' or r['wrap'] != 'ok':
        return None
    return r


def tau(a, b):
    """Kendall tau-a between two {policy: cycles} maps over their common keys."""
    ks = sorted(set(a) & set(b))
    c = d = t = 0
    for x, y in itertools.combinations(ks, 2):
        s = (a[x] - a[y]) * (b[x] - b[y])
        if s > 0:
            c += 1
        elif s < 0:
            d += 1
        else:
            t += 1
    n = len(ks) * (len(ks) - 1) // 2
    return (c - d) / n if n else float('nan'), len(ks), t


def cycles(rows, spec, wl, n, rg, pols=B8):
    """spec: a tree name, or {policy: tree} with a 'default' entry."""
    out = {}
    for p in pols:
        tree = spec.get(p, spec['default']) if isinstance(spec, dict) else spec
        r = get(rows, tree, p, wl, n, rg)
        if r:
            out[p] = r['max_cycles']
    return out


PRIV_SCALED = {'default': 'phaseA_scaled_private', 'lru': 'phaseA_scaled'}

# (label, spec A, regime A, spec B, regime B, workload, {cores: stated tau})
TAUS = [
    ('A5 cross-regime pressure-matched, L0', 'phaseA', 'shared', PRIV_SCALED, 'private', 'canneal', {4: .57, 8: .29, 16: .29}),
    ('A5 cross-regime pressure-matched, L2', 'phaseA_l2_fixed', 'shared', PRIV_SCALED, 'private', 'canneal', {4: .57, 8: .29, 16: .29}),
    ('A5 private 2MB vs private 2MB/core', 'phaseA', 'private', PRIV_SCALED, 'private', 'canneal', {4: .43, 8: .29, 16: .36}),
    ('A5 same size 2MB, L0', 'phaseA', 'shared', 'phaseA', 'private', 'canneal', {4: .86, 8: .71, 16: .64}),
    ('A5 same size 2MB, L2', 'phaseA_l2_fixed', 'shared', 'phaseA', 'private', 'canneal', {4: .86, 8: .71, 16: .64}),
    ('A5 same size 2MB/core, L0', 'phaseA_scaled', 'shared', PRIV_SCALED, 'private', 'canneal', {4: .29, 8: .14, 16: .29}),
    ('A5 same size 2MB/core, L2', 'phaseA_l2_scaled', 'shared', PRIV_SCALED, 'private', 'canneal', {4: .29, 8: .14, 16: .57}),
    ('A5 shared 2MB vs 2MB/core, L2', 'phaseA_l2_fixed', 'shared', 'phaseA_l2_scaled', 'shared', 'canneal', {16: .14}),
    ('C0 L=20 vs L=0', 'phaseA_l2_c0_20c', 'shared', 'phaseA_l2_fixed', 'shared', 'canneal', {4: 1.0, 8: 1.0}),
    ('C0 L=50 vs L=0', 'phaseA_l2_c0_50c', 'shared', 'phaseA_l2_fixed', 'shared', 'canneal', {4: 1.0, 8: 1.0}),
    ('C0 L=100 vs L=0', 'phaseA_l2_c0_100c', 'shared', 'phaseA_l2_fixed', 'shared', 'canneal', {4: 1.0, 8: 1.0}),
    ('C0 L=20 vs L=0, ocean', 'phaseA_l2_c0_20c', 'shared', 'phaseA_l2_fixed', 'shared', 'ocean', {4: .93}),
    ('C0 L=50 vs L=0, ocean', 'phaseA_l2_c0_50c', 'shared', 'phaseA_l2_fixed', 'shared', 'ocean', {4: .93}),
    ('C0 L=100 vs L=0, ocean', 'phaseA_l2_c0_100c', 'shared', 'phaseA_l2_fixed', 'shared', 'ocean', {4: .93}),
]

# Rows that must be identical in every column the binaries share.
SAME_COLS = ['max_cycles', 'instrs', 'llc_total_acc', 'llc_total_hit', 'llc_write_acc', 'llc_write_hit', 'llc_tr_acc', 'llc_tr_hit',
             'aliased_fills']
IDENT = [
    # level 0 old binary vs the level-2 binary, private regime (Q1: private is the same at every level; step 1 is timing-neutral)
    *[(('phaseA', 'lru', 'canneal', n, 'private'), ('phaseA_l2_fixed', 'lru', 'canneal', n, 'private'), 'private LRU 2 MB, old binary vs b3v4') for n in (4, 8, 16)],
    *[(('phaseA_scaled', 'lru', 'canneal', n, 'private'), ('phaseA_l2_scaled', 'lru', 'canneal', n, 'private'), 'private LRU 2 MB/core, old binary vs b3v4') for n in (4, 8, 16)],
    # A6 Q0: its private 4c rows at 2 and 8 MB stand in for the old rows
    (('phaseA', 'hawkeye', 'canneal', 4, 'private'), ('phaseA_l2_a6_2mb', 'hawkeye', 'canneal', 4, 'private'), 'A6 Q0 hawkeye 2MB'),
    (('phaseA', 'srrip_bias', 'canneal', 4, 'private'), ('phaseA_l2_a6_2mb', 'srrip_bias', 'canneal', 4, 'private'), 'A6 Q0 srrip_bias 2MB'),
    (('phaseA_scaled_private', 'hawkeye', 'canneal', 4, 'private'), ('phaseA_l2_a6_8mb', 'hawkeye', 'canneal', 4, 'private'), 'A6 Q0 hawkeye 8MB'),
    (('phaseA_scaled_private', 'srrip_bias', 'canneal', 4, 'private'), ('phaseA_l2_a6_8mb', 'srrip_bias', 'canneal', 4, 'private'), 'A6 Q0 srrip_bias 8MB'),
    # B3 canneal 8c Q3: the level-2 shared row equals the A5 rerun's
    (('phaseA_l2_fixed', 'lru', 'canneal', 8, 'shared'), ('phaseA_b3_e2_canneal8', 'lru', 'canneal', 8, 'shared'), 'B3 canneal8 Q3'),
    # A6 at 2 MB/core for 8c is 16 MB; at 8c, 2 MB fixed vs A6? (none). A6 8c at 4 MB vs nothing.
]

GAINS = [  # (label, tree spec, regime, cores, {policy: stated % gain over LRU})
    ('private 2MB 8c', 'phaseA', 'private', 8, {'srrip': 3.21, 'hawkeye': 2.88}),
    ('private 2MB 16c', 'phaseA', 'private', 16, {'srrip': 1.66, 'hawkeye': 1.49}),
    ('private 2MB/core 8c', PRIV_SCALED, 'private', 8, {'hawkeye': 9.78, 'srrip': 1.98}),
    ('private 2MB/core 16c', PRIV_SCALED, 'private', 16, {'hawkeye': 9.95, 'srrip': 3.15}),
    ('shared 2MB L0 8c', 'phaseA', 'shared', 8, {'srrip': 12.69, 'hawkeye': 12.07}),
    ('shared 2MB L2 8c', 'phaseA_l2_fixed', 'shared', 8, {'srrip': 12.72, 'hawkeye': 11.91}),
    ('shared 2MB L0 16c', 'phaseA', 'shared', 16, {'srrip': 14.67, 'hawkeye': 11.34}),
    ('shared 2MB L2 16c', 'phaseA_l2_fixed', 'shared', 16, {'srrip': 14.00, 'hawkeye': 10.95}),
    ('private 2MB 4c best', 'phaseA', 'private', 4, {'mockingjay': 9.47}),
    ('private 2MB 8c best', 'phaseA', 'private', 8, {'mockingjay': 3.22}),
    ('private 2MB 16c best', 'phaseA', 'private', 16, {'mockingjay': 1.95}),
    ('shared 2MB L0 4c best', 'phaseA', 'shared', 4, {'mockingjay': 14.44}),
    ('private 2MB srrip_bias', 'phaseA', 'private', 4, {'srrip_bias': 2.69}),
    ('private 2MB/core srrip_bias 4c', PRIV_SCALED, 'private', 4, {'srrip_bias': -5.10}),
]


def parse_log(path):
    """The rows' columns, from a raw run.log, parsed independently of run_phase_a.sh."""
    out = dict.fromkeys(COLS[8:], 0)
    mc, mn, ins = [], [], 0
    roi = False
    complete = vm = wrap = False
    with open(path, errors='replace') as fh:
        for line in fh:
            if line.startswith('Region of Interest Statistics'):
                roi = True
            m = re.match(r'Simulation complete CPU \d+ instructions: (\d+) cycles: (\d+)', line)
            if m:
                ins += int(m.group(1))
                mc.append(int(m.group(2)))
            complete |= 'ChampSim completed all CPUs' in line
            vm |= 'Out of physical memory' in line
            wrap |= 'Reached end of trace' in line
            if line.startswith('VMEM ALIASED FILLS') and not out['aliased_fills']:
                out['aliased_fills'] = int(line.split()[-1])
            if line.startswith('LLC COHERENCE INVALIDATIONS') and not out.get('_inv'):
                out['invals'] = int(line.split()[-1])
                out['_inv'] = 1
            if roi:
                m = re.match(r'cpu\d+->LLC (LOAD|TOTAL|WRITE|RFO|TRANSLATION)\s+ACCESS:\s+(\d+)\s+HIT:\s+(\d+)', line)
                if m:
                    k = {'LOAD': 'load', 'TOTAL': 'total', 'WRITE': 'write', 'RFO': 'rfo', 'TRANSLATION': 'tr'}[m.group(1)]
                    out[f'llc_{k}_acc'] += int(m.group(2))
                    out[f'llc_{k}_hit'] += int(m.group(3))
    out.pop('_inv', None)
    out['max_cycles'] = max(mc) if mc else 0
    out['min_cycles'] = min(mc) if mc else 0
    out['instrs'] = ins
    out['status'] = 'complete' if complete else 'INCOMPLETE'
    out['vmem'] = 'EXHAUSTED' if vm else 'ok'
    out['wrap'] = 'LOOPED' if wrap else 'ok'
    return out


def main():
    args = sys.argv[1:]
    logs = None
    if args[:1] == ['--logs']:
        logs, args = args[1], args[2:]
    rows = load(args[0])
    bad = 0

    print('== 1. rows that must be identical ==')
    for ka, kb, label in IDENT:
        a, b = rows.get(ka), rows.get(kb)
        if not a or not b:
            print(f'   MISSING   {label}: {ka if not a else kb}')
            continue
        diff = [c for c in SAME_COLS if a[c] != b[c]]
        lr = lambda r: r['llc_load_acc'] + r['llc_rfo_acc'], lambda r: r['llc_load_hit'] + r['llc_rfo_hit']
        if lr[0](a) != lr[0](b) or lr[1](a) != lr[1](b):
            diff.append('load+rfo')
        print(f'   {"same     " if not diff else "DIFFERENT"} {label}{"" if not diff else "  " + str(diff)}')
        bad += bool(diff)

    print()
    print('== 2a. Kendall tau, 8 baselines, by max_cycles ==')
    for label, sa, ra, sb, rb, wl, stated in TAUS:
        for n in (4, 8, 16):
            ca, cb = cycles(rows, sa, wl, n, ra), cycles(rows, sb, wl, n, rb)
            if not ca or not cb:
                if n in stated:
                    print(f'   {label:42s} {n:2d}c  no rows')
                continue
            t, k, ties = tau(ca, cb)
            st = stated.get(n)
            flag = '' if st is None or abs(t - st) < 0.006 else '  <-- DIFFERS'
            bad += bool(flag)
            print(f'   {label:42s} {n:2d}c  tau {t:+.3f} over {k} policies{" (" + str(ties) + " tied)" if ties else ""}'
                  f'   stated {("%+.2f" % st) if st is not None else "-"}{flag}')

    print()
    print('== 2b. gain over LRU, max_cycles (two definitions) ==')
    for label, spec, rg, n, stated in GAINS:
        c = cycles(rows, spec, 'canneal', n, rg)
        if 'lru' not in c:
            print(f'   {label}: no LRU row')
            continue
        for p, st in stated.items():
            if p not in c:
                print(f'   {label}: no {p} row')
                continue
            speed = (c['lru'] / c[p] - 1) * 100       # LRU cycles / policy cycles
            saved = (c['lru'] - c[p]) / c['lru'] * 100  # cycles saved
            ok = abs(speed - st) < 0.006 or abs(saved - st) < 0.006
            bad += not ok
            print(f'   {label:32s} {p:11s} speedup {speed:+6.2f}  saved {saved:+6.2f}   stated {st:+.2f}'
                  f'{"" if ok else "  <-- DIFFERS"}{"  (= speedup)" if abs(speed - st) < .006 else ("  (= saved)" if abs(saved - st) < .006 else "")}')

    print()
    print('== 2c. C0: LRU slower at L, and the order ==')
    for wl, n in (('canneal', 4), ('canneal', 8), ('ocean', 4)):
        base = get(rows, 'phaseA_l2_fixed', 'lru', wl, n, 'shared')
        for L in (20, 50, 100):
            r = get(rows, f'phaseA_l2_c0_{L}c', 'lru', wl, n, 'shared')
            if base and r:
                print(f'   {wl} {n}c L={L:3d}: LRU {base["max_cycles"]:,} -> {r["max_cycles"]:,} ({(r["max_cycles"] / base["max_cycles"] - 1) * 100:+.2f}%)')

    if logs:
        print()
        print('== 3. every row against its raw log ==')
        n = d = missing = 0
        for key, r in sorted(rows.items()):
            tree, pol, wl, cores, rg = key
            lp = os.path.join(logs, tree, f'regime_{rg}', f'{wl}_{cores}core', pol, 'run.log')
            if not os.path.exists(lp):
                missing += 1
                continue
            n += 1
            x = parse_log(lp)
            diff = [c for c in COLS[5:] if c in x and x[c] != r[c]]
            if diff:
                d += 1
                if d <= 30:
                    print(f'   DIFFERS {key}: ' + ', '.join(f'{c} row={r[c]} log={x[c]}' for c in diff[:6]))
        print(f'   {n} rows checked against their logs, {d} differ, {missing} logs not found')
        bad += d
    print()
    print(f'{bad} problem(s)')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
