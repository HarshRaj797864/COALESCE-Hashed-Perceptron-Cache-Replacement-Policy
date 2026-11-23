#!/usr/bin/env python3
"""Part C's scorer (bench/policy_sanity/breadth_bc_design_2026-11-10.md,
Part C, amendment 1's C at 16 cores, amendment 6 = Note 4). Written and
self-tested before any Part C log was read.

    partC_score.py c0 DIR                     C0: Part A's E1 on every <p>_<c>.up.log / <p>_<c>.oursoff.log pair in DIR
    partC_score.py rows DIR REFROOT           one row per log: the stock logs in DIR (up, oursoff) and each
                                              pair's reference (ours) under REFROOT (the pulled result trees)
    partC_score.py score ROWS GEM5_ROWS PARTB_DIR PROGRAMS
                                              M1, M2 per pair; C1 and C2 per core count over the programs PROGRAMS
                                              names for it (lines "4: ocean canneal ...": those scored and
                                              discriminating in B at that count, as B's results note lists them)
    partC_score.py selftest                   made-up logs and gem5 rows with hand-known answers

DEFINITIONS (Part C, "Measures"; per 1,000 instructions of each window)
  ChampSim      the Region of Interest block of the log, summed over cores, as
                run_phase_a.sh's rows read it; instructions = the sum of the
                "Simulation complete CPU n instructions:" lines
  gem5 window   the run stopped at the high stop minus the run stopped at the
                low stop (b3_score.py's window(); 4 cores: b3_score.REFS; 8 and
                16 cores: Part B's runs, stops from PARTB_DIR/<key>/GEM5)
  M1            ChampSim LLC (total - writeback) accesses per KI over gem5's L2
                demand accesses per KI (P10 / P17's traffic)
  M2            ChampSim LLC (load + RFO) misses per KI over gem5's L2 demand
                misses (demand accesses - demand hits) per KI
  C1 (primary)  at a core count: |ln M2(ours)| <= |ln M2(stock)| for at least two
                thirds of the programs listed for it
  C2            the same on M1, reported with its count
  stock         the upstream log (up); ours-off is used only for C0
"""
import math
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import b3_score          # noqa: E402  (window, load, GEM5, REFS)
import upstream_equiv    # noqa: E402  (compare, allow_patterns, lines)

DONE = 'ChampSim completed all CPUs'
ROW = 'prog cores side st ins load_acc load_hit rfo_acc rfo_hit wr_acc tot_acc'.split()
PROGS15 = 'ocean oceannc radix barnes lunc fft volrend waternsq raytrace fmm canneal streamcluster fluidanimate vips bodytrack'.split()


def tree_of(p, c):
    """partC_server.sh's reference trees, the same table"""
    if c == 4:
        if p in ('ocean', 'canneal', 'radix', 'waternsq'):
            return f'phaseA_b3_g3_{p}4'
        if p == 'barnes':
            return 'phaseA_b3_g3_barnesstd4'
        if p in ('fft', 'volrend', 'fmm'):
            return f'phaseA_b3_b1_{p}4'
        if p in ('lunc', 'raytrace'):
            return f'phaseA_b3_n2_{p}4'
        return f'phaseA_b3_h2_{p}4'
    if c == 8:
        return 'phaseA_b3_g3_canneal8' if p == 'canneal' else f'phaseA_b3_b2_{p}8'
    return 'phaseA_b3_p2_canneal16' if p == 'canneal' else f'phaseA_b3_b16_{p}16'


def gem5_pair(p, c, partb):
    """(low run, high run) as gem5 rows name them"""
    if c == 4:
        key = 'barnesstd4' if p == 'barnes' else f'{p}4'
        for ref in ('', 'held', 'new', 'set2', 'std'):
            if key in b3_score.REFS[ref] and not (ref == '' and p == 'barnes'):
                _, a, b = b3_score.REFS[ref][key]
                return a, b
        sys.exit(f'no gem5 reference for {p} at 4 cores')
    if c == 8 and p == 'canneal':
        _, a, b = b3_score.REFS['e8']['canneal8']
        return a, b
    k = f'{p}_{c}'
    f = os.path.join(partb, k, 'GEM5')
    if not os.path.exists(f):
        return None
    g = open(f).read().split('|')
    lo, hi = int(g[8]), int(g[9])
    return (f'partB/{k}/l2_2MB_mi{lo // 1000000}M/{k}c', f'partB/{k}/l2_2MB_mi{hi // 1000000}M/{k}c')


