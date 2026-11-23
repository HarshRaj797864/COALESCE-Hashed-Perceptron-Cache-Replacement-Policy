#!/usr/bin/env python3
"""Score D, the hardware direction check (bench/policy_sanity/hw_direction_design_2026-11-18.md).
Written 2026-11-18, before the machine's model is known and before any hardware count exists.

    python3 hw_score.py selftest
    python3 hw_score.py qh   QHDIR          # QH from hw_run.sh qh's perf stat files; writes QHDIR/../QH_HELD if it holds
    python3 hw_score.py progs PROGDIR       # P-D1, P-D2 from hw_run.sh progs's files and panel_rows_v1 (laptop)

perf stat -x, files: "value,unit,event,run time,percent,..." per event; comment lines start with '#'.
Keys come from the EVENTS file copied into the directory (key=event): inst, rfo_hitm, rfo_clean,
ld_hitm. A value "<not counted>" or "<not supported>", or a missing file, fails the run.

QH (the note, as corrected before any code): per case and key,
  slope = (median over the 5 repeats at 40,000 rounds - median at 20,000) / 20,000
  per round = slope(case) - slope(its barrier-only control: none4 for pp_store, pp_lock, pp_rmw,
              readers; none3 for ctl)
  holds if pp_store, pp_lock, pp_rmw read 3 +- 1 rfo_hitm a round; ctl and readers 0 +- 1;
  slope(pp_store) - slope(readers) >= 2 in rfo_hitm (both 4 steps); and ctl reads 1 +- 0.5 rfo_clean a round.
Programs: H_hw = (rfo_hitm + rfo_clean) per thousand instructions (inst), per run; the median over
the 10 repeats with the highest and lowest dropped; a run whose .err lacks "HW_ANCHOR enabled", whose
"HW_ANCHOR total creates K" is missing or differs from its PROGS anchor N (the anchor must be the last
create), or whose inst is 0, fails and is listed.
  P-D1  Spearman rho(H_hw, C_cs) >= 0.7 over the 7 programs, permutation p < 0.05
  P-D2  H_hw / C_cs in [0.1, 10] on at least 6 of the 7
  C_cs = ChampSim's rate of panel_rows_v1.txt's S row (one span a program); G_g5 = gem5's.
"""
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
PANEL = os.path.join(os.path.dirname(HERE), 'bench/policy_sanity/panel_rows_v1.txt')
G5MT = os.path.join(os.path.dirname(HERE), 'bench/policy_sanity/hw_gem5_mt_rows_v1.txt')
KEYS = ('inst', 'rfo_hitm', 'rfo_clean', 'ld_hitm')
CASES = {'pp_store': 'none4', 'pp_lock': 'none4', 'pp_rmw': 'none4', 'readers': 'none4', 'ctl': 'none3'}
ROUNDS = (20000, 40000)
SPAN = {'ocean': 'ocean_2_MB', 'canneal': 'canneal_4c_2_MB', 'radix': 'radix', 'barnes': 'barnes_std_force',
        'lunc': 'lunc', 'fluidanimate': 'fluidanimate', 'vips': 'vips'}


def events(path):
    out = {}
    for ln in open(path):
        ln = ln.strip()
        if '=' in ln and not ln.startswith('#'):
            k, v = ln.split('=', 1)
            out[k.strip()] = v.strip()
    return out


def read_csv(path, ev):
    """{key: value} from one perf stat -x, file; None if a value is missing or not counted"""
    if not os.path.isfile(path):
        return None
    byname = {}
    for ln in open(path):
        if not ln.strip() or ln.startswith('#'):
            continue
        p = ln.rstrip('\n').split(',')
        if len(p) < 3:
            continue
        byname[p[2]] = p[0]
    out = {}
    for k, name in ev.items():
        v = byname.get(name)
        if v is None or not re.fullmatch(r'\d+(\.\d+)?', v):
            return None
        out[k] = float(v)
    return out


def slope(vals20, vals40):
    return (statistics.median(vals40) - statistics.median(vals20)) / (ROUNDS[1] - ROUNDS[0])


