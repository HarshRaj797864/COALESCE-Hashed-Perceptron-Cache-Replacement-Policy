#!/usr/bin/env python3
"""Score C, the load-side counter (bench/policy_sanity/load_side_design_2026-11-18.md).
Written 2026-11-18, before any rerun of it exists and before any load-side ratio was read.

    python3 scripts/ld_score.py selftest   # hand cases, no data read
    python3 scripts/ld_score.py rows       # one ROW line a span (commit as bench/policy_sanity/ld_rows_vN.txt)
    python3 scripts/ld_score.py score      # the gates, R_ld per span, P-C1 to P-C3, the reported lines

Inputs (all pulled; nothing is fetched):
  simulator/results/ld/            QC0 / QC1A / QC1B markers (scripts/ld_all.sh pull)
  simulator/results/ld/logs/       the 14 reruns phaseA_b3_ld_<suffix>
  simulator/results/lockfix/logs/  their references, the F-C reruns (scored; lock_fix_score)
  simulator/results/gem5_b3/       gem5's stats.txt of each span's two stops
  bench/policy_sanity/gem5_b3_rows_v6.txt  gem5's window instructions (b3_score.window)

Per span (lock_fix_score's 14, its windows):
  L, I_c   the rerun's first "LLC COHERENCE DIR LOAD GEM5-RULE OWNER EVENTS" value (the
           first block, as every coherence counter is read) and its instructions
  M, I_g   gem5's system.ruby.L2Cache_Controller.MT.L1_GETS in the window (long stop minus
           short stop; from the start for a span without a short stop) and the window's
           instructions
  R_ld   = (L / I_c) / (M / I_g)

Gates, before anything is scored (the note, "Checks"): QC0 (Q0, Q0m, K0 markers), QC1a and
QC1b markers; each rerun complete, both new lines present, and equal to its F-C reference
line for line once the new lines are removed and the "(Simulation time: ...)" stamps masked
(QC2, recomputed here); the reference qualifies by lock_fix_score's own rule.

Predictions (fixed in the note):
  P-C1  barnes std window, barnes std force, barnes-256, ocean 2 MB, canneal 4c 2 MB,
        canneal 8c, radix, lunc: R_ld in [0.5, 2] on at least 6 of 8
  P-C2  the 11 scored spans: Spearman rho >= 0.7 with permutation p < 0.05, and rho >= 0.7
        one span per program (panel_stats' sets and method)
  P-C3  R_ld < 1 for fluidanimate and for vips
Reported, deciding nothing: OTHER-READ owner events; gem5's owner side, EE.Fwd_GETS (clean)
and MM.Fwd_GETS (modified) in the window, and the modified share; the apart spans.
"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROOT = os.path.dirname(HERE)
LD = os.path.join(ROOT, 'simulator/results/ld')
LDLOGS = os.path.join(LD, 'logs')
G5 = os.path.join(ROOT, 'simulator/results/gem5_b3')
BAND = (0.5, 2.0)
DONE = 'ChampSim completed all CPUs'
NEW = 'GEM5-RULE OWNER EVENTS'
P1 = ['barnes std window', 'barnes std force', 'barnes-256', 'ocean 2 MB', 'canneal 4c 2 MB', 'canneal 8c', 'radix', 'lunc']
P3 = ['fluidanimate', 'vips']
GETS = 'system.ruby.L2Cache_Controller.MT.L1_GETS'
FWD_E = 'system.ruby.L1Cache_Controller.EE.Fwd_GETS::total'
FWD_M = 'system.ruby.L1Cache_Controller.MM.Fwd_GETS::total'
LOAD_RE = re.compile(r'^LLC COHERENCE DIR LOAD GEM5-RULE OWNER EVENTS:\s*(\d+)\s*$', re.M)
OTHER_RE = re.compile(r'^LLC COHERENCE DIR OTHER-READ GEM5-RULE OWNER EVENTS:\s*(\d+)\s*$', re.M)


def in_band(x):
    return BAND[0] <= x <= BAND[1]


def clean(txt):
    """the log as QC2 compares it: time stamps masked, the new lines removed"""
    out = []
    for ln in txt.splitlines():
        if NEW in ln:
            continue
        out.append(re.sub(r'\(Simulation time: [^)]*\)', '', ln))
    return out


def qc2(ref_txt, new_txt):
    """'' if the rerun holds QC2 against its reference, else why not"""
    if DONE not in new_txt:
        return 'not complete'
    if not LOAD_RE.search(new_txt) or not OTHER_RE.search(new_txt):
        return 'the new lines are missing'
    a, b = clean(ref_txt), clean(new_txt)
    if a != b:
        i = next((k for k in range(min(len(a), len(b))) if a[k] != b[k]), min(len(a), len(b)))
        return f'differs from its reference apart from the new lines (first at line {i + 1})'
    return ''


def ld_counts(txt):
    m, o = LOAD_RE.search(txt), OTHER_RE.search(txt)
    return int(m.group(1)), int(o.group(1))


def gem5_stats(run):
    """first value of every scalar stat in a run's single dump"""
    s, dumps = {}, 0
    for line in open(os.path.join(G5, run, 'stats.txt')):
        if 'Begin Simulation Statistics' in line:
            dumps += 1
        p = line.split()
        if len(p) >= 2 and p[0] not in s and re.fullmatch(r'-?[0-9.e+]+', p[1]):
            s[p[0]] = float(p[1])
    if dumps != 1:
        sys.exit(f'{run}: {dumps} statistics dumps, expected 1')
    return s


