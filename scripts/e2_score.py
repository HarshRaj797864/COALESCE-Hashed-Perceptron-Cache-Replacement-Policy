#!/usr/bin/env python3
"""Score E, the second gem5 protocol (bench/policy_sanity/second_protocol_design_2026-11-18.md).
Written 2026-11-18, before any MESI_Two_Level run of these programs has ended and before any of
its counts was read.

    python3 scripts/e2_score.py selftest
    python3 scripts/e2_score.py rows     # b3_score.gem5_rows on the pulled MESI_Two_Level runs (commit as gem5_e2_rows_vN.txt)
    python3 scripts/e2_score.py score    # the gates, then R_g5^two, P-E1 to P-E3 and the reported lines

Inputs (pulled by scripts/e2_all.sh pull; nothing is fetched):
  simulator/results/e2/gem5/<prog>/l2_2MB_mi<stop>M/<tag>/{stats.txt,run.log,config.ini}
  simulator/results/e2/state/<prog>_<long|short>/{RESULT,ql0.txt}, BUILD_OK, QL1_PASSED, ql1.txt
  simulator/results/e2/g5micro/  and  simulator/results/ld/g5micro/gem5/  (QL1 rejudged here)
  the F-C reruns (lock_fix_score), gem5_b3_rows_v6.txt (MESI_Three_Level, of record)

Gates, in order; nothing is computed for a program that fails one:
  QL1  QL1_PASSED pulled, and e2_check.ql1 rejudged on the pulled micro runs holds
  per program: both stops' RESULT read ENDED-AT-STOP, both ql0.txt end in "QL0 PASS"
  ChampSim's and MESI_Three_Level's rates recomputed here equal the scored panel row (panel_rows_v1.txt, to 6 decimals)

Computed (the note, "What is computed"):
  gem5 MESI_Two_Level G (SS + MT L1_GETX), U (SS.L1_UPGRADE), L2 demand accesses and
  instructions in the window (long stop minus short stop), read by b3_score.gem5_rows and
  b3_score.window exactly as every earlier B3 gem5 row
  R_g5^two = (C / I_c) / (G_two / I_two), C and I_c from the span's F-C rerun (unchanged)
  beside it: R_g5 against MESI_Three_Level (of record), U and traffic both ways
  G_two / G_three per KI, per program
Predictions: P-E1 R_g5^two in [0.5, 2] for ocean, canneal 4c, radix (3 of 3); P-E2 R_g5^two < 0.5
for fluidanimate; P-E3 G_two / G_three in [0.5, 2] on all four, reported with H2's spread
(s* = 0.067; |ln| against 1.64 s*).
"""
import contextlib
import io
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROOT = os.path.dirname(HERE)
E2 = os.path.join(ROOT, 'simulator/results/e2')
E2G = os.path.join(E2, 'gem5')
LDMICRO = os.path.join(ROOT, 'simulator/results/ld/g5micro/gem5')
PANEL = os.path.join(ROOT, 'bench/policy_sanity/panel_rows_v1.txt')
BAND = (0.5, 2.0)
S_STAR = 0.067
# program -> (span label in lock_fix_score, b3_score.REFS group, REFS key, the run's tag)
PROGS = {
    'ocean4': ('ocean 2 MB', '', 'ocean4', 'ocean_4c'),
    'canneal4': ('canneal 4c 2 MB', '', 'canneal4', 'canneal_4c'),
    'radix': ('radix', 'held', 'radix4', 'radix_4c'),
    'fluidanimate': ('fluidanimate', 'set2', 'fluidanimate4', 'fluidanimate_4c'),
}
E1 = ['ocean4', 'canneal4', 'radix']


def in_band(x):
    return BAND[0] <= x <= BAND[1]


def e2_runs(B, prog):
    """(short, long) run keys of the MESI_Two_Level runs under E2G, from the original pair's stops"""
    _, grp, key, tag = PROGS[prog]
    _, ga, gb = B.REFS[grp][key]
    stop = lambda run: run.split('/')[-2]   # l2_2MB_mi<N>M  # noqa: E731
    return f'{prog}/{stop(ga)}/{tag}', f'{prog}/{stop(gb)}/{tag}'


def gem5_rows_text(root):
    import b3_score as B
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        B.gem5_rows(root)
    return buf.getvalue()


def load_rows_text(B, text):
    out = {}
    for line in text.splitlines():
        p = line.split()
        if p and not p[0].startswith('#'):
            r = dict(zip(B.GEM5, p))
            out[r['run']] = r
    return out


def ratio_g(w2, w3):
    """G_two / G_three per KI"""
    return ((w2['ss_getx'] + w2['mt_getx']) / w2['insts']) / ((w3['ss_getx'] + w3['mt_getx']) / w3['insts'])


