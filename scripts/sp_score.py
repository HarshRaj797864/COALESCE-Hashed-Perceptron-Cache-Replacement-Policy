#!/usr/bin/env python3
"""Score the published SRRIP row (bench/policy_sanity/srrip_pub_design_2026-11-18.md).
Written 2026-11-18, before any srrip_pub run of it exists and before any of its numbers was read.

    python3 scripts/sp_score.py selftest
    python3 scripts/sp_score.py parser [ROWS]   # the log parser on step 5's 19 srrip logs against the committed rows
    python3 scripts/sp_score.py score  [ROWS]   # the gates, then the report fixed in the note

ROWS defaults to bench/policy_sanity/phasea_rows_v30.txt (step 5 of record = the p2 trees, 171 complete).

Inputs (pulled; nothing is fetched):
  simulator/results/sp/QS0_PASSED          (scripts/sp_all.sh pull)
  simulator/results/sp/logs/phaseA_b3_sp_<suffix>/regime_<rg>/<wl>_<n>core/srrip_pub/run.log
  simulator/results/sp/cfg/<suffix>_<rg>_srrip_pub.json  (LLC.replacement must read srrip_pub)
  simulator/results/policy/logs/phaseA_b3_p2_*/.../srrip/run.log  (the references, step 5's srrip logs)

The parser reads a log as run_phase_a.sh's rows do: max_cyc = the largest "Simulation complete
CPU n instructions: X cycles: Y"; ins = the sum of X; LLC misses = the Region of Interest's
cpuN->LLC TOTAL ACCESS minus HIT. Before anything is read it must reproduce the committed rows
(max_cyc, ins, tot_acc, tot_hit) of step 5's 19 srrip logs exactly.

Gates: QS0 recorded as passed; each run: QS1 recomputed (complete, one SRRIP_PUB FILLS line, its
fills n > 0 and all at RRPV 2, unexplained view-order violations 0), no trace wrap, its warm-up,
length, CPU count and traces equal to its reference's, its config's LLC.replacement srrip_pub.

The report (the note, "What is reported", fixed):
  - each of the 19 configurations: max cycles of srrip_pub, srrip and LRU; srrip_pub against
    srrip and against LRU in %; LLC misses of the three
  - sensitivity: each ranked tree (barnes is not ranked, step 5's amendment 1) with srrip_pub in
    srrip's place, Kendall tau against the ranking of record; P11's shared-against-private tau
    likewise; whether any of P11-P14's verdicts would change
  - the probe's expectations, reported, not gating: ocean 4c 2 MB a core shared, srrip_pub within
    5% of LRU; canneal 4c, srrip_pub within 2% of srrip
Step 5's verdicts and rankings of record are unchanged by anything printed here.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import analyze_rows as AR   # noqa: E402

ROOT = os.path.dirname(HERE)
ROWS = os.path.join(ROOT, 'bench/policy_sanity/phasea_rows_v30.txt')
SP = os.path.join(ROOT, 'simulator/results/sp')
REFLOGS = os.path.join(ROOT, 'simulator/results/policy/logs')
P2, SPT = 'phaseA_b3_p2_', 'phaseA_b3_sp_'
DONE = 'ChampSim completed all CPUs'
FILLS = re.compile(r'^SRRIP_PUB FILLS: (\d+) LEFT AT RRPV 2: (\d+)\s*$', re.M)
COMPLETE = re.compile(r'Simulation complete CPU \d+ instructions: (\d+) cycles: (\d+)')


def parse(txt):
    """{max_cyc, ins, tot_acc, tot_hit} as run_phase_a.sh's rows read them"""
    cyc, ins = [], 0
    for ln in txt.splitlines():
        m = COMPLETE.search(ln)
        if m:
            ins += int(m.group(1))
            cyc.append(int(m.group(2)))
    acc = hit = 0
    roi = False
    for ln in txt.splitlines():
        if 'Region of Interest' in ln:
            roi = True
        if roi and re.match(r'cpu[0-9]+->LLC TOTAL', ln):
            p = ln.split()
            acc += int(p[p.index('ACCESS:') + 1])
            hit += int(p[p.index('HIT:') + 1])
    return {'max_cyc': max(cyc) if cyc else None, 'ins': ins, 'tot_acc': acc, 'tot_hit': hit}


def settings(txt):
    keep = r'^(Warmup Instructions:|Simulation Instructions:|Number of CPUs:|CPU \d+ runs )'
    return [ln for ln in txt.splitlines() if re.match(keep, ln)]