def qh_judge(sl):
    """sl: {(case, key): slope} -> (lines, holds)"""
    lines, ok = [], True
    per = {}
    for c, ctl in CASES.items():
        for k in ('rfo_hitm', 'rfo_clean'):
            if (c, k) in sl and (ctl, k) in sl:
                per[(c, k)] = sl[(c, k)] - sl[(ctl, k)]
    for c in ('pp_store', 'pp_lock', 'pp_rmw'):
        v = per[(c, 'rfo_hitm')]
        good = 2 <= v <= 4
        ok &= good
        lines.append(f'   {c}: {v:.3f} HITM RFOs a round (3 +- 1): {"ok" if good else "FAILS"}')
    for c in ('ctl', 'readers'):
        v = per[(c, 'rfo_hitm')]
        good = -1 <= v <= 1
        ok &= good
        lines.append(f'   {c}: {v:.3f} HITM RFOs a round (0 +- 1): {"ok" if good else "FAILS"}')
    # the contrast compares two 4-step cases (design, correction of 2026-11-23): pp_store against ctl would carry one
    # barrier step's own HITMs, since ctl has 3 steps
    con = sl[('pp_store', 'rfo_hitm')] - sl[('readers', 'rfo_hitm')]
    good = con >= 2
    ok &= good
    lines.append(f'   contrast pp_store - readers (both 4 steps): {con:.3f} HITM RFOs a round (>= 2): {"ok" if good else "FAILS"}')
    if ('ctl', 'rfo_clean') in per:
        v = per[('ctl', 'rfo_clean')]
        good = 0.5 <= v <= 1.5
        ok &= good
        lines.append(f'   ctl: {v:.3f} clean-snoop RFOs a round (1 +- 0.5): {"ok" if good else "FAILS"}')
    else:
        lines.append('   HITM-only model (no documented clean twin, correction 3): the clean-snoop condition is not judged')
    for c in CASES:
        if (c, 'rfo_clean') in per and c != 'ctl':
            lines.append(f'   reported: {c} {per[(c, "rfo_clean")]:.3f} clean-snoop RFOs a round')
    return lines, ok


def qh(d):
    ev = events(os.path.join(d, 'EVENTS'))
    miss = [k for k in ('inst', 'rfo_hitm') if k not in ev]   # rfo_clean: absent on HITM-only models (correction 3)
    if miss:
        print(f'QH NOT JUDGED: EVENTS lacks {miss}')
        return 1
    sl, bad = {}, []
    for c in list(CASES) + ['none4', 'none3']:
        vals = {r: [] for r in ROUNDS}
        for r in ROUNDS:
            for k in range(1, 6):
                v = read_csv(os.path.join(d, f'{c}_r{r}_{k}.csv'), ev)
                if v is None:
                    bad.append(f'{c}_r{r}_{k}')
                else:
                    vals[r].append(v)
        if any(len(vals[r]) < 3 for r in ROUNDS):
            continue
        for key in [k for k in ('rfo_hitm', 'rfo_clean') if k in ev]:
            sl[(c, key)] = slope([x[key] for x in vals[ROUNDS[0]]], [x[key] for x in vals[ROUNDS[1]]])
    if bad:
        print(f'   runs missing or not counted: {", ".join(bad)}')
    need = [c for c in list(CASES) + ['none4', 'none3'] if (c, 'rfo_hitm') not in sl]
    if need:
        print(f'QH NOT JUDGED: fewer than 3 good repeats at a round count for {need}')
        return 1
    lines, ok = qh_judge(sl)
    print('\n'.join(lines))
    print(f'QH {"HOLDS" if ok else "FAILS"}')
    if ok:
        open(os.path.join(os.path.dirname(os.path.abspath(d)), 'QH_HELD'), 'w').write('QH held\n')
    return 0 if ok else 1


def panel():
    out = {}
    for ln in open(PANEL):
        q = ln.split()
        if q and q[0] == 'ROW' and q[2] == 'S':
            out[q[1]] = (float(q[3]), float(q[4]))
    return out


def trimmed_median(v):
    v = sorted(v)
    if len(v) >= 3:
        v = v[1:-1]
    return statistics.median(v), v[0], v[-1]


