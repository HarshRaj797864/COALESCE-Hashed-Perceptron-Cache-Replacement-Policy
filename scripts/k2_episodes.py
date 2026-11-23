#!/usr/bin/env python3
"""K2, steps 1 and 2 (bench/policy_sanity/k2_sharing_gap_design_2026-11-17.md),
fixed before it reads any real file.

    k2_episodes.py run [PROG ...]       step 1 (default: canneal fluidanimate vips),
                                        then step 2 for vips and step 3's condition
    k2_episodes.py drift [PROG]         step 2 alone (default vips)
    k2_episodes.py selftest             hand-made files with known answers

Inputs (H6(b)'s pulled files; QG0 / QC0 held there):
    $H6B/g5/<p>/ev.txt        E tick line req state kind holders rmwline stale
    $H6B/g5/<p>/command.txt   'T_a <tick>' (the 50 M stop's finalTick)
    $H6B/g5/<p>/stats.txt     the rerun's finalTick (QG1: equal to the scored run's)
    $H6B/cs/<p>/ev.txt        E cycle line cpu - kind holders rmwline
    $H6B/cs/<p>/run.log       Warmup finished / Simulation finished / Heartbeat lines
    $H6B/report_<p>.txt       H6(b)'s s (I_g / I_c) and its R on these events
    $VIEW/<scored 150 M run>/stats.txt   the window's end (finalTick)
H6B defaults to simulator/results/h6b, VIEW to simulator/results/gem5_b3_view.

Window (normalised time t' = (t - start) / (end - start)):
    gem5      start = T_a, end = the scored 150 M run's finalTick
    ChampSim  start = the earliest 'Warmup finished' cycle; end = the latest
              core's warm-up cycle + its 'Simulation finished' cycles (that line
              prints the cycles of the measured phase; note amendment 1)
Episodes: per line, events in time order; a new episode when the gap to the
line's previous event exceeds gamma (0.001 primary; 0.0001 and 0.01 reported).
Ep = N_C x s / N_G; Per = (C / N_C) / (G / N_G); R = C x s / G = Ep x Per;
share_I = ln(Per) / ln(R).  I: share_I >= 2/3; E: <= 1/3; mixed otherwise.
Control (canneal): Ep and Per each in [0.8, 1.25] at gamma = 0.001.
Step 3 is indicated when fluidanimate reads I, or vips reads E or mixed with
Spearman's rho (events per 2% bin against the cores' spread) <= -0.3.
"""
import math
import os
import re
import shutil
import sys
import tempfile

H6B = os.environ.get('H6B', 'simulator/results/h6b')
VIEW = os.environ.get('VIEW', 'simulator/results/gem5_b3_view')
VIEWS = {
    'canneal': 'canneal/l2_2MB_mi150M/canneal_4c',
    'fluidanimate': 'heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c',
    'vips': 'heldout2/vips/l2_2MB_mi150M/vips_4c',
}
GAMMAS = (0.0001, 0.001, 0.01)
PRIMARY = 0.001
BINS = 50
RE_WARM = re.compile(r'^Warmup finished CPU (\d+) instructions: (\d+) cycles: (\d+)')
RE_SIM = re.compile(r'^Simulation finished CPU (\d+) instructions: (\d+) cycles: (\d+)')
RE_HB = re.compile(r'^Heartbeat CPU (\d+) instructions: (\d+) cycles: (\d+)')
RE_TRACED = re.compile(r'traced ([0-9,]+)')
RE_S = re.compile(r'\bs ([0-9.]+);')
RE_R = re.compile(r'R_g5 on these ([0-9.]+)')


