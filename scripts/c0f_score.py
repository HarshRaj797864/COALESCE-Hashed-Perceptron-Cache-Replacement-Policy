#!/usr/bin/env python3
"""C0f's checks and score (bench/policy_sanity/c0f_latency_final_design_2026-11-23.md).
Written and self-tested before any C0f run existed.

    python3 scripts/c0f_score.py selftest
    python3 scripts/c0f_score.py qf LOGDIR P3DIR
        QF0-QF2 from the pulled logs: LOGDIR = simulator/results/c0f/logs (phaseA_b3_c0f{0,100}_* trees),
        P3DIR = simulator/results/h7/logs (H7's phaseA_b3_p3_* trees). Amendment 1 (relaunch_2026-11-24.md): the L = 0
        rows are H7's p3 runs; C0f runs L = 0 only for the control (lru), equal to H7's log (QF0); every config is
        checked against H7's (QF0c; the cfg dirs pulled next to LOGDIR and P3DIR)
    python3 scripts/c0f_score.py score ROWS LOGDIR P3DIR
        QF first; only if every check holds, P1-P3 from ROWS (phasea_rows_vN.txt, pull_results.sh), the
        order by max_cycles as step 5 reads it (policy_score.order; ties by name)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SUFFIXES = {'canneal4': ('canneal', 4), 'canneal8': ('canneal', 8), 'ocean4': ('ocean', 4)}
LATS = (0, 100)
DONE = 'ChampSim completed all CPUs'
LAT_RE = re.compile(r'^COHERENCE INVALIDATION LATENCY \(CYCLES\): (\d+)\s*$', re.M)
WAIT_RE = re.compile(r'COHERENCE LATENCY WAITS:\s*(\d+)\s*$', re.M)
UNEXPL_RE = re.compile(r'^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:\s*(\d+)', re.M)
P1_MIN = 0.89
P2_SPREAD = 0.01


def policies():
    import policy_jobs as PJ
    return list(PJ.POLICIES)


def tree(L, sfx):
    return f'phaseA_b3_c0f{L}_{sfx}'


def logpath(top, tr, sfx, pol):
    wl, n = SUFFIXES[sfx]
    return os.path.join(top, tr, 'regime_shared', f'{wl}_{n}core', pol, 'run.log')


def clean(txt):
    """a log as QF0 compares it: the wall-clock part of a line masked (as ld_score.clean)"""
    return [re.sub(r'\(Simulation time: [^)]*\)', '', ln) for ln in txt.splitlines()]


def check_log(txt, L):
    """'' if one run's log holds QF1 and QF2 at latency L, else why not"""
    if DONE not in txt:
        return 'not complete'
    if 'SYNC DEADLOCK' in txt:
        return 'SYNC DEADLOCK'
    if 'Reached end of trace' in txt:
        return 'end of trace'
    u = sum(int(x) for x in UNEXPL_RE.findall(txt))
    if u:
        return f'{u} unexplained view-order violations'
    m = LAT_RE.findall(txt)
    if L == 0 and m:
        return 'prints a latency line at L = 0'
    if L > 0:
        if m != [str(L)]:
            return f'latency line {m}, not [{L}]'
        if sum(int(x) for x in WAIT_RE.findall(txt)) <= 0:
            return 'no latency waits'
    return ''


CONTROL = ('lru',)   # amendment 1: the policy run at L = 0 by C0f itself, a configuration


def p3tree(sfx):
    return f'phaseA_b3_p3_{sfx}'


def complete(f):
    return os.path.isfile(f) and DONE in open(f, errors='replace').read()


def l0_source(logdir, p3dir, sfx, pol):
    """amendment 1: where a job's L = 0 row comes from -- H7's p3 run if complete, else C0f's own L = 0 run
    (L0_SET=all), else None"""
    if complete(logpath(p3dir, p3tree(sfx), sfx, pol)):
        return 'p3'
    if os.path.isfile(logpath(logdir, tree(0, sfx), sfx, pol)):
        return 'c0f'
    return None


