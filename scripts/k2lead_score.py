#!/usr/bin/env python3
"""K2 step 3, the diagnostic lead limit (bench/policy_sanity/k2_sharing_gap_design_2026-11-17.md,
amendments 2 and 3): the readings fixed in amendment 2, computed with the code that scored F-C.

Written 2026-11-23, after the 8 runs were pulled and before any of their numbers was printed. No
scorer had been written beforehand; this one adds no rule. It uses lock_fix_score's counts()
(R_g5's C and I_c as b3_rows.sh reads them), ratios() and qualify(), and disagree_diag's spans and
gem5 windows, unchanged.

    python3 scripts/k2lead_score.py            # the 8 runs pulled by scripts/k2lead_all.sh pull
    python3 scripts/k2lead_score.py selftest

Order:
  1. lock_fix_score's parser check on the 14 scored logs (must reproduce the committed rows);
  2. each span's F-C reference recomputed: R_g5 must equal amendment 2's fixed values to 3 decimals
     (fluidanimate 0.400, vips 0.308, canneal 4c 1.018, ocean 0.712); otherwise nothing is read;
  3. each run: qualify() against its F-C log (window, CPU count, traces, level 2, request line, Q3,
     no wrap...), plus one "SYNC LEAD LIMIT: <Delta> instructions" line with the run's Delta;
  4. the readings: primary = fluidanimate at Delta 100,000, rise in R_g5 over its F-C value
     >= 0.15 -> timing SUPPORTED, else NOT SUPPORTED by this test; specificity = either control
     (canneal 4c, ocean) moving by >= 0.15 at that Delta adds "not specific to fluidanimate";
     reported: every run's R_g5, R_b, traffic, cycles, lead-held cycles and max lead.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)
K2 = os.path.join(ROOT, 'simulator/results/k2lead/logs')
FC = os.path.join(ROOT, 'simulator/results/lockfix/logs')
FIXED = {'fluidanimate': 0.400, 'vips': 0.308, 'canneal 4c 2 MB': 1.018, 'ocean 2 MB': 0.712}
NAME = {'fluidanimate': 'fluidanimate4', 'vips': 'vips4', 'canneal 4c 2 MB': 'canneal4', 'ocean 2 MB': 'ocean4'}
DELTAS = (('1m', 1000000), ('100k', 100000))
RISE = 0.15
LEAD = re.compile(r'^CPU (\d+) LEAD HOLDS: cycles measured (\d+) warmup (\d+); max lead (\d+)$', re.M)
LIMIT = re.compile(r'^SYNC LEAD LIMIT: (\d+) instructions$', re.M)
PROT = re.compile(r'^LLC COHERENCE DIR RFO PROTOCOL-OTHER EVENTS.*?(\d+)$', re.M)   # b3_rows.sh val(): first line, last number


def lead(txt):
    """(held cycles measured, largest max lead, per-CPU max leads)"""
    m = LEAD.findall(txt)
    return sum(int(x[1]) for x in m), max((int(x[3]) for x in m), default=None), [int(x[3]) for x in m]


def check_run(fc_txt, txt, delta):
    import lock_fix_score as L
    why = L.qualify(fc_txt, txt)
    if why:
        return why
    lim = LIMIT.findall(txt)
    if lim != [str(delta)]:
        return f'lead limit lines {lim}, not [{delta}]'
    n = int(re.search(r'^Number of CPUs: (\d+)', txt, re.M).group(1))
    if len(LEAD.findall(txt)) != n:
        return f'{len(LEAD.findall(txt))} LEAD HOLDS lines for {n} CPUs'
    return ''


def r_b(txt, c, w):
    m = PROT.search(txt)
    G, Ig = w['ss_getx'] + w['mt_getx'], w['insts']
    return (int(m.group(1)) / c['ins']) / (G / Ig) if m else None


def reading(r):
    """r: {(label, dk): R_g5}, ref: FIXED -> lines"""
    out = []
    f = r.get(('fluidanimate', '100k'))
    if f is None:
        return ['   PRIMARY: NOT READ -- fluidanimate at Delta 100,000 did not qualify']
    rise = f - FIXED['fluidanimate']
    out.append(f'   PRIMARY fluidanimate, Delta 100,000: R_g5 {f:.3f} against F-C {FIXED["fluidanimate"]:.3f}, rise {rise:+.3f} '
               f'(>= +{RISE}): timing {"SUPPORTED" if rise >= RISE else "NOT SUPPORTED by this test"}')
    moved = [k for k in ('canneal 4c 2 MB', 'ocean 2 MB') if (k, '100k') in r and abs(r[(k, '100k')] - FIXED[k]) >= RISE]
    out.append('   SPECIFICITY: ' + (f'{", ".join(moved)} also moved by >= {RISE}: "not specific to fluidanimate"' if moved
                                      else f'neither control moved by {RISE} or more at Delta 100,000'))
    return out


def main():
    import lock_fix_score as L
    D, B, sp = L.spans()
    print('== K2 step 3: the diagnostic lead limit (k2_sharing_gap_design_2026-11-17.md, amendment 2)')
    if not L.parser_check(verbose=False):
        sys.exit(1)
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    spans = {s[0]: s for s in sp}
    ref, ok = {}, True
    print('== F-C references, recomputed (must equal amendment 2\'s fixed values)')
    for label in FIXED:
        _, _, tree, (_, ga, gb), _, _, _ = spans[label]
        w = B.window(Gr, ga, gb)
        fct = open(D.runlog(FC, 'phaseA_b3_fc_' + tree[len('phaseA_b3_'):])).read()
        c = L.counts(fct)
        r, tr, _ = L.ratios(c, w)
        good = round(r, 3) == FIXED[label]
        ok &= good
        ref[label] = (fct, c, w, r, tr)
        print(f'   {label}: F-C R_g5 {r:.3f} ({"= the fixed" if good else "DIFFERS from the fixed"} {FIXED[label]:.3f}); traffic {tr:.3f}; max cycles {c["maxcyc"]}')
    if not ok:
        sys.exit('NOTHING READ: a reference differs from the value fixed in amendment 2')
    res = {}
    for label in FIXED:
        fct, fc_c, w, fr, ftr = ref[label]
        for dk, delta in DELTAS:
            tree = f'phaseA_b3_k2d{dk}_{NAME[label]}'
            p = os.path.join(K2, tree)
            if not os.path.isdir(p):
                print(f'\n== {label} at Delta {delta:,}: NO RUN pulled')
                continue
            txt = open(D.runlog(K2, tree)).read()
            why = check_run(fct, txt, delta)
            if why:
                print(f'\n== {label} at Delta {delta:,}: NOT READ -- {why}')
                continue
            c = L.counts(txt)
            r, tr, u = L.ratios(c, w)
            rb, frb = r_b(txt, c, w), r_b(fct, fc_c, w)
            held, mx, per = lead(txt)
            res[(label, dk)] = r
            print(f'\n== {label} at Delta {delta:,} ({tree}): qualifies')
            print(f'   R_g5 {r:.3f} (F-C {fr:.3f}, {r - fr:+.3f}); R_b {rb:.3f} (F-C {frb:.3f}); traffic {tr:.3f} (F-C {ftr:.3f})')
            print(f'   max cycles {c["maxcyc"]} ({(c["maxcyc"] - fc_c["maxcyc"]) / fc_c["maxcyc"]:+.2%} against F-C); '
                  f'lead-held cycles measured {held}; max lead per CPU {per}')
    print('\n== Readings (amendment 2, fixed)')
    print('\n'.join(reading(res)))
    return 0


def selftest():
    good = True

    def check(name, got, want):
        nonlocal good
        g = got == want
        good &= g
        print(f'   {"ok  " if g else "FAIL"} {name}: {got!r}' + ('' if g else f' (want {want!r})'))
    t = 'CPU 0 LEAD HOLDS: cycles measured 10 warmup 5; max lead 100352\nCPU 1 LEAD HOLDS: cycles measured 0 warmup 0; max lead 7\n'
    check('lead lines', lead(t), (10, 100352, [100352, 7]))
    base = {('canneal 4c 2 MB', '100k'): 1.018, ('ocean 2 MB', '100k'): 0.712}
    def with_f(v):
        return {**base, ('fluidanimate', '100k'): v}
    check('rise 0.150 supported', reading(with_f(0.550))[0].endswith('timing SUPPORTED'), True)
    check('rise 0.149 not supported', 'NOT SUPPORTED' in reading(with_f(0.549))[0], True)
    check('a fall of 0.217 not supported', 'NOT SUPPORTED' in reading(with_f(0.183))[0], True)
    check('a control moving 0.15 is named', 'canneal' in reading({**with_f(0.6), ('canneal 4c 2 MB', '100k'): 1.17})[1], True)
    check('a control falling 0.555 is named', 'ocean' in reading({**with_f(0.6), ('ocean 2 MB', '100k'): 0.157})[1], True)
    check('controls still: neither', 'neither' in reading(with_f(0.6))[1], True)
    check('no primary: not read', 'NOT READ' in reading(base)[0], True)
    print('selftest PASS' if good else 'selftest FAILED')
    return 0 if good else 1


if __name__ == '__main__':
    a = sys.argv[1:]
    if a == ['selftest']:
        sys.exit(selftest())
    if not a:
        sys.exit(main())
    sys.exit(__doc__)