def predictions(res):
    """res: {prog: {'r2': R_g5^two, 'gg': G_two / G_three}} -> (lines, (E1, E2, E3))"""
    lines = []
    n1 = sum(in_band(res[p]['r2']) for p in E1)
    for p in E1:
        lines.append(f'   P-E1 {p}: R_g5^two {res[p]["r2"]:.3f} {"in" if in_band(res[p]["r2"]) else "NOT in"} the band')
    e1 = n1 == len(E1)
    lines.append(f'   P-E1: {n1} of {len(E1)}: {"HOLDS" if e1 else "FAILS"}')
    e2 = res['fluidanimate']['r2'] < 0.5
    lines.append(f'   P-E2: fluidanimate R_g5^two {res["fluidanimate"]["r2"]:.3f}: {"HOLDS" if e2 else "FAILS"} (< 0.5)')
    n3 = 0
    for p in PROGS:
        g = res[p]['gg']
        n3 += in_band(g)
        lines.append(f'   P-E3 {p}: G_two / G_three {g:.3f} (|ln| {abs(math.log(g)):.3f} against 1.64 s* {1.64 * S_STAR:.3f}: '
                     f'{"within" if abs(math.log(g)) <= 1.64 * S_STAR else "beyond"} the noise) {"in" if in_band(g) else "NOT in"} [0.5, 2]')
    e3 = n3 == len(PROGS)
    lines.append(f'   P-E3: {n3} of {len(PROGS)}: {"HOLDS" if e3 else "FAILS"}')
    return lines, (e1, e2, e3)


def reading(v):
    e1, e2, _ = v
    out = []
    out.append('R_g5\'s verdicts on ocean, canneal 4c and radix hold against a second gem5 protocol that needs no FIFO patch.' if e1
               else 'A program outside the band under MESI_Two_Level is stated as sensitive to the reference protocol, with both numbers; nothing is re-tuned.')
    if not e2:
        out.append('fluidanimate in the band under MESI_Two_Level: its gap is put on MESI_Three_Level, reported and diagnosed, never scored as an agreement.')
    out.append('The reference of record stays MESI_Three_Level.')
    return out


def gates_ql1():
    import e2_check as C
    if not os.path.isfile(os.path.join(E2, 'QL1_PASSED')):
        return 'QL1 not passed (or not pulled)'
    two, three = os.path.join(E2, 'g5micro'), LDMICRO
    if not (os.path.isdir(two) and os.path.isdir(three)):
        return f'QL1 cannot be rejudged: pull {os.path.relpath(two, ROOT)} and {os.path.relpath(three, ROOT)}'
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = C.ql1(two, three)
    return '' if rc == 0 else 'QL1 rejudged here FAILS: ' + buf.getvalue().strip().splitlines()[-1]


def gate_prog(prog):
    for stop in ('short', 'long'):
        s = os.path.join(E2, 'state', f'{prog}_{stop}')
        res = open(os.path.join(s, 'RESULT')).read().strip() if os.path.exists(os.path.join(s, 'RESULT')) else ''
        if not res.startswith('ENDED-AT-STOP'):
            return f'{stop} stop: {res or "not ended (or not pulled)"}'
        q = open(os.path.join(s, 'ql0.txt')).read().strip().splitlines() if os.path.exists(os.path.join(s, 'ql0.txt')) else []
        if not q or not q[-1].startswith('QL0 PASS'):
            return f'{stop} stop: QL0 {"not recorded" if not q else q[-1]}'
    return ''


def panel_s():
    out = {}
    for ln in open(PANEL):
        q = ln.split()
        if q and q[0] == 'ROW' and q[2] == 'S':
            out[q[1].replace('_', ' ')] = (float(q[3]), float(q[4]))   # the per-KI rates, printed to 6 decimals
    return out


def collect():
    import b3_score as B
    import lock_fix_score as L
    D, _, sp = L.spans()
    if not L.parser_check(verbose=False):
        sys.exit('the parser check failed: nothing is read')
    G3 = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    G2 = load_rows_text(B, gem5_rows_text(E2G)) if os.path.isdir(E2G) else {}
    span = {s[0]: s for s in sp}
    ps = panel_s()
    res, why = {}, {}
    for prog, (label, grp, key, _) in PROGS.items():
        g = gate_prog(prog)
        if g:
            why[prog] = g
            continue
        _, _, tree, (_, ga, gb), _, _, _ = span[label]
        a2, b2 = e2_runs(B, prog)
        if a2 not in G2 or b2 not in G2:
            why[prog] = f'no gem5 row for {a2 if a2 not in G2 else b2}'
            continue
        w2, w3 = B.window(G2, a2, b2), B.window(G3, ga, gb)
        fc = os.path.join(L.NEW, 'phaseA_b3_fc_' + tree[len('phaseA_b3_'):])
        c = L.counts(open(D.runlog(L.NEW, os.path.basename(fc))).read())
        r3, t3, u3 = L.ratios(c, w3)
        x, y = 1000.0 * c['C'] / c['ins'], 1000.0 * (w3['ss_getx'] + w3['mt_getx']) / w3['insts']
        if abs(x - ps[label][0]) > 5e-7 or abs(y - ps[label][1]) > 5e-7:
            sys.exit(f'{label}: the rates recomputed ({x:.6f}, {y:.6f}) differ from the scored panel row {ps[label]}: nothing is read')
        r2, t2, u2 = L.ratios(c, w2)
        res[prog] = {'r2': r2, 't2': t2, 'u2': u2, 'r3': r3, 't3': t3, 'u3': u3, 'gg': ratio_g(w2, w3), 'w2': w2, 'w3': w3}
    return res, why


