#!/usr/bin/env python3
"""H2, the band's noise floor (bench/policy_sanity/calibration_design_2026-11-14.md),
fixed before any perturbed gem5 run or re-trace exists.

    cal_score.py qv0 ORIG_DIR NEW_DIR SECTION:KEY=VALUE   (server) the same configuration but the declared line?
    cal_score.py qv1 NEW_DIR [ENDED]                      (server) ended at its instruction stop?
    cal_score.py rows [DIR]        > bench/policy_sanity/cal_gem5_rows_vN.txt
                                   the pulled perturbed gem5 runs as gem5 rows (b3_score.py's columns)
    cal_score.py score CAL_GEM5_ROWS [label=R ...]
    cal_score.py selftest          hand cases, no data read

QV0: NEW_DIR/config.ini equals ORIG_DIR/config.ini once ORIG_DIR's path is read
as NEW_DIR's, except KEY in [SECTION], which must change to VALUE (exactly one
line). Exit 0 = PASS, 1 = FAIL.
QV1 (once gem5 has ended): exit 0 = ENDED-AT-STOP ("because a thread reached
the max instruction count", one statistics dump), 4 = OTHER, 5 = not ended.

score, per program p (ocean 2 MB, canneal 4c 2 MB, lunc, fluidanimate):
  C_k   ChampSim gem5-rule RFO events per KI on trace set k: 0 = the F-C
        reference run (simulator/results/lockfix/logs), 1..5 = the re-traces'
        replays (simulator/results/cal/logs), read as lock_fix_score reads them
        (its parser check on the 14 scored logs first); a replay is used only
        if it qualifies (lock_fix_score.qualify against the reference, its
        traces the r<k> set's with the same names in the same order)
  G_j   gem5 SS + MT L1_GETX per KI in the window (150 M stop - 50 M stop), at
        latency j: 10 ns = the scored runs (gem5_b3_rows_v6.txt), 8/9/11/12 ns =
        H2's runs (CAL_GEM5_ROWS); a window b3_score.window refuses is not measured
  R_kj  C_k / G_j; s_c = stdev(ln C_k) (n - 1, needs 4), s_g = stdev(ln G_j)
        (needs 3), s_p = sqrt(s_c^2 + s_g^2); s* = the largest s_p (needs 2 programs)
  label ln R +- 1.645 s*: ROBUSTLY IN (inside [0.5, 2]), ROBUSTLY OUT (wholly
        outside), NEAR THE EDGE; for the 14 F-C spans and any label=R given.
        s* >= ln 2 / 1.645 (0.4214): no R can be robustly in -- said.
"""
import math
import os
import re
import shutil
import statistics
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CAL_LOGS = os.environ.get('CAL_LOGS', os.path.join(ROOT, 'simulator/results/cal/logs'))    # a rehearsal points these elsewhere
CAL_GEM5 = os.environ.get('CAL_GEM5', os.path.join(ROOT, 'simulator/results/cal/gem5'))
BAND = (0.5, 2.0)
Z = 1.645
LATS = (8, 9, 11, 12)
K = (1, 2, 3, 4, 5)
EXIT_OK = 'because a thread reached the max instruction count'
# program (PROGS name) -> (F-C span label, ChampSim tree suffix, gem5 tag, reference trace set)
PROGRAMS = {
    'ocean4': ('ocean 2 MB', 'ocean4', 'ocean_4c', 'sync_mx/ocean4'),
    'canneal4': ('canneal 4c 2 MB', 'canneal4', 'canneal_4c', 'sync_mx/canneal4'),
    'lunc': ('lunc', 'lunc4', 'lunc_4c', 'sync_nb/lunc'),
    'fluidanimate': ('fluidanimate', 'fluidanimate4', 'fluidanimate_4c', 'sync_h2/fluidanimate'),
}