def qs1(ref_txt, txt):
    """'' if the run holds QS1 and runs its reference's window and traces, else why not"""
    if DONE not in txt:
        return 'not complete'
    f = FILLS.findall(txt)
    if len(f) != 1:
        return f'{len(f)} SRRIP_PUB FILLS lines, not 1'
    n, k = map(int, f[0])
    if n <= 0 or n != k:
        return f'fills {n}, at RRPV 2 {k}'
    un = [int(x) for x in re.findall(r'^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:.*?(\d+)\s*$', txt, re.M)]
    if not un or sum(un):
        return f'unexplained view-order violations {un}'
    if 'Reached end of trace' in txt:
        return 'a trace wrapped'
    if not settings(txt) or settings(txt) != settings(ref_txt):
        return "its warm-up, length, CPU count or traces differ from its reference's"
    return ''


def jobs():
    import policy_score as P
    return [j for j in P.jobs() if j[4] == 'srrip' and j[0].startswith(P2)]


def ref_log(tree, wl, cores, rg):
    return os.path.join(REFLOGS, tree, f'regime_{rg}', f'{wl}_{cores}core', 'srrip', 'run.log')


def sp_log(tree, wl, cores, rg):
    return os.path.join(SP, 'logs', SPT + tree[len(P2):], f'regime_{rg}', f'{wl}_{cores}core', 'srrip_pub', 'run.log')


def sp_cfg(tree, rg):
    return os.path.join(SP, 'cfg', f'{tree[len(P2):]}_{rg}_srrip_pub.json')


def key(r):
    return (r['tree'], r['rg'], r['wl'], r['cores'], r['pol'])


def parser_check(rows, verbose=True):
    R = {key(r): r for r in rows}
    bad = 0
    for tree, wl, c, rg, pol, _ in jobs():
        got = parse(open(ref_log(tree, wl, c, rg)).read())
        r = R[(tree, rg, wl, c, 'srrip')]
        diff = {k: (got[k], r[k]) for k in got if got[k] != r[k]}
        bad += bool(diff)
        if verbose or diff:
            print(f'   parser {tree} {rg}: ' + ('equals the rows' if not diff else f'DIFFERS {diff}'))
    print(f'   parser check: {len(jobs()) - bad} of {len(jobs())} step 5 srrip logs reproduce the committed rows'
          + ('' if not bad else ' -- NOTHING IS READ'))
    return bad == 0


def substitute(rows, sp):
    """the rows with each p2 srrip row's numbers replaced by srrip_pub's (the policy keeps the
    name srrip, so step 5's own ranking code reads it in srrip's place)"""
    out = []
    for r in rows:
        k = (r['tree'], r['rg'], r['wl'], r['cores'])
        if r['pol'] == 'srrip' and k in sp:
            r = dict(r, **{f: sp[k][f] for f in ('max_cyc', 'ins', 'tot_acc', 'tot_hit')})
        out.append(r)
    return out


def ranked_trees():
    import policy_score as P
    seen = []
    for tree, wl, c, rg, pol, _ in P.jobs():
        if tree.startswith(P2) and 'barnesstd' not in tree and (tree, rg) not in seen:
            seen.append((tree, rg))
    return seen


def sensitivity(rows, rows_sub):
    """[(tree, rg, tau, n)] each ranked tree's order of record against srrip_pub's in srrip's place"""
    import policy_score as P
    out = []
    for tree, rg in ranked_trees():
        _, oa = P.order(rows, tree, rg)
        _, ob = P.order(rows_sub, tree, rg)
        out.append((tree, rg, AR.kendall_tau(oa, ob), len(oa)))
    return out


def gates():
    return '' if os.path.isfile(os.path.join(SP, 'QS0_PASSED')) else 'QS0 not passed (or not pulled)'