def parse_log(path):
    """-> dict of ROW's numeric fields and st, as run_phase_a.sh's rows read a log"""
    roi = False
    d = dict(load_acc=0, load_hit=0, rfo_acc=0, rfo_hit=0, wr_acc=0, tot_acc=0, ins=0)
    ndone = 0
    for line in open(path, errors='replace'):
        if line.rstrip('\n') == DONE or DONE in line:
            ndone += 1
        m = re.search(r'Simulation complete CPU \d+ instructions: (\d+)', line)
        if m:
            d['ins'] += int(m.group(1))
        if 'Region of Interest' in line:
            roi = True
        if not roi:
            continue
        m = re.match(r'cpu\d+->LLC (LOAD|RFO|WRITE|TOTAL)\s+ACCESS:\s+(\d+)\s+HIT:\s+(\d+)', line)
        if m:
            t, a, h = m.group(1), int(m.group(2)), int(m.group(3))
            if t == 'LOAD':
                d['load_acc'] += a; d['load_hit'] += h
            elif t == 'RFO':
                d['rfo_acc'] += a; d['rfo_hit'] += h
            elif t == 'WRITE':
                d['wr_acc'] += a
            else:
                d['tot_acc'] += a
    d['st'] = 'complete' if ndone == 1 else 'INCOMPLETE'
    return d


def c0(dirpath):
    pats = upstream_equiv.allow_patterns()
    names = sorted(f[:-len('.up.log')] for f in os.listdir(dirpath) if f.endswith('.up.log'))
    held = n = 0
    for nm in names:
        o = os.path.join(dirpath, nm + '.oursoff.log')
        if not os.path.exists(o):
            print(f'   {nm}: no ours-off log')
            continue
        n += 1
        ok, probs, _ = upstream_equiv.compare(upstream_equiv.lines(os.path.join(dirpath, nm + '.up.log')), upstream_equiv.lines(o), pats)
        held += ok
        print(f'   {nm}: E1 {"holds" if ok else "FAILS"}' + ('' if ok else ': ' + '; '.join(probs[:3])))
    print(f'C0: E1 holds on {held} of {n} pairs')
    return held, n


def rows(dirpath, refroot, out=sys.stdout):
    for p_c in sorted({f.rsplit('.', 2)[0] for f in os.listdir(dirpath) if f.endswith('.up.log') or f.endswith('.oursoff.log')}):
        p, c = p_c.rsplit('_', 1)
        for side in ('up', 'oursoff'):
            f = os.path.join(dirpath, f'{p_c}.{side}.log')
            if os.path.exists(f):
                d = parse_log(f)
                print(p, c, side, *(d[k] for k in ROW[3:]), file=out)
        ref_dir = os.path.join(refroot, tree_of(p, int(c)), 'regime_shared')
        logs = []
        if os.path.isdir(ref_dir):
            for sub in sorted(os.listdir(ref_dir)):
                if sub.endswith(f'_{c}core') and os.path.exists(os.path.join(ref_dir, sub, 'lru', 'run.log')):
                    logs.append(os.path.join(ref_dir, sub, 'lru', 'run.log'))
        if len(logs) == 1:
            d = parse_log(logs[0])
            print(p, c, 'ours', *(d[k] for k in ROW[3:]), file=out)
        else:
            print(f'# {p} {c}: {len(logs)} reference logs under {ref_dir}', file=out)