# ---------------------------------------------------------------- server side
def sections(path, orig_dir=None, new_dir=None):
    out, sec = [], None
    for ln in open(path).read().splitlines():
        if orig_dir:
            ln = ln.replace(orig_dir.rstrip('/'), new_dir.rstrip('/'))
        if ln.startswith('['):
            sec = ln
        out.append((sec, ln))
    return out


def qv0(orig_dir, new_dir, declared, out=print):
    m = re.fullmatch(r'([^:]+):([A-Za-z_0-9]+)=(.*)', declared)
    if not m:
        out(f'QV0 FAIL: cannot read the declared change "{declared}" (SECTION:KEY=VALUE)')
        return False
    dsec, dkey, dval = '[' + m.group(1) + ']', m.group(2), m.group(3)
    a = sections(os.path.join(orig_dir, 'config.ini'), orig_dir, new_dir)
    b = sections(os.path.join(new_dir, 'config.ini'))
    bad, changed = [], 0
    if len(a) != len(b):
        bad.append(f'{len(a)} lines in the original, {len(b)} in the new run')
    for (sa, la), (sb, lb) in zip(a, b):
        if sa == dsec and la.startswith(dkey + '='):
            if lb == f'{dkey}={dval}' and la != lb and sb == sa:
                changed += 1
                continue
            bad.append(f'{sa} original "{la}", new "{lb}" (declared {dkey}={dval})')
            continue
        if la != lb:
            bad.append(f'{sa}: original "{la}", new "{lb}"')
    if changed != 1:
        bad.append(f'the declared line changed {changed} times, not once')
    for x in bad[:12]:
        out('   QV0: ' + x)
    out(f'QV0 {"PASS" if not bad else "FAIL"}: {dsec} {dkey} -> {dval}' + ('' if not bad else f'; {len(bad)} problem(s)'))
    return not bad


def qv1(new_dir, ended=True, out=print):
    if not ended:
        out('QV1 RUNNING')
        return 5
    lp, sp = os.path.join(new_dir, 'run.log'), os.path.join(new_dir, 'stats.txt')
    log = open(lp, errors='replace').read() if os.path.exists(lp) else ''
    dumps = open(sp).read().count('Begin Simulation Statistics') if os.path.exists(sp) else 0
    if EXIT_OK in log and dumps == 1:
        ft = re.search(r'^finalTick\s+(\d+)', open(sp).read(), re.M)
        out(f'QV1 ENDED-AT-STOP finalTick {ft.group(1) if ft else "?"}')
        return 0
    tail = [ln for ln in log.splitlines() if ln.strip()][-1:] or ['<empty run.log>']
    out(f'QV1 OTHER: {dumps} statistics dump(s); last line: {tail[0][:160]}')
    return 4


# ---------------------------------------------------------------- laptop side
def label(r, s):
    """ROBUSTLY IN / ROBUSTLY OUT / NEAR THE EDGE for one R and a spread s"""
    lo, hi = math.log(r) - Z * s, math.log(r) + Z * s
    blo, bhi = math.log(BAND[0]), math.log(BAND[1])
    if lo >= blo - 1e-12 and hi <= bhi + 1e-12:
        return 'ROBUSTLY IN', math.exp(lo), math.exp(hi)
    if hi < blo or lo > bhi:
        return 'ROBUSTLY OUT', math.exp(lo), math.exp(hi)
    return 'NEAR THE EDGE', math.exp(lo), math.exp(hi)


def spread(values, need):
    """stdev of ln(values), n - 1; None below NEED values"""
    v = [math.log(x) for x in values if x is not None and x > 0]
    return statistics.stdev(v) if len(v) >= need else None


def cal_lines(txt):
    return [ln.split(' runs ', 1)[1] for ln in txt.splitlines() if re.match(r'^CPU \d+ runs ', ln)]