def cfg_check(logdir, p3dir, sfx, pol):
    """QF0c: C0f's L = 0 config equals H7's config of the job, and its L = 100 config is that plus
    "coherence_latency": 100 (configs pulled next to the logs: <logdir>/../cfg)"""
    import json
    cd, hd = os.path.join(os.path.dirname(logdir), 'cfg'), os.path.join(os.path.dirname(p3dir), 'cfg')
    a, b, h = (os.path.join(cd, f'L0_{sfx}_shared_{pol}.json'), os.path.join(cd, f'L100_{sfx}_shared_{pol}.json'),
               os.path.join(hd, f'{sfx}_shared_{pol}.json'))
    for x in (a, b, h):
        if not os.path.isfile(x):
            return f'no config {x}'
    ja, jb, jh = (json.load(open(x)) for x in (a, b, h))
    if ja != jh:
        return "the L = 0 config differs from H7's"
    if jb != dict(ja, coherence_latency=100):
        return 'the L = 100 config is not the L = 0 config plus coherence_latency 100'
    return ''


def qf(logdir, p3dir, pols=None, quiet=False):
    """(holds, lines). Amendment 1: L = 100 from C0f's runs; L = 0 from H7's complete p3 run of the job
    (or C0f's own L = 0 run where H7's is not complete); every CONTROL policy's L = 0 run by C0f must
    exist and equal H7's p3 log (QF0); every job's configs pass QF0c."""
    pols = pols or policies()
    lines, ok = [], True
    n0 = same = nsrc = ncfg = 0
    for sfx in SUFFIXES:
        for pol in pols:
            f = logpath(logdir, tree(100, sfx), sfx, pol)
            if not os.path.isfile(f):
                ok = False
                lines.append(f'   QF2 FAILS: L=100 {sfx} {pol}: no log')
            else:
                why = check_log(open(f, errors='replace').read(), 100)
                if why:
                    ok = False
                    lines.append(f'   QF1/QF2 FAILS: L=100 {sfx} {pol}: {why}')
            src = l0_source(logdir, p3dir, sfx, pol)
            if src is None:
                ok = False
                lines.append(f'   QF2 FAILS: L=0 {sfx} {pol}: neither H7\'s p3 run is complete nor a C0f L = 0 log exists')
            else:
                nsrc += src == 'p3'
                g = logpath(p3dir, p3tree(sfx), sfx, pol) if src == 'p3' else logpath(logdir, tree(0, sfx), sfx, pol)
                why = check_log(open(g, errors='replace').read(), 0)
                if why:
                    ok = False
                    lines.append(f'   QF1/QF2 FAILS: L=0 {sfx} {pol} ({src}): {why}')
            why = cfg_check(logdir, p3dir, sfx, pol)
            if why:
                ok = False
                lines.append(f'   QF0c FAILS: {sfx} {pol}: {why}')
            else:
                ncfg += 1
            own = logpath(logdir, tree(0, sfx), sfx, pol)
            if pol in CONTROL or os.path.isfile(own):
                h = logpath(p3dir, p3tree(sfx), sfx, pol)
                if not os.path.isfile(own) or not complete(h):
                    if pol in CONTROL:
                        ok = False
                        lines.append(f'   QF0 FAILS: {sfx} {pol}: the control needs C0f\'s L = 0 log and H7\'s complete p3 log')
                    continue
                n0 += 1
                if clean(open(h, errors='replace').read()) == clean(open(own, errors='replace').read()):
                    same += 1
                else:
                    ok = False
                    lines.append(f'   QF0 FAILS: {sfx} {pol}: the L = 0 log differs from H7\'s p3 log')
    nj = len(SUFFIXES) * len(pols)
    lines.append(f'   QF0: {same} of {n0} C0f L = 0 logs equal to H7\'s complete p3 logs (wall-clock masked); '
                 f'controls {", ".join(CONTROL)}')
    lines.append(f'   QF0c: {ncfg} of {nj} jobs\' configs equal to H7\'s (L = 0) and to it plus coherence_latency 100 (L = 100)')
    lines.append(f'   L = 0 rows: {nsrc} of {nj} from H7\'s p3 runs, {nj - nsrc} from C0f\'s own')
    lines.append(f'   QF0-QF2: {"hold" if ok else "FAIL"} on {nj} jobs at two latencies')
    return ok, lines