def gem5_window(ga, gb):
    """(MT.L1_GETS, EE.Fwd_GETS, MM.Fwd_GETS, simInsts) in the window; ga None = from the start"""
    B = gem5_stats(gb)
    A = gem5_stats(ga) if ga is not None else {}
    d = tuple(int(B.get(k, 0)) - int(A.get(k, 0)) for k in (GETS, FWD_E, FWD_M, 'simInsts'))
    if GETS not in B:
        sys.exit(f'{gb}: no {GETS}')
    if min(d) < 0:
        sys.exit(f'{ga} -> {gb}: a negative window count {d}')
    return d


def r_ld(L, Ic, M, Ig):
    return (L / Ic) / (M / Ig)


def predictions(res, rho_all, p_all, rho_one):
    """res: {label: R_ld} -> (lines, (P-C1, P-C2, P-C3) as booleans)"""
    lines = []
    n1 = sum(in_band(res[k]) for k in P1)
    for k in P1:
        lines.append(f'   P-C1 {k}: R_ld {res[k]:.3f} {"in" if in_band(res[k]) else "NOT in"} the band')
    c1 = n1 >= 6
    lines.append(f'   P-C1: {n1} of {len(P1)} in [0.5, 2] (needs 6): {"HOLDS" if c1 else "FAILS"}')
    c2 = rho_all >= 0.7 and p_all < 0.05 and rho_one >= 0.7
    lines.append(f'   P-C2: rho {rho_all:+.3f} (permutation p {p_all:.4f}) on the 11 scored; one per program rho {rho_one:+.3f}: '
                 f'{"HOLDS" if c2 else "FAILS"}')
    c3 = all(res[k] < 1 for k in P3)
    lines.append('   P-C3: ' + ', '.join(f'{k} R_ld {res[k]:.3f}' for k in P3) + f': {"HOLDS" if c3 else "FAILS"}')
    return lines, (c1, c2, c3)


def gates():
    """'' if QC0 and QC1 are recorded as passed in the pulled state, else what is missing"""
    miss = [q for q in ('Q0_PASSED', 'Q0M_PASSED', 'K0_PASSED', 'QC1A_PASSED', 'QC1B_PASSED') if not os.path.isfile(os.path.join(LD, q))]
    return ('not passed (or not pulled): ' + ', '.join(miss)) if miss else ''