def predictions(h, c):
    """h, c: {program: rate} over the same programs -> (lines, (P-D1, P-D2))"""
    import panel_stats as PS
    progs = sorted(h)
    x, y = [h[p] for p in progs], [c[p] for p in progs]
    rho, p = PS.spearman(x, y), PS.perm_p(x, y)
    d1 = rho >= 0.7 and p < 0.05
    within = [q for q in progs if 0.1 <= h[q] / c[q] <= 10]
    d2 = len(within) >= len(progs) - 1
    lines = [f'   P-D1: rho {rho:+.3f} (permutation p {p:.4f}) over {len(progs)} programs: {"HOLDS" if d1 else "FAILS"}',
             f'   P-D2: H_hw / C_cs within [0.1, 10] on {len(within)} of {len(progs)} (needs {len(progs) - 1}): {"HOLDS" if d2 else "FAILS"}']
    return lines, (d1, d2)


def anchors(path):
    """{name: N} from a PROGS file (name|anchor_n|dir|stdin|command...)"""
    out = {}
    for ln in open(path):
        q = ln.rstrip('\n').split('|')
        if len(q) >= 5 and not ln.startswith('#'):
            out[q[0]] = int(q[1])
    return out


def run_ok(err_text, n):
    """the anchor fired, and the program created exactly n threads in all"""
    m = re.search(r'HW_ANCHOR total creates (\d+)', err_text)
    return 'HW_ANCHOR enabled' in err_text and m is not None and int(m.group(1)) == n


def progs(d):
    ev = events(os.path.join(d, 'EVENTS'))
    A = anchors(os.path.join(d, 'PROGS'))
    runs, bad = {}, []
    for f in sorted(os.listdir(d)):
        m = re.fullmatch(r'(.+)_(\d+)\.csv', f)
        if not m:
            continue
        name = m.group(1)
        v = read_csv(os.path.join(d, f), ev)
        err = os.path.join(d, f[:-4] + '.err')
        anch = os.path.isfile(err) and name in A and run_ok(open(err, errors='replace').read(), A[name])
        if v is None or not anch or v['inst'] <= 0:
            bad.append(f[:-4])
            continue
        runs.setdefault(name, []).append(v)
    if bad:
        print(f'   failed runs (not used): {", ".join(bad)}')
    P = panel()
    h, c, g, hm = {}, {}, {}, {}
    if 'rfo_clean' not in ev:
        print('   HITM-only model (correction 3): H_hw = demand RFOs with a HITM snoop response, per KI')
    for name, vs in sorted(runs.items()):
        if name not in SPAN or len(vs) < 8:
            print(f'   {name}: {len(vs)} good runs{"" if name in SPAN else " (not a program of the note)"} -- not used')
            continue
        cl = (lambda v: v['rfo_clean']) if 'rfo_clean' in ev else (lambda v: 0.0)
        rates = [1000.0 * (v['rfo_hitm'] + cl(v)) / v['inst'] for v in vs]
        med, lo, hi = trimmed_median(rates)
        hitm = statistics.median([v['rfo_hitm'] / (v['rfo_hitm'] + cl(v)) for v in vs if v['rfo_hitm'] + cl(v) > 0] or [float('nan')])
        hm[name] = statistics.median([1000.0 * v['rfo_hitm'] / v['inst'] for v in vs])
        h[name], (c[name], g[name]) = med, P[SPAN[name]]
        ld = (f'; loads {statistics.median([1000.0 * v["ld_hitm"] / v["inst"] for v in vs]):.4f} XSNP-HITM/KI' if all('ld_hitm' in v for v in vs) else '')
        print(f'   {name}: H_hw {med:.4f}/KI [{lo:.4f}, {hi:.4f}] over {len(vs)} runs; HITM share {hitm:.1%}; '
              f'ChampSim {c[name]:.4f}, gem5 {g[name]:.4f}; H_hw / C_cs {med / c[name]:.2f}, H_hw / G_g5 {med / g[name]:.2f}{ld}')
    if set(h) != set(SPAN):
        print(f'   NO VERDICT: programs missing: {sorted(set(SPAN) - set(h))}')
        return 1
    lines, _ = predictions(h, c)
    print('\n'.join(lines))
    import panel_stats as PS
    hs = sorted(h)
    print(f'   reported: rho(H_hw, G_g5) {PS.spearman([h[p] for p in hs], [g[p] for p in hs]):+.3f}')
    mt = g5mt_rows(G5MT)
    if all(SPAN[p] in mt for p in hs):
        m = [mt[SPAN[p]][0] for p in hs]
        print(f'   reported: HITM RFOs against gem5 MT.L1_GETX (a store finding another core owning the line): '
              f'rho {PS.spearman([hm[p] for p in hs], m):+.3f}; ratios ' +
              ', '.join(f'{p} {hm[p] / mt[SPAN[p]][0]:.2f}' for p in hs if mt[SPAN[p]][0] > 0))
    return 0