def ratios(r, w):
    ki = float(r['ins']) / 1000.0
    gki = w['insts'] / 1000.0
    m1 = ((int(r['tot_acc']) - int(r['wr_acc'])) / ki) / (w['demand_acc'] / gki)
    m2 = ((int(r['load_acc']) - int(r['load_hit']) + int(r['rfo_acc']) - int(r['rfo_hit'])) / ki) / ((w['demand_acc'] - w['demand_hits']) / gki)
    return m1, m2


def score(rows_path, gem5_path, partb, programs_path, out=sys.stdout):
    R = {}
    for line in open(rows_path):
        p = line.split()
        if not p or p[0].startswith('#'):
            continue
        r = dict(zip(ROW, p))
        R[(r['prog'], int(r['cores']), r['side'])] = r
    G = b3_score.load(gem5_path, b3_score.GEM5, lambda r: r['run'])
    listed = {}
    for line in open(programs_path):
        line = line.split('#')[0].strip()
        if line:
            c, _, ps = line.partition(':')
            listed[int(c)] = ps.split()
    verdicts = {}
    for c in (4, 8, 16):
        print(f'== {c} cores: per 1,000 instructions, simulator / gem5 (M1 demand traffic, M2 memory traffic)', file=out)
        print(f'   {"program":13s} {"M1 ours":>8s} {"M1 stock":>8s} {"M2 ours":>8s} {"M2 stock":>8s}  stock\'s M2 error  listed', file=out)
        res = {}
        for p in PROGS15:
            ours, up = R.get((p, c, 'ours')), R.get((p, c, 'up'))
            gp = gem5_pair(p, c, partb)
            why = []
            if ours is None or ours['st'] != 'complete':
                why.append('no complete reference row')
            if up is None or up['st'] != 'complete':
                why.append('no complete stock row')
            w = None
            if gp is not None and gp[1] in G and (gp[0] is None or gp[0] in G):
                try:
                    w = b3_score.window(G, gp[0], gp[1])
                except SystemExit as e:          # a run stopped by its time limit, or counters that went backwards
                    why.append(f'gem5: {e}')
            if w is None and not any(x.startswith('gem5:') for x in why):
                why.append('no gem5 window')
            elif w['demand_acc'] <= 0 or w['demand_acc'] - w['demand_hits'] <= 0:
                why.append('gem5 demand accesses or misses are 0')
            if why:
                print(f'   {p:13s} not scored: {"; ".join(why)}', file=out)
                continue
            m1o, m2o = ratios(ours, w)
            m1s, m2s = ratios(up, w)
            res[p] = (m1o, m1s, m2o, m2s)
            print(f'   {p:13s} {m1o:8.3f} {m1s:8.3f} {m2o:8.3f} {m2s:8.3f}  {"high" if m2s > 1 else "low":>16s}  {"yes" if p in listed.get(c, []) else "no"}', file=out)
        L = [p for p in listed.get(c, [])]
        miss = [p for p in L if p not in res]
        if not L:
            print(f'   C1, C2 at {c} cores: no program listed (none scored and discriminating in B there)', file=out)
            verdicts[c] = None
            continue
        if miss:
            print(f'   C1, C2 at {c} cores: NOT SCORED -- listed but without numbers: {" ".join(miss)}', file=out)
            verdicts[c] = None
            continue
        k1 = sum(1 for p in L if abs(math.log(res[p][2])) <= abs(math.log(res[p][3])))
        k2 = sum(1 for p in L if abs(math.log(res[p][0])) <= abs(math.log(res[p][1])))
        c1 = 3 * k1 >= 2 * len(L)
        print(f'   C1 (M2, primary) at {c} cores: ours at least as close as stock on {k1} of {len(L)} -> {"HOLDS" if c1 else "FAILS"} (two thirds needed)', file=out)
        print(f'   C2 (M1) at {c} cores: ours at least as close as stock on {k2} of {len(L)} ({"two thirds or more" if 3 * k2 >= 2 * len(L) else "under two thirds"})', file=out)
        verdicts[c] = (c1, k1, k2, len(L))
    return verdicts