def score(rowsfile):
    import policy_score as P
    rows = AR.load(rowsfile)
    p2 = [r for r in rows if r['tree'].startswith(P2)]
    if len(p2) != 171 or any(r['st'] != 'complete' for r in p2):
        sys.exit(f'{rowsfile}: {len(p2)} p2 rows, not 171 complete')
    print('== The published SRRIP row (srrip_pub_design_2026-11-18.md), against step 5 of record (p2)')
    print('== the parser, on step 5\'s srrip logs')
    if not parser_check(rows, verbose=False):
        return 1
    g = gates()
    if g:
        print(f'   NOT SCORED: {g}')
        return 1
    print('   QS0: recorded as passed')
    R = {key(r): r for r in rows}
    sp, bad = {}, 0
    for tree, wl, c, rg, _, _ in jobs():
        f = sp_log(tree, wl, c, rg)
        if not os.path.exists(f):
            print(f'   {tree} {rg}: NO RUN pulled ({os.path.relpath(f, ROOT)})')
            bad += 1
            continue
        txt = open(f).read()
        why = qs1(open(ref_log(tree, wl, c, rg)).read(), txt)
        cf = sp_cfg(tree, rg)
        if not why:
            try:
                rep = json.load(open(cf))['LLC']['replacement']
                why = '' if rep == 'srrip_pub' else f'its config\'s LLC.replacement is {rep}'
            except (OSError, KeyError, ValueError) as e:
                why = f'its config cannot be read ({e.__class__.__name__}: {os.path.relpath(cf, ROOT)})'
        if why:
            print(f'   {tree} {rg}: NOT READ -- {why}')
            bad += 1
            continue
        sp[(tree, rg, wl, c)] = parse(txt)
    if bad:
        print(f'   NO REPORT while {bad} of {len(jobs())} runs are missing or fail their gates')
        return 1
    print(f'   QS1, window, traces and config: {len(sp)} of {len(jobs())} hold')
    print('\n== The 19 configurations (max cycles; LLC misses = ROI LLC TOTAL access - hit)')
    for tree, wl, c, rg, _, _ in jobs():
        s, r, l = sp[(tree, rg, wl, c)], R[(tree, rg, wl, c, 'srrip')], R[(tree, rg, wl, c, 'lru')]
        print(f'   {tree[len(P2):]:22} {rg:7}  srrip_pub {s["max_cyc"]:>14,}  srrip {r["max_cyc"]:>14,}  lru {l["max_cyc"]:>14,}  '
              f'pub vs srrip {s["max_cyc"] / r["max_cyc"] - 1:+.2%}  pub vs lru {s["max_cyc"] / l["max_cyc"] - 1:+.2%}  '
              f'LLC misses {s["tot_acc"] - s["tot_hit"]:,} / {r["tot_acc"] - r["tot_hit"]:,} / {l["tot_acc"] - l["tot_hit"]:,}'
              + ('  (barnes: not ranked)' if 'barnesstd' in tree else ''))
    sub = substitute(rows, sp)
    print('\n== Sensitivity: each ranked tree with srrip_pub in srrip\'s place, tau against the ranking of record')
    for tree, rg, t, n in sensitivity(rows, sub):
        print(f'   {tree[len(P2):]:22} {rg:7} tau {t:+.2f} over {n}')
    print('   P11 (shared against private), record -> with srrip_pub:')
    for c in (4, 8):
        for sz, suf in (('fixed 2 MB', ''), ('2 MB a core', '_scaled')):
            a = P.tau(rows, f'{P2}canneal{c}{suf}', 'shared', f'{P2}canneal{c}{suf}', 'private')[0]
            b = P.tau(sub, f'{P2}canneal{c}{suf}', 'shared', f'{P2}canneal{c}{suf}', 'private')[0]
            print(f'     canneal {c}c, {sz}: {a:+.2f} -> {b:+.2f}')
    va, vb = P.verdicts(rows, P2), P.verdicts(sub, P2)
    ch = [k for k in va if va[k][0] != vb[k][0]]
    for k in va:
        print(f'   {k}: record {"HOLDS" if va[k][0] else "FAILS"} ({va[k][1]} of {va[k][2]}); with srrip_pub '
              f'{"HOLDS" if vb[k][0] else "FAILS"} ({vb[k][1]} of {vb[k][2]})')
    print('   ' + ('No verdict of P11-P14 would change with the published SRRIP in ChampSim\'s place.' if not ch
                 else f'The verdict of {", ".join(ch)} would change with the published SRRIP in ChampSim\'s place (reported; the record stands).'))
    print('\n== The probe\'s expectations (reported, not gating)')
    k = (P2 + 'ocean4_scaled', 'shared', 'ocean', 4)
    d = sp[k]['max_cyc'] / R[k + ('lru',)]['max_cyc'] - 1
    print(f'   ocean 4c, 2 MB a core, shared: srrip_pub vs LRU {d:+.2%} ({"within" if abs(d) <= 0.05 else "NOT within"} 5%)')
    for tree in (P2 + 'canneal4', P2 + 'canneal4_scaled'):
        for rg in ('shared', 'private'):
            k = (tree, rg, 'canneal', 4)
            d = sp[k]['max_cyc'] / R[k + ('srrip',)]['max_cyc'] - 1
            print(f'   canneal 4c {tree[len(P2):]} {rg}: srrip_pub vs srrip {d:+.2%} ({"within" if abs(d) <= 0.02 else "NOT within"} 2%)')
    print('\nStep 5\'s verdicts and rankings of record (p2, ChampSim\'s srrip) are unchanged.')
    return 0