def g5mt():
    """gem5's MT and SS L1_GETX per KI over each D span's window, read as panel_stats.rows reads them"""
    import lock_fix_score as L
    D, B, sp = L.spans()
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    want = {v.replace('_', ' '): v for v in SPAN.values()}
    print('# hw_score.py g5mt: G5MT <span> <gem5 MT.L1_GETX per KI> <gem5 SS.L1_GETX per KI> (the panel windows)')
    n = 0
    for label, role, tree, (_, ga, gb), logroot, _, _ in sp:
        if label not in want:
            continue
        w = B.window(Gr, ga, gb)
        print(f'G5MT {want[label]} {1000.0 * w["mt_getx"] / w["insts"]:.6f} {1000.0 * w["ss_getx"] / w["insts"]:.6f}')
        n += 1
    return 0 if n == len(want) else 1


def g5mt_rows(path):
    out = {}
    if os.path.isfile(path):
        for ln in open(path):
            q = ln.split()
            if q and q[0] == 'G5MT':
                out[q[1]] = (float(q[2]), float(q[3]))
    return out


def selftest():
    import tempfile
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    ev = {'inst': 'instructions:u', 'rfo_hitm': 'hitm:u', 'rfo_clean': 'clean:u'}
    with tempfile.TemporaryDirectory() as t:
        f = os.path.join(t, 'a.csv')
        open(f, 'w').write('# started on x\n\n1000,,instructions:u,5,100.00,,\n70,,hitm:u,5,100.00,,\n9,,clean:u,5,100.00,,\n')
        check('read_csv', read_csv(f, ev), {'inst': 1000.0, 'rfo_hitm': 70.0, 'rfo_clean': 9.0})
        open(f, 'w').write('1000,,instructions:u,5,100.00,,\n<not counted>,,hitm:u,0,0.00,,\n9,,clean:u,5,100.00,,\n')
        check('not counted fails', read_csv(f, ev), None)
        check('missing file', read_csv(os.path.join(t, 'none.csv'), ev), None)
        # a whole QH directory: barrier 6 HITM a step; pp_* add 3 a round; ctl adds 1 clean a round
        d = os.path.join(t, 'out', 'qh')
        os.makedirs(d)
        open(os.path.join(d, 'EVENTS'), 'w').write('inst=instructions:u\nrfo_hitm=hitm:u\nrfo_clean=clean:u\n')
        steps = {'pp_store': 4, 'pp_lock': 4, 'pp_rmw': 4, 'readers': 4, 'none4': 4, 'ctl': 3, 'none3': 3}
        add = {'pp_store': (3, 0), 'pp_lock': (3, 0), 'pp_rmw': (3, 0), 'readers': (0, 1), 'ctl': (0, 1), 'none4': (0, 0), 'none3': (0, 0)}
        for c, n in steps.items():
            for r in ROUNDS:
                for k in range(1, 6):
                    hm = 500 + r * (6 * n + add[c][0]) + k
                    cl = 40 + r * add[c][1] + k
                    open(os.path.join(d, f'{c}_r{r}_{k}.csv'), 'w').write(f'{10 ** 9},,instructions:u,1,100.00,,\n{hm},,hitm:u,1,100.00,,\n{cl},,clean:u,1,100.00,,\n')
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = qh(d)
        check('QH holds on a hand case', (rc, 'QH HOLDS' in buf.getvalue(), os.path.isfile(os.path.join(t, 'out', 'QH_HELD'))), (0, True, True))
    sl = {(c, k): 0.0 for c in list(CASES) + ['none4', 'none3'] for k in ('rfo_hitm', 'rfo_clean')}
    good = {**sl, ('pp_store', 'rfo_hitm'): 3.0, ('pp_lock', 'rfo_hitm'): 3.0, ('pp_rmw', 'rfo_hitm'): 3.0, ('ctl', 'rfo_clean'): 1.0}
    check('judge holds', qh_judge(good)[1], True)
    check('pp_rmw at 1.9 fails', qh_judge({**good, ('pp_rmw', 'rfo_hitm'): 1.9})[1], False)
    check('ctl HITM 1.1 fails', qh_judge({**good, ('ctl', 'rfo_hitm'): 1.1})[1], False)
    check('a barrier shift is removed by the control', qh_judge({k: v + (0.7 if k[1] == 'rfo_hitm' and k[0] in ('pp_store', 'pp_lock', 'pp_rmw', 'readers', 'none4') else 0) for k, v in good.items()})[1], True)
    check('contrast below 2 fails (1.5)', qh_judge({**good, ('readers', 'rfo_hitm'): 1.5, ('none4', 'rfo_hitm'): 0.6})[1], False)
    check('contrast at 2 holds', qh_judge({**good, ('readers', 'rfo_hitm'): 1.0, ('none4', 'rfo_hitm'): 0.5})[1], True)
    gap = qh_judge({**good, ('pp_store', 'rfo_hitm'): 7.5, ('pp_lock', 'rfo_hitm'): 7.5, ('pp_rmw', 'rfo_hitm'): 7.5,
                    ('readers', 'rfo_hitm'): 6.0, ('none4', 'rfo_hitm'): 6.0, ('ctl', 'rfo_hitm'): 4.5, ('none3', 'rfo_hitm'): 4.5})[0]
    check('a barrier step (1.5 a step) does not pass the contrast (pp_store - ctl would read 3)',
          [ln.split(':')[-1].strip() for ln in gap if 'contrast' in ln], ['FAILS'])
    check('ctl clean 0.4 fails', qh_judge({**good, ('ctl', 'rfo_clean'): 0.4})[1], False)
    check('anchor: last create', run_ok('HW_ANCHOR enabled after create 3\nx\nHW_ANCHOR total creates 3\n', 3), True)
    check('anchor: not the last create', run_ok('HW_ANCHOR enabled after create 3\nHW_ANCHOR total creates 5\n', 3), False)
    check('anchor: no exit line', run_ok('HW_ANCHOR enabled after create 3\n', 3), False)
    check('anchor: never enabled', run_ok('HW_ANCHOR total creates 3\n', 3), False)
    only = {k: v for k, v in good.items() if k[1] == 'rfo_hitm'}
    check('HITM-only model: holds without clean keys', qh_judge(only)[1], True)
    check('HITM-only model: says the clean condition is not judged', any('not judged' in ln for ln in qh_judge(only)[0]), True)
    check('HITM-only model: pp_store at 1.5 fails', qh_judge({**only, ('pp_store', 'rfo_hitm'): 1.5})[1], False)
    check('g5mt rows: MT + SS = the panel gem5 rate (ocean)', (lambda m, P: abs(sum(m['ocean_2_MB']) - P['ocean_2_MB'][1]) < 2e-6)(g5mt_rows(G5MT), panel()), True)
    check('trimmed median', trimmed_median([1, 2, 3, 4, 100, 5, 6, 7, 8, 9]), (5.5, 2, 9))
    h = {p: float(i + 1) for i, p in enumerate(SPAN)}
    c = {p: float(i + 1) * 2 for i, p in enumerate(SPAN)}
    check('P-D1, P-D2 hold', predictions(h, c)[1], (True, True))
    check('P-D2 fails at two outside', predictions(h, dict(c, ocean=100.0, radix=100.0))[1][1], False)
    check('P-D1 fails reversed', predictions(h, {p: 10.0 - v for p, v in h.items()})[1][0], False)
    print('selftest:', 'PASS' if ok else 'FAILED')
    return ok


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['selftest']:
        sys.exit(0 if selftest() else 1)
    if len(a) == 2 and a[0] == 'qh':
        sys.exit(qh(a[1]))
    if len(a) == 2 and a[0] == 'progs':
        sys.exit(progs(a[1]))
    if a == ['g5mt']:
        sys.exit(g5mt())
    sys.exit(__doc__)