def qualify_cal(ref_txt, new_txt, k, prog, refset):
    """'' if the replay of re-trace K qualifies against the F-C reference, else why not"""
    import lock_fix_score as L
    a, b = cal_lines(ref_txt), cal_lines(new_txt)
    if len(a) != len(b) or not a:
        return f'{len(b)} trace lines for the reference\'s {len(a)}'
    for x, y in zip(a, b):
        if os.path.basename(x) != os.path.basename(y):
            return f'trace {os.path.basename(y)} where the reference has {os.path.basename(x)}'
        if f'/traces/{refset}/' not in x:
            return f'the reference trace {x} is not under traces/{refset}/'
        if not y.endswith(f'/traces/cal/r{k}/{prog}/{os.path.basename(y)}'):
            return f'trace {y} is not the r{k} set\'s'
    mapped = new_txt
    for x, y in zip(a, b):
        mapped = mapped.replace(f' runs {y}\n', f' runs {x}\n')
    return L.qualify(ref_txt, mapped)


# spans in the lock-fix set whose R the paper reports but does not score (their checks failed before
# the lock fix); their label is printed with this note so it is never read as a verdict
UNSCORED = {'bodytrack': 'not scored: fails QW', 'fmm': 'not scored: fails the same-stream check'}


def fc_spans():
    """the 14 F-C spans' (label, R_g5) as lock_fix_score computes them"""
    import lock_fix_score as L
    D, B, sp = L.spans()
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    out, win = [], {}
    for lab, _, tree, (_, ga, gb), _, _, _ in sp:
        w = B.window(Gr, ga, gb)
        win[lab] = w
        new = 'phaseA_b3_fc_' + tree[len('phaseA_b3_'):]
        if not os.path.isdir(os.path.join(L.NEW, new)):
            out.append((lab, None, 'no F-C rerun pulled'))
            continue
        c = L.counts(open(D.runlog(L.NEW, new)).read())
        out.append((lab, L.ratios(c, w)[0], ''))
    return out, win, D, B, L