def collect():
    import lock_fix_score as L
    D, B, sp = L.spans()
    if not L.parser_check(verbose=False):
        sys.exit('the parser check failed: nothing is read')
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    out = []
    for label, role, tree, (_, ga, gb), logroot, _, _ in sp:
        sub = tree[len('phaseA_b3_'):]
        fc = os.path.join(L.NEW, 'phaseA_b3_fc_' + sub)
        ldr = os.path.join(LDLOGS, 'phaseA_b3_ld_' + sub)
        if not os.path.isdir(ldr):
            out.append((label, None, f'no rerun pulled ({os.path.relpath(ldr, ROOT)})'))
            continue
        scored_txt = open(D.runlog(logroot, tree)).read()
        ref_txt = open(D.runlog(L.NEW, os.path.basename(fc))).read()
        why = L.qualify(scored_txt, ref_txt)
        if why:
            out.append((label, None, f'its F-C reference does not qualify: {why}'))
            continue
        new_txt = open(D.runlog(LDLOGS, os.path.basename(ldr))).read()
        why = qc2(ref_txt, new_txt)
        if why:
            out.append((label, None, f'QC2: {why}'))
            continue
        c = L.counts(new_txt)
        Lc, other = ld_counts(new_txt)
        w = B.window(Gr, ga, gb)
        M, fe, fm, ins = gem5_window(ga, gb)
        if ins != int(w['insts']):
            sys.exit(f'{label}: gem5 window instructions {ins} from stats.txt against {w["insts"]} from the rows')
        if M == 0:
            out.append((label, None, 'gem5 MT.L1_GETS is 0 in the window: no ratio'))
            continue
        out.append((label, {'L': Lc, 'other': other, 'Ic': c['ins'], 'M': M, 'Ig': ins, 'fe': fe, 'fm': fm,
                            'R': r_ld(Lc, c['ins'], M, ins)}, ''))
    return out


def rows():
    import panel_stats as PS
    print('# load-side rows (load_side_design_2026-11-18.md): ROW span L x_ChampSim_perKI y_gem5_perKI set other_perKI gem5_EE_fwd_perKI gem5_MM_fwd_perKI')
    bad = 0
    for label, d, why in collect():
        if d is None:
            print(f'# {label}: no row -- {why}')
            bad += 1
            continue
        s = 'scored' if label in PS.SCORED else 'apart'
        ki, gk = (lambda v: 1000.0 * v / d['Ic']), (lambda v: 1000.0 * v / d['Ig'])
        print(f'ROW {label.replace(" ", "_")} L {ki(d["L"]):.6f} {gk(d["M"]):.6f} {s} {ki(d["other"]):.6f} {gk(d["fe"]):.6f} {gk(d["fm"]):.6f}')
    return 1 if bad else 0


def score():
    import panel_stats as PS
    print('== C (load_side_design_2026-11-18.md): R_ld = (L / I_c) / (MT.L1_GETS / I_g)')
    g = gates()
    if g:
        print(f'   NOT SCORED: QC0 / QC1 {g}')
        return 1
    print('   QC0 (Q0, Q0m, K0), QC1a, QC1b: recorded as passed')
    res, rates = {}, {}
    for label, d, why in collect():
        if d is None:
            print(f'   {label}: NOT READ -- {why}')
            continue
        res[label] = d['R']
        rates[label] = (1000.0 * d['L'] / d['Ic'], 1000.0 * d['M'] / d['Ig'])   # rank statistics are on the rates
        tot = d['fe'] + d['fm']
        print(f'   {label}: L {d["L"]} in {d["Ic"]} (OTHER-READ {d["other"]}); gem5 MT.L1_GETS {d["M"]} in {d["Ig"]}; R_ld {d["R"]:.3f}'
              + (f'; gem5 owner side: clean {d["fe"]}, modified {d["fm"]} ({d["fm"] / tot:.1%} modified)' if tot else ''))
    need = [k for k in PS.SCORED if k not in res]
    if need:
        print(f'   NO VERDICT while these scored spans are missing: {", ".join(need)}')
        return 1
    s_all = PS.summary([rates[k] for k in PS.SCORED])
    s_one = PS.summary([rates[k] for k in PS.ONE_PER_PROGRAM])
    lines, (c1, c2, c3) = predictions(res, s_all['rho'], s_all['p'], s_one['rho'])
    print('\n'.join(lines))
    print(f'   reported: on the 11 scored, typical factor x{s_all["gm"]:.2f} (geometric mean of |ln R_ld|), log Pearson {s_all["r_log"]:+.3f}, '
          f'{s_all["inband"]} of 11 in the band')
    print('   READING: R_ld is reported beside R_g5; no existing verdict changes.'
          + ('' if c1 else ' P-C1 failed: the paper says load-side communication is not validated, with the numbers.')
          + (' The paper may say "ChampSim orders programs by load-side communication as gem5 does".' if c2 else ''))
    return 0