def rows():
    print(f'# MESI_Two_Level gem5 rows (second_protocol_design_2026-11-18.md), b3_score.gem5_rows on {os.path.relpath(E2G, ROOT)}')
    sys.stdout.write(gem5_rows_text(E2G))
    return 0


def score():
    print('== E (second_protocol_design_2026-11-18.md): R_g5^two = (C / I_c) / (G_two / I_two), C from the F-C reruns')
    g = gates_ql1()
    if g:
        print(f'   NOT SCORED: {g}')
        return 1
    print('   QL1: QL1_PASSED pulled and rejudged here: holds')
    res, why = collect()
    for prog in PROGS:
        if prog in why:
            print(f'   {prog}: NOT READ -- {why[prog]}')
            continue
        r = res[prog]
        f = lambda x: '-' if x is None else f'{x:.3f}'  # noqa: E731
        print(f'   {prog}: R_g5^two {r["r2"]:.3f} (MESI_Three_Level {r["r3"]:.3f}); traffic {r["t2"]:.3f} ({r["t3"]:.3f}); '
              f'U {f(r["u2"])} ({f(r["u3"])}); G_two / G_three {r["gg"]:.3f}; gem5 window instructions {r["w2"]["insts"]:,} / {r["w3"]["insts"]:,}')
    if why:
        print(f'   NO VERDICT while {len(why)} of {len(PROGS)} programs are not read')
        return 1
    lines, v = predictions(res)
    print('\n'.join(lines))
    for x in reading(v):
        print('   READING: ' + x)
    return 0


def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    import b3_score as B
    check('run keys, ocean', e2_runs(B, 'ocean4'), ('ocean4/l2_2MB_mi50M/ocean_4c', 'ocean4/l2_2MB_mi150M/ocean_4c'))
    check('run keys, radix', e2_runs(B, 'radix'), ('radix/l2_2MB_mi830M/radix_4c', 'radix/l2_2MB_mi930M/radix_4c'))
    check('run keys, canneal', e2_runs(B, 'canneal4'), ('canneal4/l2_2MB_mi50M/canneal_4c', 'canneal4/l2_2MB_mi150M/canneal_4c'))
    check('run keys, fluidanimate', e2_runs(B, 'fluidanimate'),
          ('fluidanimate/l2_2MB_mi50M/fluidanimate_4c', 'fluidanimate/l2_2MB_mi150M/fluidanimate_4c'))
    w2 = {'ss_getx': 30, 'mt_getx': 10, 'insts': 1000}
    w3 = {'ss_getx': 15, 'mt_getx': 5, 'insts': 1000}
    check('G_two / G_three', ratio_g(w2, w3), 2.0)
    check('G ratio scaled', ratio_g(w2, dict(w3, insts=500)), 1.0)
    good = {p: {'r2': 1.0, 'gg': 1.0} for p in PROGS}
    good['fluidanimate'] = {'r2': 0.4, 'gg': 1.0}
    check('all hold', predictions(good)[1], (True, True, True))
    check('edge in', predictions({**good, 'radix': {'r2': 2.0, 'gg': 0.5}})[1], (True, True, True))
    check('E1 fails on one', predictions({**good, 'radix': {'r2': 2.01, 'gg': 1.0}})[1][0], False)
    check('E2 fails at 0.5', predictions({**good, 'fluidanimate': {'r2': 0.5, 'gg': 1.0}})[1][1], False)
    check('E3 fails on one', predictions({**good, 'ocean4': {'r2': 1.0, 'gg': 2.1}})[1][2], False)
    check('reading when E1 fails', reading((False, True, True))[0][:10], 'A program ')
    check('reading when E2 fails', len(reading((True, False, True))), 3)
    print('selftest:', 'PASS' if ok else 'FAILED')
    return ok


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['selftest']:
        sys.exit(0 if selftest() else 1)
    if a == ['rows']:
        sys.exit(rows())
    if a == ['score']:
        sys.exit(score())
    sys.exit(__doc__)