def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    log = '\n'.join([
        'Number of CPUs: 2', 'CPU 0 runs a.xz', 'CPU 1 runs b.xz', 'Warmup Instructions: 10', 'Simulation Instructions: 20',
        'cpu0->LLC TOTAL        ACCESS:        999  HIT:        1  MISS:  998',
        'Simulation complete CPU 0 instructions: 20 cycles: 300 cumulative IPC: 0.1 (Simulation time: 00 hr 00 min 01 sec)',
        'Simulation complete CPU 1 instructions: 21 cycles: 400 cumulative IPC: 0.1 (Simulation time: 00 hr 00 min 01 sec)',
        'Region of Interest Statistics',
        'cpu0->LLC TOTAL        ACCESS:        100  HIT:         60  MISS:         40',
        'cpu1->LLC TOTAL        ACCESS:         50  HIT:         10  MISS:         40',
        'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:          0',
        'SRRIP_PUB FILLS: 80 LEFT AT RRPV 2: 80',
        DONE, ''])
    check('parse', parse(log), {'max_cyc': 400, 'ins': 41, 'tot_acc': 150, 'tot_hit': 70})
    ref = log.replace('SRRIP_PUB FILLS: 80 LEFT AT RRPV 2: 80\n', '')
    check('QS1 holds', qs1(ref, log), '')
    check('incomplete', qs1(ref, log.replace(DONE, '')), 'not complete')
    check('no fills line', qs1(ref, ref)[:2], '0 ')
    check('two fills lines', qs1(ref, log.replace(DONE, 'SRRIP_PUB FILLS: 80 LEFT AT RRPV 2: 80\n' + DONE))[:2], '2 ')
    check('a fill at 3', qs1(ref, log.replace('RRPV 2: 80', 'RRPV 2: 79')), 'fills 80, at RRPV 2 79')
    check('no fills', qs1(ref, log.replace('FILLS: 80 LEFT AT RRPV 2: 80', 'FILLS: 0 LEFT AT RRPV 2: 0')), 'fills 0, at RRPV 2 0')
    check('unexplained', qs1(ref, log.replace('UNEXPLAINED:          0', 'UNEXPLAINED:          2'))[:10], 'unexplaine')
    check('wrap', qs1(ref, log.replace(DONE, 'Reached end of trace x\n' + DONE)), 'a trace wrapped')
    check('another trace', qs1(ref, log.replace('CPU 1 runs b.xz', 'CPU 1 runs c.xz'))[:4], 'its ')
    check('another warm-up', qs1(ref, log.replace('Warmup Instructions: 10', 'Warmup Instructions: 11'))[:4], 'its ')
    # substitution: only the p2 srrip row of the matching configuration changes
    rows = [{'tree': P2 + 'canneal4', 'rg': 'shared', 'wl': 'canneal', 'cores': 4, 'pol': p, 'st': 'complete',
             'max_cyc': m, 'ins': 1, 'tot_acc': 1, 'tot_hit': 0} for p, m in (('lru', 100), ('srrip', 90), ('drrip', 95))]
    sub = substitute(rows, {(P2 + 'canneal4', 'shared', 'canneal', 4): {'max_cyc': 99, 'ins': 1, 'tot_acc': 1, 'tot_hit': 0}})
    check('substituted', [r['max_cyc'] for r in sub], [100, 99, 95])
    check('record untouched', [r['max_cyc'] for r in rows], [100, 90, 95])
    import policy_score as P
    oa, ob = P.order(rows, P2 + 'canneal4', 'shared', pols=['lru', 'srrip', 'drrip'])[1], P.order(sub, P2 + 'canneal4', 'shared', pols=['lru', 'srrip', 'drrip'])[1]
    check('orders', (oa, ob), (['srrip', 'drrip', 'lru'], ['drrip', 'srrip', 'lru']))
    check('tau of one adjacent swap over 3', round(AR.kendall_tau(oa, ob), 4), round(1 / 3, 4))
    check('ranked trees exclude barnes', any('barnesstd' in t for t, _ in ranked_trees()), False)
    check('ranked trees: 15 (tree, regime) pairs', len(ranked_trees()), 15)
    check('19 jobs', len(jobs()), 19)
    print('selftest:', 'PASS' if ok else 'FAILED')
    return ok


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['selftest']:
        sys.exit(0 if selftest() else 1)
    if a[:1] == ['parser']:
        sys.exit(0 if parser_check(AR.load(a[1] if len(a) > 1 else ROWS)) else 1)
    if a[:1] == ['score']:
        sys.exit(score(a[1] if len(a) > 1 else ROWS))
    sys.exit(__doc__)