def score(cal_rows, extra):
    import lock_fix_score as L
    print('== H2 (calibration_design_2026-11-14.md): the band\'s noise floor')
    print('== the parser, on the 14 scored logs')
    if not L.parser_check(verbose=False):
        sys.exit(1)
    spans, win, D, B, L = fc_spans()
    Cg = B.load(cal_rows, B.GEM5, lambda r: r['run']) if cal_rows else {}
    sp_of = {}
    for prog, (lab, suf, tag, refset) in PROGRAMS.items():
        print(f'\n== {lab} ({prog})')
        tree = [s for s in L.spans()[2] if s[0] == lab][0][2]
        ref_log = D.runlog(L.NEW, 'phaseA_b3_fc_' + tree[len('phaseA_b3_'):])
        ref_txt = open(ref_log).read()
        # gem5 side
        G = {10: win[lab]}
        for j in LATS:
            a, b = f'{prog}/b{j}ns/l2_2MB_mi50M/{tag}', f'{prog}/b{j}ns/l2_2MB_mi150M/{tag}'
            if a not in Cg or b not in Cg:
                print(f'   gem5 {j} ns: not measured (no row for {"both stops" if a not in Cg and b not in Cg else (a if a not in Cg else b)})')
                continue
            try:
                G[j] = B.window(Cg, a, b)
            except SystemExit as e:
                print(f'   gem5 {j} ns: not measured ({e})')
        g = {j: 1000.0 * (w['ss_getx'] + w['mt_getx']) / w['insts'] for j, w in G.items()}
        for j in sorted(G):
            same = j != 10 and all(G[j][x] == G[10][x] for x in ('insts', 'ss_getx', 'mt_getx', 'ss_upgrade', 'getx_all', 'demand_acc', 'demand_hits'))
            print(f'   gem5 {j:2d} ns: {G[j]["ss_getx"] + G[j]["mt_getx"]} events in {G[j]["insts"]} instr = {g[j]:.4f}/KI'
                  + ('  (window equal to the scored one: absorbed)' if same else ''))
        # ChampSim side
        Cc = {0: L.counts(ref_txt)}
        for k in K:
            d = os.path.join(CAL_LOGS, f'phaseA_b3_cal{k}_{suf}')
            if not os.path.isdir(d):
                print(f'   trace set r{k}: not measured (no replay pulled)')
                continue
            nt = open(D.runlog(CAL_LOGS, f'phaseA_b3_cal{k}_{suf}')).read()
            why = qualify_cal(ref_txt, nt, k, prog, refset)
            if why:
                print(f'   trace set r{k}: NOT USED -- {why}')
                continue
            Cc[k] = L.counts(nt)
        c = {k: 1000.0 * v['C'] / v['ins'] for k, v in Cc.items()}
        for k in sorted(c):
            print(f'   trace set {"ref" if k == 0 else "r" + str(k)}: {Cc[k]["C"]} events in {Cc[k]["ins"]} instr = {c[k]:.4f}/KI')
        R = {(k, j): c[k] / g[j] for k in c for j in g if g[j]}
        if R:
            print('   R_kj (rows: trace sets; columns: gem5 latency, ns)')
            print('        ' + ''.join(f'{j:>8d}' for j in sorted(g)))
            for k in sorted(c):
                print(f'   {"ref" if k == 0 else "r" + str(k):>4s} ' + ''.join(f'{R[(k, j)]:8.3f}' for j in sorted(g)))
            v = list(R.values())
            gm = math.exp(sum(math.log(x) for x in v) / len(v))
            print(f'   {len(v)} values: min {min(v):.3f}, max {max(v):.3f}, geometric mean {gm:.3f}; in the band {sum(BAND[0] <= x <= BAND[1] for x in v)} of {len(v)}')
        s_c, s_g = spread(c.values(), 4), spread(g.values(), 3)
        s_p = math.sqrt(s_c ** 2 + s_g ** 2) if s_c is not None and s_g is not None else None
        fmt = lambda x: 'not measured' if x is None else f'{x:.4f}'
        print(f'   s_c {fmt(s_c)} ({len(c)} trace sets), s_g {fmt(s_g)} ({len(g)} latencies), s_p {fmt(s_p)}')
        if s_p is not None:
            r0 = c[0] / g[10]
            lb, lo, hi = label(r0, s_p)
            print(f'   own interval: R {r0:.3f}, {lo:.3f} to {hi:.3f}: {lb}')
            sp_of[prog] = s_p
    print('\n== s*')
    if len(sp_of) < 2:
        print(f'   s* NOT SET: s_p measured on {len(sp_of)} program(s), 2 needed -- no labels')
        return
    s_star = max(sp_of.values())
    print(f'   s* = {s_star:.4f} (the largest s_p of {len(sp_of)}: ' + ', '.join(f'{p} {v:.4f}' for p, v in sp_of.items()) + ')')
    if Z * s_star >= math.log(2) - 1e-12:
        print(f'   s* >= {math.log(2) / Z:.4f}: NO R CAN BE ROBUSTLY IN -- the band is narrower than the measured noise')
    print('\n== labels: ln R +- 1.645 s* against [0.5, 2] (the verdicts stand as scored)')
    rows = [(lab, r, why) for lab, r, why in spans] + [(x.split('=', 1)[0], float(x.split('=', 1)[1]), '') for x in extra]
    for lab, r, why in rows:
        if r is None:
            print(f'   {lab:24s} {why}')
            continue
        lb, lo, hi = label(r, s_star)
        print(f'   {lab:24s} R {r:.3f}  interval {lo:.3f} to {hi:.3f}  {lb}' + (f'  ({UNSCORED[lab]})' if lab in UNSCORED else ''))


def rows(root):
    import b3_score as B
    B.gem5_rows(root)