def l0_rows(rows, logdir, p3dir, pols):
    """amendment 1: the L = 0 rows of tree(0, sfx), each taken from its source tree and relabelled"""
    out = [r for r in rows if not r['tree'].startswith('phaseA_b3_c0f0_')]
    for sfx in SUFFIXES:
        for pol in pols:
            src = l0_source(logdir, p3dir, sfx, pol)
            st = p3tree(sfx) if src == 'p3' else tree(0, sfx)
            for r in rows:
                if r['tree'] == st and r['pol'] == pol and r['rg'] == 'shared':
                    out.append(dict(r, tree=tree(0, sfx)))
    return out


def p_lines(rows, pols=None):
    """P1-P3 from rows (dicts with tree rg st pol max_cyc) -> (lines, {sfx: (p1, p2, p3)})"""
    import policy_score as PS
    pols = pols or policies()
    out, v = [], {}
    for sfx in SUFFIXES:
        a, b = tree(0, sfx), tree(100, sfx)
        da, oa = PS.order(rows, a, 'shared', pols)
        db, ob = PS.order(rows, b, 'shared', pols)
        if len(da) != len(pols) or len(db) != len(pols):
            out.append(f'   {sfx}: NOT SCORED -- {len(da)} / {len(db)} of {len(pols)} policies complete at L = 0 / 100')
            continue
        t, n, tie = PS.tau(rows, a, 'shared', b, 'shared')
        rise = {p: db[p]['max_cyc'] / da[p]['max_cyc'] - 1 for p in pols}
        spread = max(rise.values()) - min(rise.values())
        p1, p2, p3 = t >= P1_MIN, spread < P2_SPREAD, rise['lru'] >= 0
        v[sfx] = (p1, p2, p3)
        out.append(f'   {sfx}: P1 tau(L=100, L=0) {t:+.3f} over {n} policies (>= +{P1_MIN}): {"holds" if p1 else "FAILS"}'
                   f'{"; ties " + str(tie) if tie else ""}')
        out.append(f'   {sfx}: P2 rise in max_cycles {min(rise.values()):+.3%} .. {max(rise.values()):+.3%}, spread '
                   f'{spread * 100:.3f} pp (< {P2_SPREAD * 100:.0f}): {"holds" if p2 else "FAILS"}; '
                   f'P3 LRU {rise["lru"]:+.3%}: {"holds" if p3 else "FAILS"}')
        out.append(f'   {sfx}: order at L = 0   {" < ".join(oa)}')
        out.append(f'   {sfx}: order at L = 100 {" < ".join(ob)}  (COALESCE {ob.index("coalesce") + 1 if "coalesce" in ob else "-"} of {len(ob)})')
    return out, v


def score(rows_path, logdir, p3dir):
    import analyze_rows as AR
    ok, lines = qf(logdir, p3dir)
    print('\n'.join(lines))
    if not ok:
        print('NOT SCORED: a check fails (above); nothing is read')
        return 1
    out, v = p_lines(l0_rows(AR.load(rows_path), logdir, p3dir, policies()))
    print('\n'.join(out))
    if len(v) == len(SUFFIXES):
        print(f'P1 {"HOLDS" if all(x[0] for x in v.values()) else "FAILS"} on {sum(x[0] for x in v.values())} of 3 configurations')
    return 0