def selftest():
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        def log(path, ins, la, lh, ra, rh, wa, ta, done=True, extra=''):
            with open(path, 'w') as f:
                f.write('Warmup Instructions: 50000000\nSimulation Instructions: 100000000\n')
                f.write(f'cpu0->LLC LOAD         ACCESS:     999999 HIT:     999999 MISS: 0 MISS_MERGE: 0\n')   # before the ROI: not read
                for k, i in enumerate(ins):
                    f.write(f'Simulation complete CPU {k} instructions: {i} cycles: 5\n')
                if done:
                    f.write(DONE + '\n')
                f.write('Region of Interest Statistics\n')
                for k in range(len(ins)):
                    f.write(f'cpu{k}->LLC TOTAL        ACCESS: {ta[k]:10d} HIT: 0 MISS: 0 MISS_MERGE: 0\n')
                    f.write(f'cpu{k}->LLC LOAD         ACCESS: {la[k]:10d} HIT: {lh[k]:10d} MISS: 0 MISS_MERGE: 0\n')
                    f.write(f'cpu{k}->LLC RFO          ACCESS: {ra[k]:10d} HIT: {rh[k]:10d} MISS: 0 MISS_MERGE: 0\n')
                    f.write(f'cpu{k}->LLC WRITE        ACCESS: {wa[k]:10d} HIT: 0 MISS: 0 MISS_MERGE: 0\n')
                f.write(extra)
        cdir = os.path.join(d, 'partC'); os.makedirs(cdir)
        ref = os.path.join(d, 'trees')
        # ocean at 4 cores: 4 x 100,000 instructions = 400 KI
        # ours: tot 4,000 - wr 400 = 3,600 -> 9.0/KI; misses (1,000-600)+(200-100) = 500 -> 1.25/KI
        # stock: tot 8,000 - wr 800 = 7,200 -> 18.0/KI; misses (2,000-400)+(400-0) = 2,000 -> 5.0/KI
        q = [100000] * 4
        rd = os.path.join(ref, 'phaseA_b3_g3_ocean4', 'regime_shared', 'ocean_4core', 'lru'); os.makedirs(rd)
        log(os.path.join(rd, 'run.log'), q, [250] * 4, [150] * 4, [50] * 4, [25] * 4, [100] * 4, [1000] * 4)
        log(os.path.join(cdir, 'ocean_4.up.log'), q, [500] * 4, [100] * 4, [100] * 4, [0] * 4, [200] * 4, [2000] * 4)
        log(os.path.join(cdir, 'ocean_4.oursoff.log'), q, [500] * 4, [100] * 4, [100] * 4, [0] * 4, [200] * 4, [2000] * 4)
        # canneal at 4: stock closer than ours on M2 (ours misses 3x gem5's, stock 1.5x)
        rd = os.path.join(ref, 'phaseA_b3_g3_canneal4', 'regime_shared', 'canneal_4core', 'lru'); os.makedirs(rd)
        log(os.path.join(rd, 'run.log'), q, [250] * 4, [100] * 4, [50] * 4, [50] * 4, [100] * 4, [1000] * 4)       # misses 600 -> 1.5/KI
        log(os.path.join(cdir, 'canneal_4.up.log'), q, [250] * 4, [175] * 4, [50] * 4, [50] * 4, [100] * 4, [1000] * 4)   # misses 300 -> 0.75/KI
        log(os.path.join(cdir, 'canneal_4.oursoff.log'), q, [250] * 4, [175] * 4, [50] * 4, [50] * 4, [100] * 4, [1000] * 4, extra='an extra line\n')
        # radix at 4: ours exact, stock 2x
        rd = os.path.join(ref, 'phaseA_b3_g3_radix4', 'regime_shared', 'radix_4core', 'lru'); os.makedirs(rd)
        log(os.path.join(rd, 'run.log'), q, [100] * 4, [0] * 4, [0] * 4, [0] * 4, [0] * 4, [100] * 4)              # misses 400 -> 1.0/KI; M1 1.0/KI
        log(os.path.join(cdir, 'radix_4.up.log'), q, [200] * 4, [0] * 4, [0] * 4, [0] * 4, [0] * 4, [200] * 4)
        log(os.path.join(cdir, 'radix_4.oursoff.log'), q, [200] * 4, [0] * 4, [0] * 4, [0] * 4, [0] * 4, [200] * 4)
        # gem5: ocean window 200 KI, demand 2,000 (10/KI), hits 1,800 (misses 1/KI)
        #       canneal: 500 KI, demand 5,000 (10/KI), misses 250 (0.5/KI)
        #       radix: 100 KI, demand 100 (1/KI), misses 100 (1/KI)
        g5 = os.path.join(d, 'gem5.txt')
        with open(g5, 'w') as f:
            def g(run, ins, acc, hit):
                f.write(f'{run} max_insts {ins} 0 0 0 0 {acc} {hit} {ins}\n')
            a, b = b3_score.REFS['']['ocean4'][1:]
            g(a, 100000, 1000, 900); g(b, 300000, 3000, 2700)
            a, b = b3_score.REFS['']['canneal4'][1:]
            g(a, 0, 0, 0); g(b, 500000, 5000, 4750)
            a, b = b3_score.REFS['held']['radix4'][1:]
            g(a, 50000, 50, 0); g(b, 150000, 150, 0)
        progs = os.path.join(d, 'programs.txt')
        open(progs, 'w').write('4: ocean canneal radix\n8:\n')
        rf = os.path.join(d, 'rows.txt')
        with open(rf, 'w') as f:
            rows(cdir, ref, out=f)
        R = {}
        for line in open(rf):
            p = line.split()
            if p and not p[0].startswith('#'):
                R[(p[0], p[1], p[2])] = dict(zip(ROW, p))
        want = {('ocean', '4', 'ours'): ('complete', 400000, 1000, 600, 200, 100, 400, 4000),
                ('ocean', '4', 'up'): ('complete', 400000, 2000, 400, 400, 0, 800, 8000)}
        for k, v in want.items():
            got = R.get(k)
            ok = got is not None and (got['st'], int(got['ins']), int(got['load_acc']), int(got['load_hit']), int(got['rfo_acc']), int(got['rfo_hit']), int(got['wr_acc']), int(got['tot_acc'])) == v
            bad += not ok
            print(f'   {"ok  " if ok else "FAIL"} rows: {k} = {v} (the counts before the ROI are not read)')
        import io
        buf = io.StringIO()
        v = score(rf, g5, os.path.join(d, 'partB'), progs, out=buf)
        txt = buf.getvalue()
        # ocean: M1 ours 9.0/10 = 0.9, stock 18/10 = 1.8; M2 ours 1.25/1 = 1.25, stock 5/1 = 5 -> ours closer
        # canneal: M2 ours 1.5/0.5 = 3.0, stock 0.75/0.5 = 1.5 -> stock closer
        # radix: M2 ours 1.0, stock 2.0 -> ours closer.  C1: 2 of 3 -> HOLDS (two thirds)
        # M1: ocean ours 0.9 / stock 1.8; canneal 0.9 / 0.9 (a tie counts for ours: 'at least as close'); radix 1.0 / 2.0 -> 3 of 3
        checks = [('ocean M1/M2', re.search(r'ocean\s+0\.900\s+1\.800\s+1\.250\s+5\.000\s+high', txt)),
                  ('canneal M2 ours 3.0, stock 1.5', re.search(r'canneal\s+[0-9.]+\s+[0-9.]+\s+3\.000\s+1\.500\s+high', txt)),
                  ('radix M2 ours 1.0, stock 2.0', re.search(r'radix\s+1\.000\s+2\.000\s+1\.000\s+2\.000', txt)),
                  ('C1 at 4 cores: 2 of 3 holds; C2 3 of 3', v.get(4) == (True, 2, 3, 3)),
                  ('8 cores: nothing listed', v.get(8) is None)]
        for name, ok in checks:
            bad += not ok
            print(f'   {"ok  " if ok else "FAIL"} score: {name}')
        # one of three closer -> C1 fails
        open(progs, 'w').write('4: canneal radix ocean\n')
        rd = os.path.join(ref, 'phaseA_b3_g3_radix4', 'regime_shared', 'radix_4core', 'lru')
        log(os.path.join(rd, 'run.log'), q, [300] * 4, [0] * 4, [0] * 4, [0] * 4, [0] * 4, [300] * 4)                # ours 3x, stock 2x
        with open(rf, 'w') as f:
            rows(cdir, ref, out=f)
        v = score(rf, g5, os.path.join(d, 'partB'), progs, out=io.StringIO())
        ok = v.get(4) == (False, 1, 2, 3)
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} score: C1 fails at 1 of 3 ({v.get(4)})')
        # a listed program without numbers: not scored
        open(progs, 'w').write('4: ocean vips\n')
        buf = io.StringIO()
        v = score(rf, g5, os.path.join(d, 'partB'), progs, out=buf)
        ok = v.get(4) is None and 'NOT SCORED -- listed but without numbers: vips' in buf.getvalue()
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} score: a listed program without numbers is not scored')
        # an incomplete stock log is not scored
        log(os.path.join(cdir, 'ocean_4.up.log'), q, [500] * 4, [100] * 4, [100] * 4, [0] * 4, [200] * 4, [2000] * 4, done=False)
        with open(rf, 'w') as f:
            rows(cdir, ref, out=f)
        buf = io.StringIO()
        score(rf, g5, os.path.join(d, 'partB'), progs, out=buf)
        ok = re.search(r'ocean\s+not scored: no complete stock row', buf.getvalue()) is not None
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} score: an incomplete stock log is not scored')
        # C0: identical logs hold; an extra line fails; the incomplete one fails
        import contextlib
        with contextlib.redirect_stdout(io.StringIO()) as o:
            held, n = c0(cdir)
        ok = (held, n) == (1, 3) and 'radix_4: E1 holds' in o.getvalue() and 'canneal_4: E1 FAILS' in o.getvalue() and 'ocean_4: E1 FAILS' in o.getvalue()
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} c0: identical logs hold, an added line fails, an incomplete log fails ({held} of {n})')
        # Part B's gem5 names from a GEM5 line
        pb = os.path.join(d, 'partB', 'radix_8'); os.makedirs(pb)
        open(os.path.join(pb, 'GEM5'), 'w').write('radix_8|/x/RADIX|-p8|||8|1:8|168h|1610000000|1710000000\n')
        ok = gem5_pair('radix', 8, os.path.join(d, 'partB')) == ('partB/radix_8/l2_2MB_mi1610M/radix_8c', 'partB/radix_8/l2_2MB_mi1710M/radix_8c')
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} gem5 names at 8 cores from Part B\'s GEM5 line (radix: its skip + 50 M, + 150 M)')
        ok = gem5_pair('barnes', 4, '') == b3_score.REFS['std']['barnesstd4'][1:] and gem5_pair('canneal', 8, '') == b3_score.REFS['e8']['canneal8'][1:] \
            and gem5_pair('streamcluster', 4, '') == b3_score.REFS['set2']['streamcluster4'][1:] and gem5_pair('fmm', 4, '') == b3_score.REFS['held']['fmm4'][1:]
        bad += not ok
        print(f'   {"ok  " if ok else "FAIL"} gem5 names at 4 cores: barnes (window span), canneal 8, streamcluster (set 2), fmm (held-out)')
    print(f'== selftest {"PASSES" if not bad else f"FAILS ({bad})"} ==')
    return bad


def main(argv):
    if len(argv) == 2 and argv[1] == 'selftest':
        return 1 if selftest() else 0
    if len(argv) == 3 and argv[1] == 'c0':
        held, n = c0(argv[2]); return 0 if held == n else 1
    if len(argv) == 4 and argv[1] == 'rows':
        rows(argv[2], argv[3]); return 0
    if len(argv) == 6 and argv[1] == 'score':
        score(*argv[2:6]); return 0
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
