#!/usr/bin/env python3
"""Score round 2, step 1 (bench/policy_sanity/lock_wait_design_2026-11-06.md):
the prediction from the measured contended waited acquires.

    python3 scripts/lock_wait_score.py            # the reruns pulled by scripts/lockwait_all.sh pull
    python3 scripts/lock_wait_score.py selftest   # the hand cases (no data read)

For each span of round 1 (scripts/disagree_diag.py's SPANS, plus fmm, reported):
  C, I_c   ChampSim's gem5-rule RFO events and instructions, from the scored
           rows (b3_rows_v18, phasea_rows_v27), as in round 1
  G, I_g   gem5's SS + MT L1 GETX and instructions in its window, as in round 1
  N        the rerun's measured contended waited acquires, summed over cores
           (CPU n MUTEX WAITED ACQUIRES: measured contended N ...). Like C, it
           spans the whole measured phase, to the simulation's end.
  R_g5(k) = ((C + k N) / I_c) / (G / I_g),  k = 1, 2
  W_m      measured cycles held for a mutex / the cores' measured cycles
           (Simulation finished CPU n ... cycles), reported only

A rerun is scored only if its log equals the scored log line by line, apart
from the wall clock and the new lines (Q0-full, checked here again on the
pulled files), and prints one waited-acquire line per MUTEX ACQUIRES line.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROOT = os.path.dirname(HERE)
NEW = os.path.join(ROOT, 'simulator/results/lockwait/logs')
BAND = (0.5, 2.0)
FAILING = ['fluidanimate', 'barnes std window', 'barnes std start', 'barnes-256']
AGREEING = ['barnes std force', 'ocean 2 MB', 'canneal 4c 2 MB', 'canneal 8c', 'radix', 'lunc', 'ocean non-contiguous']
REPORTED = ['vips', 'bodytrack', 'fmm']
NEWLINE = 'MUTEX WAITED ACQUIRES'
WAITED = re.compile(r'^CPU (\d+) MUTEX WAITED ACQUIRES: measured contended (\d+) own (\d+) cycles (\d+); warmup contended (\d+) own (\d+)$', re.M)


def waited(txt):
    """{cpu: (measured contended, own, cycles, warm-up contended, own)}"""
    return {int(m[0]): tuple(map(int, m[1:])) for m in WAITED.findall(txt)}


def sim_cycles(txt):
    return sum(int(y) for y in re.findall(r'^Simulation finished CPU \d+ instructions: \d+ cycles: (\d+)', txt, re.M))


def clean(txt):
    return [re.sub(r'\(Simulation time: [^)]*\)', '', ln) for ln in txt.splitlines() if NEWLINE not in ln]


def q0full(old_txt, new_txt):
    """'' if the rerun equals the scored run apart from the new lines, else why not"""
    if 'ChampSim completed all CPUs' not in new_txt:
        return 'the rerun did not complete'
    a = len(re.findall(r'^CPU \d+ MUTEX ACQUIRES:', new_txt, re.M))
    if len(waited(new_txt)) != a or len(re.findall(NEWLINE, new_txt)) != a:
        return f'{len(waited(new_txt))} waited-acquire lines for {a} MUTEX ACQUIRES lines'
    o, n = clean(old_txt), clean(new_txt)
    if o != n:
        i = next((k for k, (x, y) in enumerate(zip(o, n)) if x != y), min(len(o), len(n)))
        return f'differs from the scored log at its line {i + 1} ({len(o)} against {len(n)} lines)'
    return ''


def predict(C, Ic, G, Ig, N):
    base = G / Ig
    return tuple(((C + k * N) / Ic) / base for k in (0, 1, 2))


def in_band(x):
    return BAND[0] <= x <= BAND[1]


def verdict(r):
    """r: {label: (R0, R1, R2)} for the failing and agreeing spans -> (verdict, lines)"""
    lines, l1, short, over = [], 0, 0, []
    for k in FAILING:
        _, r1, r2 = r[k]
        ok = r1 <= BAND[1] and r2 >= BAND[0]           # [R(1), R(2)] meets [0.5, 2]
        l1 += ok
        short += r2 < BAND[0]
        if r1 > BAND[1]:
            over.append(k)
        lines.append(f'   P-L1 {k}: [{r1:.3f}, {r2:.3f}] {"meets" if ok else "misses"} the band'
                     + (' (short: R(2) < 0.5)' if r2 < BAND[0] else ' (over: R(1) > 2)' if r1 > BAND[1] else ''))
    l2 = 0
    for k in AGREEING:
        _, r1, r2 = r[k]
        ok = in_band(r1) and in_band(r2)
        l2 += ok
        if not ok and max(r1, r2) > BAND[1]:
            over.append(k)
        lines.append(f'   P-L2 {k}: R(1) {r1:.3f}, R(2) {r2:.3f} {"both in" if ok else "NOT both in"} the band')
    lines.append(f'   P-L1 holds on {l1} of {len(FAILING)} failing spans ({short} short); P-L2 on {l2} of {len(AGREEING)} agreeing spans')
    if over:
        lines.append(f'   OVERSHOOT on: {", ".join(over)}')
    if l1 >= 3 and l2 == len(AGREEING):
        v = 'H-C2 SUPPORTED: the F-C note is written next'
    elif short >= 3:
        v = 'H-C2 REJECTED: P-L1 falls short on three or more failing spans; F-C is not built'
    elif over:
        v = 'OVERSHOOT: k >= 1 per contended acquire is too many; the next note reads gem5\'s lock-word traffic directly'
    else:
        v = 'PARTIAL, reported as measured'
    return v, lines


def main():
    import disagree_diag as D
    B = D.B
    spans = list(D.SPANS) + [('fmm', 'reported', 'phaseA_b3_g3_fmm4', B.REFS['held']['fmm4'], D.G6LOG, None, None)]
    have = {s[0] for s in spans}
    missing = [k for k in FAILING + AGREEING + REPORTED if k not in have]
    if missing:
        sys.exit(f'spans not defined: {missing}')
    P = B.load(D.PHASEA, B.PHASEA, lambda r: (r['tree'], r['rg']))
    Cr = B.load(D.B3ROWS, B.B3, lambda r: (r['tree'], r['rg']))
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    print('== Round 2 step 1 (lock_wait_design_2026-11-06.md): R_g5(k) = ((C + k N) / I_c) / (G / I_g)')
    res, bad = {}, []
    for label, role, tree, (_, ga, gb), logroot, _, _ in spans:
        c, p = Cr[(tree, 'shared')], P[(tree, 'shared')]
        if p['ins'] != c['ins'] or c['st'] != 'complete':
            sys.exit(f'{tree}: rows disagree or incomplete')
        w = B.window(Gr, ga, gb)
        G, Ig, C, Ic = w['ss_getx'] + w['mt_getx'], w['insts'], int(c['rfo_g5']), int(c['ins'])
        old = D.runlog(logroot, tree)
        newroot = os.path.join(NEW, 'phaseA_b3_lc_' + tree[len('phaseA_b3_'):])
        if not os.path.isdir(newroot):
            print(f'\n== {label} ({role}): NO RERUN pulled ({os.path.relpath(newroot, ROOT)})')
            bad.append(label)
            continue
        new = D.runlog(NEW, os.path.basename(newroot))
        ot, nt = open(old).read(), open(new).read()
        why = q0full(ot, nt)
        if why:
            print(f'\n== {label} ({role}): NOT SCORED -- Q0-full: {why}')
            bad.append(label)
            continue
        wt = waited(nt)
        N = sum(v[0] for v in wt.values())
        own = sum(v[1] for v in wt.values())
        cyc = sum(v[2] for v in wt.values())
        wcon, wown = sum(v[3] for v in wt.values()), sum(v[4] for v in wt.values())
        sc = sim_cycles(nt)
        r = predict(C, Ic, G, Ig, N)
        res[label] = r
        print(f'\n== {label} ({role}); rerun {os.path.relpath(new, ROOT)}; Q0-full holds')
        print(f'   C {C} in I_c {Ic}; G {G} in I_g {Ig}; R_g5 {r[0]:.3f}')
        print(f'   measured waited acquires: contended N {N}, own {own}; warm-up: contended {wcon}, own {wown}; by CPU {wt}')
        print(f'   W_m {cyc} measured cycles held / {sc} measured cycles = {cyc / sc:.4%}' if sc else f'   W_m {cyc} cycles held (no measured cycles)')
        print(f'   R_g5(1) {r[1]:.3f}  R_g5(2) {r[2]:.3f}' + ('   (reported, decides nothing)' if label in REPORTED else ''))
    print('\n== The rules (design § 4)')
    need = [k for k in FAILING + AGREEING if k not in res]
    if need:
        print(f'   NOT SCORED: no verdict while these spans are missing or fail Q0-full: {", ".join(need)}')
        sys.exit(1)
    v, lines = verdict(res)
    print('\n'.join(lines))
    print(f'   VERDICT: {v}')


def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = got == want if not isinstance(want, float) else abs(got - want) < 1e-12
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    # the formula, by hand: C 100 in 1 M, G 400 in 1 M -> 0.25; N 100 -> 0.5, 0.75
    r = predict(100, 1_000_000, 400, 1_000_000, 100)
    check('R0', r[0], 0.25); check('R1', r[1], 0.5); check('R2', r[2], 0.75)
    # different instruction counts: C 30 in 2 M, G 90 in 3 M -> (15/M) / (30/M) = 0.5; N 15 -> 0.75, 1.0
    r = predict(30, 2_000_000, 90, 3_000_000, 15)
    check('R0 scaled', r[0], 0.5); check('R1 scaled', r[1], 0.75); check('R2 scaled', r[2], 1.0)
    # the log parser
    log = ('CPU 0 MUTEX ACQUIRES: 5 CYCLES WAITING FOR A MUTEX: 70\nCPU 1 MUTEX ACQUIRES: 5 CYCLES WAITING FOR A MUTEX: 9\n'
           'CPU 0 MUTEX WAITED ACQUIRES: measured contended 3 own 1 cycles 60; warmup contended 1 own 0\n'
           'CPU 1 MUTEX WAITED ACQUIRES: measured contended 0 own 2 cycles 9; warmup contended 0 own 0\n'
           'Simulation finished CPU 0 instructions: 10 cycles: 1000 cumulative IPC: 0.01 (Simulation time: 00 hr 00 min 01 sec)\n'
           'Simulation finished CPU 1 instructions: 10 cycles: 500 cumulative IPC: 0.02 (Simulation time: 00 hr 00 min 02 sec)\n'
           'ChampSim completed all CPUs\n')
    check('waited', waited(log), {0: (3, 1, 60, 1, 0), 1: (0, 2, 9, 0, 0)})
    check('sim cycles', sim_cycles(log), 1500)
    old = '\n'.join(ln for ln in log.splitlines() if NEWLINE not in ln).replace('00 min 01 sec', '00 min 07 sec')
    check('Q0-full, equal apart from new lines and clock', q0full(old, log), '')
    check('Q0-full, an old line changed', q0full(old.replace('ACQUIRES: 5 CYCLES', 'ACQUIRES: 6 CYCLES', 1), log)[:8], 'differs ')
    check('Q0-full, a waited line missing', q0full(old, log.replace('CPU 1 MUTEX WAITED', 'CPU 1 MUTEX WAITEX'))[:9], '1 waited-')
    check('Q0-full, incomplete', q0full(old, log.replace('ChampSim completed all CPUs', '')), 'the rerun did not complete')
    # the verdicts
    inb, hold, short, over = (1.0, 1.0, 1.0), (0.3, 0.6, 0.9), (0.2, 0.25, 0.3), (0.3, 2.5, 4.7)
    base = {k: inb for k in AGREEING}
    check('SUPPORTED', verdict({**base, **{k: hold for k in FAILING}})[0][:13], 'H-C2 SUPPORTE')
    check('SUPPORTED, 3 of 4', verdict({**base, **{k: hold for k in FAILING[:3]}, FAILING[3]: short})[0][:13], 'H-C2 SUPPORTE')
    check('agreeing span pushed out: not SUPPORTED', verdict({**base, 'radix': (1.5, 2.1, 2.7), **{k: hold for k in FAILING}})[0][:9], 'OVERSHOOT')
    check('REJECTED', verdict({**base, **{k: short for k in FAILING[:3]}, FAILING[3]: hold})[0][:13], 'H-C2 REJECTED')
    check('OVERSHOOT', verdict({**base, **{k: over for k in FAILING[:2]}, **{k: short for k in FAILING[2:]}})[0][:9], 'OVERSHOOT')
    check('PARTIAL', verdict({**base, **{k: hold for k in FAILING[:2]}, **{k: short for k in FAILING[2:]}})[0][:7], 'PARTIAL')
    # the edges of the band count as in it
    check('edges: failing R(2) = 0.5, agreeing R = 2.0',
          verdict({**base, 'radix': (2.0, 2.0, 2.0), **{k: (0.1, 0.4, 0.5) for k in FAILING}})[0][:13], 'H-C2 SUPPORTE')
    check('just past: failing R(2) = 0.4999', verdict({**base, **{k: (0.1, 0.4, 0.4999) for k in FAILING}})[0][:13], 'H-C2 REJECTED')
    print('selftest:', 'PASS' if ok else 'FAILED')
    return ok


if __name__ == '__main__':
    if sys.argv[1:] == ['selftest']:
        sys.exit(0 if selftest() else 1)
    main()