def selftest():
    import tempfile
    good = True

    def check(name, got, want):
        nonlocal good
        g = got == want
        good &= g
        print(f'   {"ok  " if g else "FAIL"} {name}: {got!r}' + ('' if g else f' (want {want!r})'))

    base = ('CPU 0 runs /t/a.xz\nWarmup Instructions: 50000000\n'
            'Heartbeat CPU 0 instructions: 10 cycles: 20 (Simulation time: 00 hr 01 min 02 sec)\n'
            'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED: 0\n')
    l0 = base + DONE + '\n'
    l100 = 'COHERENCE INVALIDATION LATENCY (CYCLES): 100\n' + base + 'cpu0_LLC COHERENCE LATENCY WAITS:        42\n' + DONE + '\n'
    check('L0 log holds', check_log(l0, 0), '')
    check('L100 log holds', check_log(l100, 100), '')
    check('L0 with a latency line fails', check_log(l100, 0), 'prints a latency line at L = 0')
    check('L100 without waits fails', check_log(l100.replace('WAITS:        42', 'WAITS:        0'), 100), 'no latency waits')
    check('L100 without the line fails', check_log(l0, 100), "latency line [], not [100]")
    check('incomplete fails', check_log(base, 0), 'not complete')
    check('unexplained fails', check_log(l0.replace('UNEXPLAINED: 0', 'UNEXPLAINED: 3'), 0), '3 unexplained view-order violations')
    check('end of trace fails', check_log(l0 + 'Reached end of trace\n', 0), 'end of trace')
    check('wall clock masked', clean(l0) == clean(l0.replace('01 min 02 sec', '09 min 59 sec')), True)
    pols = ['lru', 'srrip', 'coalesce']
    import json
    with tempfile.TemporaryDirectory() as t:
        ld, pd = os.path.join(t, 'c0f', 'logs'), os.path.join(t, 'h7', 'logs')
        cd, hd = os.path.join(t, 'c0f', 'cfg'), os.path.join(t, 'h7', 'cfg')
        os.makedirs(cd); os.makedirs(hd)

        def put(f, txt):
            os.makedirs(os.path.dirname(f), exist_ok=True)
            open(f, 'w').write(txt)
        for sfx in SUFFIXES:
            for pol in pols:
                put(logpath(ld, tree(100, sfx), sfx, pol), l100)
                put(logpath(pd, p3tree(sfx), sfx, pol), l0.replace('01 min 02 sec', '07 min 00 sec'))
                if pol in CONTROL:
                    put(logpath(ld, tree(0, sfx), sfx, pol), l0)
                c = {'policy': pol, 'private_coherence': 2, 'sync_lock_word': 'request'}
                json.dump(c, open(os.path.join(hd, f'{sfx}_shared_{pol}.json'), 'w'))
                json.dump(c, open(os.path.join(cd, f'L0_{sfx}_shared_{pol}.json'), 'w'), indent=2)
                json.dump(dict(c, coherence_latency=100), open(os.path.join(cd, f'L100_{sfx}_shared_{pol}.json'), 'w'))
        ok, ln = qf(ld, pd, pols)
        check('amendment 1: QF holds; QF0 3 of 3; QF0c 9 of 9; 9 L = 0 rows from p3',
              (ok, any('QF0: 3 of 3' in x for x in ln), any('QF0c: 9 of 9' in x for x in ln), any('9 of 9 from H7' in x for x in ln)),
              (True, True, True, True))
        g = logpath(pd, p3tree('canneal4'), 'canneal4', 'lru')
        put(g, l0.replace('cycles: 20', 'cycles: 21'))
        check('QF0 catches a control differing from its p3 log', qf(ld, pd, pols)[0], False)
        put(g, l0)
        os.remove(g)
        check('a control without its p3 log fails', qf(ld, pd, pols)[0], False)
        put(g, l0)
        h = logpath(pd, p3tree('ocean4'), 'ocean4', 'srrip')
        put(h, l0.replace(DONE, 'running'))
        check('a non-control with neither source fails', qf(ld, pd, pols)[0], False)
        put(logpath(ld, tree(0, 'ocean4'), 'ocean4', 'srrip'), l0)
        ok, ln = qf(ld, pd, pols)
        check('... with C0f\'s own L = 0 log instead it holds (8 of 9 from p3)', (ok, any('8 of 9 from H7' in x for x in ln)), (True, True))
        put(h, l0)
        os.remove(logpath(ld, tree(0, 'ocean4'), 'ocean4', 'srrip'))
        x = os.path.join(hd, 'canneal8_shared_coalesce.json')
        json.dump({'policy': 'coalesce', 'private_coherence': 2}, open(x, 'w'))
        check('QF0c catches a config differing from H7\'s', qf(ld, pd, pols)[0], False)
        json.dump({'policy': 'coalesce', 'private_coherence': 2, 'sync_lock_word': 'request'}, open(x, 'w'))
        y = os.path.join(cd, 'L100_canneal8_shared_coalesce.json')
        json.dump({'policy': 'coalesce', 'private_coherence': 2, 'sync_lock_word': 'request', 'coherence_latency': 50}, open(y, 'w'))
        check('QF0c catches an L = 100 config that is not L = 0 + 100', qf(ld, pd, pols)[0], False)
        json.dump({'policy': 'coalesce', 'private_coherence': 2, 'sync_lock_word': 'request', 'coherence_latency': 100}, open(y, 'w'))
        check('restored: QF holds', qf(ld, pd, pols)[0], True)
        os.remove(logpath(ld, tree(100, 'ocean4'), 'ocean4', 'srrip'))
        check('a missing L = 100 log fails QF2', qf(ld, pd, pols)[0], False)
        put(logpath(ld, tree(100, 'ocean4'), 'ocean4', 'srrip'), l100)
        rr = [{'tree': p3tree('canneal4'), 'rg': 'shared', 'st': 'complete', 'pol': 'srrip', 'max_cyc': 7},
              {'tree': tree(0, 'canneal4'), 'rg': 'shared', 'st': 'complete', 'pol': 'lru', 'max_cyc': 9},
              {'tree': p3tree('canneal4'), 'rg': 'shared', 'st': 'complete', 'pol': 'lru', 'max_cyc': 9}]
        got = sorted((r['tree'], r['pol'], r['max_cyc']) for r in l0_rows(rr, ld, pd, ['lru', 'srrip']) if r['tree'] == tree(0, 'canneal4'))
        check('l0_rows relabels p3 rows, one per policy', got, [(tree(0, 'canneal4'), 'lru', 9), (tree(0, 'canneal4'), 'srrip', 7)])

    def rows(c0, c100):
        r = []
        for sfx in SUFFIXES:
            for p in pols:
                r.append({'tree': tree(0, sfx), 'rg': 'shared', 'st': 'complete', 'pol': p, 'max_cyc': c0[p]})
                r.append({'tree': tree(100, sfx), 'rg': 'shared', 'st': 'complete', 'pol': p, 'max_cyc': c100[p]})
        return r
    c0 = {'lru': 1000, 'srrip': 900, 'coalesce': 800}
    _, v = p_lines(rows(c0, {'lru': 1005, 'srrip': 904, 'coalesce': 804}), pols)
    check('same order, uniform rise: P1 P2 P3 hold', v['canneal4'], (True, True, True))
    _, v = p_lines(rows(c0, {'lru': 1000, 'srrip': 1100, 'coalesce': 800}), pols)
    check('a swap among 3: P1 fails (tau +0.333), P2 fails', v['canneal4'][:2], (False, False))
    _, v = p_lines(rows(c0, {'lru': 990, 'srrip': 900, 'coalesce': 800}), pols)
    check('LRU falls: P3 fails', v['canneal4'][2], False)
    print('selftest PASS' if good else 'selftest FAILED')
    return 0 if good else 1


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['selftest']:
        sys.exit(selftest())
    if len(a) == 3 and a[0] == 'qf':
        ok, ln = qf(a[1], a[2])
        print('\n'.join(ln))
        sys.exit(0 if ok else 1)
    if len(a) == 4 and a[0] == 'score':
        sys.exit(score(a[1], a[2], a[3]))
    sys.exit(__doc__)