def die(msg):
    print(f'k2_episodes: {msg}', file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------- inputs
def load_events(path, sim):
    """Events and, for gem5, the traced CPUs from the header."""
    ev, traced = [], None
    for ln in open(path):
        if ln.startswith('#'):
            m = RE_TRACED.search(ln)
            if m and traced is None:
                traced = {int(x) for x in m.group(1).split(',') if x}
            continue
        p = ln.split()
        if not p or p[0] != 'E':
            continue
        want = 9 if sim == 'gem5' else 8
        if len(p) != want:
            die(f'{path}: {len(p)} fields, expected {want}: {ln.strip()}')
        h = [int(x) for x in p[6].split(',') if x not in ('', '-')]
        ev.append({'t': int(p[1]), 'line': int(p[2], 16), 'req': int(p[3]), 'kind': p[5], 'holders': h})
    return ev, traced


def final_tick(stats):
    for ln in open(stats):
        if ln.startswith('finalTick'):
            return int(ln.split()[1])
    die(f'{stats}: no finalTick')


def gem5_window(h6b, view, prog, views=VIEWS):
    ta = None
    for ln in open(os.path.join(h6b, 'g5', prog, 'command.txt')):
        p = ln.split()
        if len(p) == 2 and p[0] == 'T_a':
            ta = int(p[1])
            break
    if ta is None:
        die(f'{prog}: no T_a in command.txt')
    end = final_tick(os.path.join(view, views[prog], 'stats.txt'))
    rerun = os.path.join(h6b, 'g5', prog, 'stats.txt')
    if os.path.exists(rerun) and final_tick(rerun) != end:
        die(f'{prog}: the rerun ends at {final_tick(rerun)}, the scored run at {end} (QG1 says equal)')
    if end <= ta:
        die(f'{prog}: gem5 window empty ({ta} .. {end})')
    return ta, end


def cs_window(runlog):
    warm, sim, hb = {}, {}, {}
    for ln in open(runlog):
        m = RE_WARM.match(ln)
        if m:
            warm[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
            continue
        m = RE_SIM.match(ln)
        if m:
            sim[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
            continue
        m = RE_HB.match(ln)
        if m:
            hb.setdefault(int(m.group(1)), []).append((int(m.group(3)), int(m.group(2))))
    if not warm or set(warm) != set(sim):
        die(f'{runlog}: warm-up lines for {sorted(warm)}, finished lines for {sorted(sim)}')
    start = min(c for _, c in warm.values())
    end = max(warm[k][1] + sim[k][1] for k in sim)
    return start, end, warm, sim, hb


def report_s_r(h6b, prog):
    txt = open(os.path.join(h6b, f'report_{prog}.txt')).read()
    ms, mr = RE_S.search(txt), RE_R.search(txt)
    if not ms or not mr:
        die(f'report_{prog}.txt: no s or R')
    return float(ms.group(1)), float(mr.group(1))


# ---------------------------------------------------------------- step 1
def norm(ev, start, end):
    span = float(end - start)
    out = 0
    for e in ev:
        e['u'] = (e['t'] - start) / span
        out += not (0.0 <= e['u'] <= 1.0)
    return out


def episodes(ev, gamma):
    by = {}
    for e in ev:
        by.setdefault(e['line'], []).append(e)
    eps = []
    for line in by:
        cur = []
        for e in sorted(by[line], key=lambda x: x['u']):
            if cur and e['u'] - cur[-1]['u'] > gamma:
                eps.append(cur)
                cur = []
            cur.append(e)
        eps.append(cur)
    return eps


def reading(share):
    if share is None:
        return 'undefined'
    if share >= 2 / 3:
        return 'I'
    if share <= 1 / 3:
        return 'E'
    return 'mixed'


def split(cev, gev, s, gamma):
    C, G = len(cev), len(gev)
    if not C or not G:
        return {'C': C, 'G': G, 'NC': 0, 'NG': 0, 'Ep': None, 'Per': None, 'R': None, 'share': None, 'reading': 'undefined'}
    nc, ng = len(episodes(cev, gamma)), len(episodes(gev, gamma))
    ep = nc * s / ng
    per = (C / nc) / (G / ng)
    r = C * s / G
    share = None if abs(math.log(r)) < 1e-12 else math.log(per) / math.log(r)
    return {'C': C, 'G': G, 'NC': nc, 'NG': ng, 'Ep': ep, 'Per': per, 'R': r, 'share': share, 'reading': reading(share)}


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = max(0, math.ceil(q * len(xs)) - 1)
    return xs[k]


def cores_hist(eps):
    h = {}
    for ep in eps:
        n = len({e['req'] for e in ep} | {c for e in ep for c in e['holders']})
        h[n] = h.get(n, 0) + 1
    return dict(sorted(h.items()))


def bins(ev, n=BINS):
    b = [0] * n
    for e in ev:
        b[min(n - 1, max(0, int(e['u'] * n)))] += 1
    return b


def fmt(x, d=3):
    return 'n/a' if x is None else f'{x:.{d}f}'


def control_holds(sp):
    return sp['Ep'] is not None and 0.8 <= sp['Ep'] <= 1.25 and 0.8 <= sp['Per'] <= 1.25


def step1(prog, h6b=H6B, view=VIEW, views=VIEWS, out=print):
    gev, traced = load_events(os.path.join(h6b, 'g5', prog, 'ev.txt'), 'gem5')
    cev, _ = load_events(os.path.join(h6b, 'cs', prog, 'ev.txt'), 'champsim')
    gs, ge = gem5_window(h6b, view, prog, views)
    cs, ce, *_ = cs_window(os.path.join(h6b, 'cs', prog, 'run.log'))
    s, r_h6b = report_s_r(h6b, prog)
    og, oc = norm(gev, gs, ge), norm(cev, cs, ce)
    out(f'\n== K2 step 1: {prog}')
    out(f'   window: gem5 {gs} .. {ge} ticks; ChampSim {cs} .. {ce} cycles; events outside it: gem5 {og}, ChampSim {oc}')
    res = {g: split(cev, gev, s, g) for g in GAMMAS}
    p = res[PRIMARY]
    out(f'   C {p["C"]}, G {p["G"]}, s {s}; R {fmt(p["R"])} (H6(b) {r_h6b:.3f}{"" if abs(p["R"] - r_h6b) <= 0.0015 else " -- DIFFERS"})')
    for g in GAMMAS:
        x = res[g]
        out(f'   gamma {g:<6} {"(primary)" if g == PRIMARY else "         "} episodes ChampSim {x["NC"]}, gem5 {x["NG"]}; '
            f'Ep {fmt(x["Ep"])}, Per {fmt(x["Per"])}; share_I {fmt(x["share"])} -> {x["reading"]}')
    other = sorted({res[g]['reading'] for g in GAMMAS if g != PRIMARY and res[g]['reading'] != p['reading']})
    dep = f'; depends on the time scale (other gammas: {", ".join(other)})' if other else ''
    out(f'   READING (gamma {PRIMARY}): {p["reading"]}{dep}')
    ge_eps, ce_eps = episodes(gev, PRIMARY), episodes(cev, PRIMARY)
    gl, cl = [len(x) for x in ge_eps], [len(x) for x in ce_eps]
    out(f'   events per episode: gem5 median {pct(gl, 0.5)}, p90 {pct(gl, 0.9)}; ChampSim median {pct(cl, 0.5)}, p90 {pct(cl, 0.9)}')
    out(f'   episodes by distinct cores: gem5 {cores_hist(ge_eps)}; ChampSim {cores_hist(ce_eps)}')
    tr = traced if traced is not None else None
    gst = [e for e in gev if e['kind'] == 'store' and (tr is None or (e['req'] in tr and all(h in tr for h in e['holders'])))]
    cst = [e for e in cev if e['kind'] == 'store']
    xs = split(cst, gst, s, PRIMARY)
    out(f'   stores only (gem5 traced CPUs {sorted(tr) if tr else "all"}): C {xs["C"]}, G {xs["G"]}, R {fmt(xs["R"])}; '
        f'Ep {fmt(xs["Ep"])}, Per {fmt(xs["Per"])}; share_I {fmt(xs["share"])} -> {xs["reading"]} (reported)')
    out(f'   events in {BINS} bins of the window: gem5 {bins(gev)}')
    out(f'                                  ChampSim {bins(cev)}')
    return {'primary': p, 'reading': p['reading'], 'depends': bool(other), 'control': control_holds(p)}


# ---------------------------------------------------------------- step 2
def interp(points, x):
    """Piecewise-linear y(x) through sorted (x, y) points; flat outside them."""
    if x <= points[0][0]:
        return points[0][1]
    if x >= points[-1][0]:
        return points[-1][1]
    lo, hi = 0, len(points) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if points[mid][0] <= x:
            lo = mid
        else:
            hi = mid
    (x0, y0), (x1, y1) = points[lo], points[hi]
    return y0 if x1 == x0 else y0 + (y1 - y0) * (x - x0) / (x1 - x0)


def ranks(v):
    order = sorted(range(len(v)), key=lambda i: v[i])
    r = [0.0] * len(v)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
            j += 1
        for k in range(i, j + 1):
            r[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return r


def spearman(x, y):
    rx, ry = ranks(x), ranks(y)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    sxy = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    sxx = sum((a - mx) ** 2 for a in rx)
    syy = sum((b - my) ** 2 for b in ry)
    return None if sxx == 0 or syy == 0 else sxy / math.sqrt(sxx * syy)


def step2(prog, h6b=H6B, out=print):
    cev, _ = load_events(os.path.join(h6b, 'cs', prog, 'ev.txt'), 'champsim')
    cs, ce, warm, sim, hb = cs_window(os.path.join(h6b, 'cs', prog, 'run.log'))
    norm(cev, cs, ce)
    curves = {}
    for k in sim:
        pts = sorted(set(hb.get(k, [])) | {(warm[k][1], warm[k][0])})
        curves[k] = pts
    spread = []
    for i in range(BINS):
        t = cs + (i + 0.5) / BINS * (ce - cs)
        pos = [interp(curves[k], t) for k in sorted(curves)]
        spread.append(max(pos) - min(pos))
    counts = bins(cev)
    rho = spearman(counts, spread)
    out(f'\n== K2 step 2: {prog} (ChampSim only; reported)')
    out(f'   heartbeat points per core: {[len(curves[k]) for k in sorted(curves)]}')
    out(f'   spread of the cores (M instructions) per 2% bin: {[round(x / 1e6, 2) for x in spread]}')
    out(f'   events per bin: {counts}')
    out(f'   Spearman rho (events against spread): {fmt(rho)}')
    return rho


def step3(fl, vp, rho):
    a = fl == 'I'
    b = vp in ('E', 'mixed') and rho is not None and rho <= -0.3
    return a, b


def run(progs):
    res = {}
    for p in progs:
        res[p] = step1(p)
    print('\n== Step 1 readings')
    ctl = res.get('canneal')
    if ctl is not None:
        print(f'   control canneal 4c: {"holds" if ctl["control"] else "FAILS -- the episode split is unreliable; step 1 readings not used"} '
              f'(Ep {fmt(ctl["primary"]["Ep"])}, Per {fmt(ctl["primary"]["Per"])})')
    for p in progs:
        if p != 'canneal':
            print(f'   {p}: {res[p]["reading"]}{" (depends on the time scale)" if res[p]["depends"] else ""}')
    if 'vips' in progs:
        rho = step2('vips')
        if 'fluidanimate' in res:
            used = ctl is None or ctl['control']
            a, b = step3(res['fluidanimate']['reading'] if used else None, res['vips']['reading'] if used else None, rho)
            print('\n== Step 3 condition')
            print(f'   fluidanimate reads I: {"yes" if a else "no"}; vips reads E or mixed with rho <= -0.3: {"yes" if b else "no"}'
                  f' -> step 3 {"INDICATED (an amendment first, then the owner's word)" if a or b else "not indicated"}')


# ---------------------------------------------------------------- self-test
def selftest():
    d = tempfile.mkdtemp(prefix='k2st_')
    fails = []

    def check(name, got, want):
        if got != want:
            fails.append(f'{name}: got {got!r}, want {want!r}')

    GS, GE = 1_000, 1_000_000_000 + 1_000          # gem5 window, ticks
    WARM = {0: 500, 1: 600}                       # ChampSim warm-up cycles
    SIM = {0: 10_000_000, 1: 10_000_100}          # measured-phase cycles
    CS, CE = 500, 600 + 10_000_100

    def gt(u):
        return GS + round(u * (GE - GS))

    def ct(u):
        return CS + round(u * (CE - CS))

    def mk(prog, g5, cs, s, hb=None, traced='1,2'):
        """g5 / cs: lists of (u, line, req, kind, holders)."""
        for sub in ('g5', 'cs'):
            os.makedirs(os.path.join(d, 'h6b', sub, prog), exist_ok=True)
        os.makedirs(os.path.join(d, 'view', prog), exist_ok=True)
        with open(os.path.join(d, 'h6b', 'g5', prog, 'ev.txt'), 'w') as f:
            print(f'# h6b_attr.py gem5 x: 1 L1/L2 transition lines; {len(g5)} events (SS/MT L1_GETX, paired); traced {traced}', file=f)
            for u, ln, rq, k, h in g5:
                print(f'E {gt(u)} {ln:x} {rq} MT {k} {",".join(map(str, h))} 0 0', file=f)
        with open(os.path.join(d, 'h6b', 'cs', prog, 'ev.txt'), 'w') as f:
            print(f'# h6b_attr.py champsim x: {len(cs)} events', file=f)
            for u, ln, rq, k, h in cs:
                print(f'E {ct(u)} {ln:x} {rq} - {k} {",".join(map(str, h))} 0', file=f)
        open(os.path.join(d, 'h6b', 'g5', prog, 'command.txt'), 'w').write(f'T_a {GS}\ncwd x\n')
        for p in (os.path.join(d, 'h6b', 'g5', prog, 'stats.txt'), os.path.join(d, 'view', prog, 'stats.txt')):
            open(p, 'w').write(f'\n---------- Begin Simulation Statistics ----------\nfinalTick {GE} # ticks\n')
        with open(os.path.join(d, 'h6b', 'cs', prog, 'run.log'), 'w') as f:
            for k in (0, 1):
                for x in (hb or {}).get(k, []):
                    print(f'Heartbeat CPU {k} instructions: {x[1]} cycles: {x[0]} heartbeat IPC: 1 cumulative IPC: 1', file=f)
                print(f'Warmup finished CPU {k} instructions: 50000000 cycles: {WARM[k]} cumulative IPC: 1', file=f)
            for k in (0, 1):
                print(f'Simulation finished CPU {k} instructions: 100000000 cycles: {SIM[k]} cumulative IPC: 1', file=f)
        r = (len(cs) * s / len(g5)) if g5 else 0
        open(os.path.join(d, 'h6b', f'report_{prog}.txt'), 'w').write(
            f'== H6(b) {prog}\n   C {len(cs)} (scored {len(cs)}), G {len(g5)} (scored {len(g5)}), s {s}; R_g5 on these {r:.3f}\n')

    def burst(u0, n, line=0x10, kinds=None):
        return [(u0 + i * 5e-5, line, 1 + i % 2, (kinds or ['store'] * n)[i], [2 - i % 2]) for i in range(n)]

    views = {}

    def run1(prog):
        views[prog] = prog
        lines = []
        r = step1(prog, h6b=os.path.join(d, 'h6b'), view=os.path.join(d, 'view'), views=views, out=lines.append)
        return r, lines

    # I: one burst each, gem5 6 events (4 stores, 2 RMWs), ChampSim 2 stores
    mk('pI', burst(0.1, 6, kinds=['store', 'rmw', 'store', 'rmw', 'store', 'store']), burst(0.1, 2), 1.0)
    r, L = run1('pI')
    p = r['primary']
    check('pI counts', (p['C'], p['G'], p['NC'], p['NG']), (2, 6, 1, 1))
    check('pI Ep/Per/R', (round(p['Ep'], 6), round(p['Per'], 6), round(p['R'], 6)), (1.0, round(1 / 3, 6), round(1 / 3, 6)))
    check('pI share', round(p['share'], 6), 1.0)
    check('pI reading', (r['reading'], r['depends']), ('I', False))
    check('pI window line', any('events outside it: gem5 0, ChampSim 0' in x for x in L), True)
    check('pI cores per episode', any("gem5 {2: 1}; ChampSim {2: 1}" in x for x in L), True)
    check('pI stores only', any('stores only' in x and 'C 2, G 4, R 0.500' in x and '-> I' in x for x in L), True)
    check('pI R vs H6(b)', any('DIFFERS' in x for x in L), False)

    # E: gem5 three bursts of 2, ChampSim one burst of 2
    mk('pE', burst(0.1, 2) + burst(0.3, 2) + burst(0.5, 2), burst(0.1, 2), 1.0)
    r, _ = run1('pE')
    p = r['primary']
    check('pE Ep/Per', (round(p['Ep'], 6), round(p['Per'], 6)), (round(1 / 3, 6), 1.0))
    check('pE reading', (r['reading'], r['depends']), ('E', False))

    # mixed: gem5 two bursts of 4, ChampSim one burst of 2
    mk('pM', burst(0.1, 4) + burst(0.6, 4), burst(0.1, 2), 1.0)
    r, _ = run1('pM')
    check('pM share/reading', (round(r['primary']['share'], 6), r['reading']), (0.5, 'mixed'))

    # s != 1: same bursts, s = 0.5 -> Ep 0.5, Per 1, E
    mk('pS', burst(0.2, 4), burst(0.2, 4), 0.5)
    r, _ = run1('pS')
    p = r['primary']
    check('pS', (round(p['Ep'], 6), round(p['Per'], 6), round(p['R'], 6), r['reading']), (0.5, 1.0, 0.5, 'E'))

    # time-scale dependence: gaps of 0.005 -> separate at 0.001, together at 0.01
    g = [(0.1 + i * 0.005, 0x10, 1 + i % 2, 'store', [2 - i % 2]) for i in range(4)]
    c = [(0.1 + i * 0.005, 0x10, 1 + i % 2, 'store', [2 - i % 2]) for i in range(2)]
    mk('pT', g, c, 1.0)
    r, L = run1('pT')
    check('pT primary', r['reading'], 'E')
    check('pT gamma 0.01', any(x.startswith('   gamma 0.01 ') and x.endswith('-> I') for x in L), True)
    check('pT depends', r['depends'], True)

    # control: identical streams hold; one burst of 4 against two of 2 fails (Ep 0.5)
    mk('cP', burst(0.1, 3) + burst(0.7, 3, line=0x20), burst(0.1, 3) + burst(0.7, 3, line=0x20), 1.0)
    r, _ = run1('cP')
    check('cP control', (r['control'], r['reading']), (True, 'undefined'))
    mk('cF', burst(0.1, 2) + burst(0.4, 2), burst(0.1, 4), 1.0)
    r, _ = run1('cF')
    check('cF control', (r['control'], round(r['primary']['Ep'], 6), round(r['primary']['Per'], 6)), (False, 0.5, 2.0))

    # stores-only filter drops untraced CPUs (gem5 traced 1,2; an event from 0)
    mk('pU', burst(0.1, 2) + [(0.9, 0x30, 0, 'store', [1])], burst(0.1, 2), 1.0)
    r, L = run1('pU')
    check('pU stores only', any('stores only' in x and 'G 2,' in x for x in L), True)
    check('pU all events', r['primary']['G'], 3)

    # an event outside the window is counted and kept
    mk('pO', burst(0.1, 2), burst(0.1, 2) + [(-0.01, 0x40, 1, 'store', [2])], 1.0)
    r, L = run1('pO')
    check('pO outside', any('ChampSim 1' in x and 'events outside it' in x for x in L), True)
    check('pO kept', r['primary']['C'], 3)

    # windows: ChampSim end = warm-up + measured cycles of the latest core
    st, en, *_ = cs_window(os.path.join(d, 'h6b', 'cs', 'pI', 'run.log'))
    check('cs window', (st, en), (CS, CE))

    # step 2: spread grows with time, events fall with time -> rho = -1
    hb = {0: [(CS + i * (CE - CS) // 10, 50_000_000 + i * 10_000_000) for i in range(1, 11)],
          1: [(CS + i * (CE - CS) // 10, 50_000_000 + i * 8_000_000) for i in range(1, 11)]}
    evs = []
    for i in range(BINS):
        for j in range(BINS - i):
            evs.append(((i + 0.5) / BINS, 0x100 + i, 1, 'store', [2]))
    mk('pD', burst(0.1, 2), evs, 1.0, hb=hb)
    lines = []
    rho = step2('pD', h6b=os.path.join(d, 'h6b'), out=lines.append)
    check('step 2 rho', round(rho, 6), -1.0)
    check('spearman hand', round(spearman([1, 2, 3, 4, 5], [5, 6, 7, 8, 7]), 4), round(8 / math.sqrt(95), 4))
    check('interp', (interp([(0, 0), (10, 100)], 5), interp([(0, 0), (10, 100)], 20)), (50.0, 100))

    # step 3's condition
    check('step 3', [step3('I', 'E', 0.0), step3('E', 'mixed', -0.3), step3('mixed', 'E', -0.29), step3('E', 'I', -0.9)],
          [(True, False), (False, True), (False, False), (False, False)])

    # a malformed event line is refused
    bad = os.path.join(d, 'bad.txt')
    open(bad, 'w').write('E 1 10 1 - store\n')
    try:
        load_events(bad, 'champsim')
        fails.append('malformed line: accepted')
    except SystemExit:
        pass

    shutil.rmtree(d)
    if fails:
        print('SELFTEST FAIL:')
        for f in fails:
            print('   ' + f)
        sys.exit(1)
    print('SELFTEST PASS: I, E, mixed, s != 1, time-scale dependence, control pass and fail, the untraced filter, '
          'an event outside the window, the ChampSim window, Spearman (rho -1 and a hand case with ties), interpolation, '
          "step 3's condition, a malformed line refused")


def main(a):
    if not a:
        print(__doc__)
        sys.exit(1)
    if a[0] == 'selftest':
        selftest()
    elif a[0] == 'run':
        run(a[1:] or ['canneal', 'fluidanimate', 'vips'])
    elif a[0] == 'drift':
        step2(a[1] if len(a) > 1 else 'vips')
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main(sys.argv[1:])