def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = (abs(got - want) < 1e-12) if isinstance(want, float) else got == want
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    # R_ld: 50 in 1 M against 100 in 1 M -> 0.5; 300 in 2 M against 100 in 1 M -> 1.5
    check('R_ld', r_ld(50, 1_000_000, 100, 1_000_000), 0.5)
    check('R_ld scaled', r_ld(300, 2_000_000, 100, 1_000_000), 1.5)
    ref = '\n'.join(['Number of CPUs: 2', 'LLC COHERENCE DIR RFO GEM5-RULE EVENTS: 7',
                     'Simulation complete CPU 0 instructions: 20 cycles: 300 cumulative IPC: 0.1 (Simulation time: 00 hr 00 min 01 sec)',
                     DONE, ''])
    new = ref.replace('LLC COHERENCE DIR RFO GEM5-RULE EVENTS: 7',
                      'LLC COHERENCE DIR RFO GEM5-RULE EVENTS: 7\nLLC COHERENCE DIR LOAD GEM5-RULE OWNER EVENTS:         12\n'
                      'LLC COHERENCE DIR OTHER-READ GEM5-RULE OWNER EVENTS:          0').replace('01 sec', '09 sec')
    check('QC2 holds (time masked, new lines removed)', qc2(ref, new), '')
    check('counts', ld_counts(new), (12, 0))
    check('QC2: incomplete', qc2(ref, new.replace(DONE, '')), 'not complete')
    check('QC2: a new line missing', qc2(ref, new.replace('OTHER-READ', 'OTHER-REAX')), 'the new lines are missing')
    check('QC2: an old line differs', qc2(ref, new.replace('RFO GEM5-RULE EVENTS: 7', 'RFO GEM5-RULE EVENTS: 8'))[:8], 'differs ')
    check('QC2: cycles differ', qc2(ref, new.replace('cycles: 300', 'cycles: 301'))[:8], 'differs ')
    # the predictions: 8 P-C1 spans; edges count as in
    base = {k: 1.0 for k in P1}
    base.update({'fluidanimate': 0.4, 'vips': 0.3})
    _, v = predictions(base, 0.8, 0.01, 0.75)
    check('all hold', v, (True, True, True))
    _, v = predictions({**base, 'radix': 2.0, 'lunc': 0.5}, 0.8, 0.01, 0.75)
    check('edges in the band', v[0], True)
    _, v = predictions({**base, 'radix': 2.01, 'lunc': 0.49}, 0.8, 0.01, 0.75)
    check('6 of 8 holds', v[0], True)
    _, v = predictions({**base, 'radix': 2.01, 'lunc': 0.49, 'ocean 2 MB': 3.0}, 0.8, 0.01, 0.75)
    check('5 of 8 fails', v[0], False)
    check('P-C2 fails on p', predictions(base, 0.8, 0.06, 0.75)[1][1], False)
    check('P-C2 fails on rho', predictions(base, 0.69, 0.01, 0.75)[1][1], False)
    check('P-C2 fails one per program', predictions(base, 0.8, 0.01, 0.69)[1][1], False)
    check('P-C2 at the edge', predictions(base, 0.7, 0.0499, 0.7)[1][1], True)
    check('P-C3 fails if one >= 1', predictions({**base, 'vips': 1.0}, 0.8, 0.01, 0.75)[1][2], False)
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