# ---------------------------------------------------------------- self-test
def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = (abs(got - want) < 1e-9) if isinstance(want, float) else got == want
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    e = math.exp
    # (0, 0.1, -0.1, 0.2): mean 0.05, squares 0.0025 0.0025 0.0225 0.0225 = 0.05 / 3
    check('s over 4 values', spread([e(0), e(0.1), e(-0.1), e(0.2)], 4), math.sqrt(0.05 / 3))
    check('s needs 4: 3 given', spread([1, 2, 3], 4), None)
    check('s_g needs 3: 3 given', spread([e(0), e(0.1), e(0.2)], 3), 0.1)
    check('lunc 1.830, s* 0.05: in', label(1.830, 0.05)[0], 'ROBUSTLY IN')
    check('lunc 1.830, s* 0.06: near', label(1.830, 0.06)[0], 'NEAR THE EDGE')
    check('0.400, s* 0.13: out', label(0.400, 0.13)[0], 'ROBUSTLY OUT')
    check('0.400, s* 0.14: near', label(0.400, 0.14)[0], 'NEAR THE EDGE')
    check('2.5, s* 0.1: out above', label(2.5, 0.1)[0], 'ROBUSTLY OUT')
    check('0.5 exactly, s* 0: in (edges inclusive)', label(0.5, 0.0)[0], 'ROBUSTLY IN')
    check('1.0, s* 0.43 (>= 0.4214): near', label(1.0, 0.43)[0], 'NEAR THE EDGE')
    check('1.0, s* 0.42 (< 0.4214): in', label(1.0, 0.42)[0], 'ROBUSTLY IN')
    check('interval of 1.0 at s* 0.1', round(label(1.0, 0.1)[2], 6), round(e(0.1645), 6))
    # QV0 on a synthetic config
    tmp = tempfile.mkdtemp(prefix='cal_selftest_')
    q = lambda *a: None
    try:
        o, n = os.path.join(tmp, 'orig'), os.path.join(tmp, 'new')
        os.makedirs(o)
        os.makedirs(n)
        base = ('[root]\ntype=Root\n\n[system.mem_ctrls]\ntype=MemCtrl\nstatic_backend_latency=10000\nstatic_frontend_latency=10000\n'
                f'\n[system.workload]\ncwd={o}\ninput={o}/in.txt\n')
        open(os.path.join(o, 'config.ini'), 'w').write(base)
        good = base.replace(o, n).replace('static_backend_latency=10000', 'static_backend_latency=8000')
        open(os.path.join(n, 'config.ini'), 'w').write(good)
        D = 'system.mem_ctrls:static_backend_latency=8000'
        check('QV0 the declared change passes', qv0(o, n, D, q), True)
        open(os.path.join(n, 'config.ini'), 'w').write(good.replace('static_frontend_latency=10000', 'static_frontend_latency=9000'))
        check('QV0 another line changed fails', qv0(o, n, D, q), False)
        open(os.path.join(n, 'config.ini'), 'w').write(base.replace(o, n))
        check('QV0 the declared line unchanged fails', qv0(o, n, D, q), False)
        open(os.path.join(n, 'config.ini'), 'w').write(good.replace('=8000', '=9000'))
        check('QV0 another value fails', qv0(o, n, D, q), False)
        open(os.path.join(n, 'config.ini'), 'w').write(good + '[system.extra]\nx=1\n')
        check('QV0 an extra section fails', qv0(o, n, D, q), False)
        # QV1
        open(os.path.join(n, 'run.log'), 'w').write('Exiting @ tick 99 ' + EXIT_OK + '\n')
        open(os.path.join(n, 'stats.txt'), 'w').write('---------- Begin Simulation Statistics ----------\nfinalTick 99\n')
        check('QV1 normal end', qv1(n, True, q), 0)
        check('QV1 not ended', qv1(n, False, q), 5)
        open(os.path.join(n, 'run.log'), 'w').write('panic: FIFO ordering violated\n')
        check('QV1 a panic -> OTHER', qv1(n, True, q), 4)
        open(os.path.join(n, 'run.log'), 'w').write('Exiting @ tick 99 ' + EXIT_OK + '\n')
        open(os.path.join(n, 'stats.txt'), 'w').write('---------- Begin Simulation Statistics ----------\n' * 2)
        check('QV1 two dumps -> OTHER', qv1(n, True, q), 4)
    finally:
        shutil.rmtree(tmp)
    # the replay's trace mapping (lock_fix_score.qualify's own cases are its self-test's)
    S = '/h/sim/traces'
    ref = '\n'.join(['Number of CPUs: 2', f'CPU 0 runs {S}/sync_mx/ocean4/raw0.champsimtrace.xz', f'CPU 1 runs {S}/sync_mx/ocean4/raw1.champsimtrace.xz',
                     'Warmup Instructions: 10', 'Simulation Instructions: 20', 'PRIVATE-CACHE COHERENCE LEVEL: 2',
                     'cpu0_L1D COHERENCE DIR SELF-CHECK MISMATCHES: 0', 'LLC COHERENCE DIR STALE-HOLDER VIOLATIONS: 0',
                     'LLC COHERENCE DIR PRIVATE CACHES REGISTERED: 6', 'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED: 0',
                     'CPU 0 MUTEX WAITED ACQUIRES: measured contended 0 own 0 cycles 0; warmup contended 0 own 0',
                     'SYNC LOCK WORD: request', 'CPU 0 LOCK-WORD REQUESTS: measured 0 warmup 0', 'ChampSim completed all CPUs', ''])
    new = ref.replace(f'{S}/sync_mx/ocean4/', f'{S}/cal/r2/ocean4/')
    check('replay of r2 qualifies', qualify_cal(ref, new, 2, 'ocean4', 'sync_mx/ocean4'), '')
    check('a trace of r3 in an r2 replay', qualify_cal(ref, new.replace('r2/ocean4/raw1', 'r3/ocean4/raw1'), 2, 'ocean4', 'sync_mx/ocean4')[:8], 'trace /h')
    swapped = new.replace('raw0.champ', 'rawX.champ').replace('raw1.champ', 'raw0.champ').replace('rawX.champ', 'raw1.champ')
    check('traces in another order', qualify_cal(ref, swapped, 2, 'ocean4', 'sync_mx/ocean4')[:9], 'trace raw')
    check('the scored set itself is not a re-trace', qualify_cal(ref, ref, 2, 'ocean4', 'sync_mx/ocean4')[:9], 'trace /h/')
    check('another length', qualify_cal(ref, new.replace('Simulation Instructions: 20', 'Simulation Instructions: 21'), 2, 'ocean4', 'sync_mx/ocean4')[:9], 'its lengt')
    check('Q3 in a replay', qualify_cal(ref, new.replace('UNEXPLAINED: 0', 'UNEXPLAINED: 3'), 2, 'ocean4', 'sync_mx/ocean4')[:2], 'Q3')
    print('SELF-TEST ' + ('PASSES' if ok else 'FAILS'))
    return 0 if ok else 1


def main():
    a = sys.argv[1:]
    if a == ['selftest']:
        sys.path.insert(0, HERE)
        return selftest()
    if len(a) == 4 and a[0] == 'qv0':
        return 0 if qv0(a[1], a[2], a[3]) else 1
    if len(a) in (2, 3) and a[0] == 'qv1':
        return qv1(a[1], (a[2] if len(a) == 3 else '1') == '1')
    if a and a[0] == 'rows' and len(a) <= 2:
        sys.path.insert(0, HERE)
        rows(a[1] if len(a) == 2 else CAL_GEM5)
        return 0
    if a and a[0] == 'score' and len(a) >= 2:
        sys.path.insert(0, HERE)
        score(a[1], a[2:])
        return 0
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main())
