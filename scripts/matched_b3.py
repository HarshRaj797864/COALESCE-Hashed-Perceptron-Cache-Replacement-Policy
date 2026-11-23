#!/usr/bin/env python3
"""Matched B3 windows (bench/policy_sanity/matched_b3_design_2026-11-17.md).

  matched_b3.py loc2 RUNS_DIR GEM5_PERCPU > bench/policy_sanity/matched_loc_set2_v1.txt
      the located windows of fluidanimate, vips, oceannc (set 2) and streamcluster_4, as
      v2_located.py's LOC / LOCPT / LOCNOT rows: h2's counter runs (RUNS_DIR =
      simulator/results/heldout2/count/runs), gem5's stops at 50 M and 150 M
  matched_b3.py lag LOC_ROWS COUNT_ROWS [LOC_ROWS COUNT_ROWS ...]
      step 1: per key, the largest |lag| of a traced thread's located window against its
      counter window (the COUNT_ROWS' WIN lo / hi: ChampSim's measured span's first 100 M in
      the counter's records), over the three gem5-CPUID counter runs. RERUN if it exceeds
      5,000,000, else not. No ratio is computed.
  matched_b3.py score RUN_LOG LOC_ROWS COUNT_ROWS GEM5_B3_ROWS KEY GEM5_RUN_LO GEM5_RUN_HI
      R_g5m of one matched run (COHERENCE_POSITION_BINS on), one value per counter run, beside
      R_g5 read from the same log. For a Part B key, run only after partB_score.py score.
  matched_b3.py selftest

Matched window of core c (replaying thread t), for counter run k:
  [rec_lo - base, rec_hi - base), base = WIN lo of (k, t) - the run's warm-up instructions,
  clipped to the core's measured span; more than 1,000,000 clipped on any core: not computed.
Events: the bins (of B) whose start lies in the window. Instructions: the windows' lengths.
R_g5m = (1000 x events / instructions) / (gem5's 1000 x (SS + MT L1_GETX) / insts between its stops).
"""
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import b3_score            # noqa: E402
import heldout2_score as h2  # noqa: E402
import v2_located          # noqa: E402

LAG_LIMIT = 5_000_000
CLIP_LIMIT = 1_000_000
BAND = (0.5, 2.0)
SET2 = ('fluidanimate', 'vips', 'oceannc', 'streamcluster')


def loc2(runs_dir, percpu_path):
    percpu = h2.read_percpu(percpu_path)
    print(f'# matched_b3.py loc2 {runs_dir} {percpu_path} (matched_b3_design_2026-11-17.md; v2_located.py rows format)')
    print('# LOC key run <sums over the traced threads>; LOCPT key run t rec_lo rec_hi ginst_lo ginst_hi gem5_lo gem5_hi; LOCNOT key reason')
    for p in SET2:
        s = dict(h2.PROGRAMS[p], stopsM=(50, 150))
        r, pts = v2_located.located(p, s, runs_dir, percpu)
        if pts is None:
            print(f'LOCNOT {p} {r}')
            continue
        for k in v2_located.RUNS:
            print(f'LOC {p} {k} ' + ' '.join(f'{f} {r[k][f]}' for f in v2_located.FIELDS))
        for q in pts:
            print('LOCPT ' + p + ' ' + ' '.join(map(str, q)))
    return 0


def read_locpt(path):
    """{key: {(run, t): (rec_lo, rec_hi)}}, {key: reason}"""
    P, N = {}, {}
    for ln in open(path):
        q = ln.split()
        if not q:
            continue
        if q[0] == 'LOCPT':
            P.setdefault(q[1], {})[(q[2], int(q[3]))] = (int(q[4]), int(q[5]))
        elif q[0] == 'LOCNOT':
            N[q[1]] = ' '.join(q[2:])
    return P, N


def read_win(path):
    """{(key, run, t): (lo, hi)} from count rows' WIN lines of the gem5-CPUID runs"""
    W = {}
    for ln in open(path):
        q = ln.split()
        if len(q) >= 9 and q[0] == 'WIN' and q[2] == 'gem5':
            d = dict(zip(q[5::2], q[6::2]))
            W[(q[1], q[3], int(q[4][1:]))] = (int(d['lo']), int(d['hi']))
    return W


def lag(pairs):
    print('# matched_b3.py lag ' + ' '.join(pairs) + f' (step 1; RERUN if the largest |lag| exceeds {LAG_LIMIT:,}; no ratio)')
    for i in range(0, len(pairs), 2):
        P, N = read_locpt(pairs[i])
        W = read_win(pairs[i + 1])
        for key in sorted(set(P) | set(N)):
            if key in N:
                print(f'LAG {key} not located ({N[key]})')
                continue
            worst, los, his, miss = 0, [], [], []
            for (k, t), (rl, rh) in sorted(P[key].items()):
                if (key, k, t) not in W:
                    miss.append(f'{k}/t{t}')
                    continue
                lo, hi = W[(key, k, t)]
                los.append(rl - lo)
                his.append(rh - hi)
                worst = max(worst, abs(rl - lo), abs(rh - hi))
            if miss:
                print(f'LAG {key} no counter window for {",".join(miss)}')
                continue
            print(f'LAG {key} max {worst} start [{min(los)}, {max(los)}] end [{min(his)}, {max(his)}] -> {"RERUN" if worst > LAG_LIMIT else "not rerun"}')
    return 0


def parse_log(text):
    """the matched run's facts, or a reason (str)"""
    m = re.search(r'^B3 POSITION BINS: (\d+) instructions$', text, re.M)
    if not m:
        return 'no B3 POSITION BINS line (the instrument was off)'
    B = int(m.group(1))
    wu = re.search(r'^Warmup Instructions: (\d+)', text, re.M)
    if not wu or 'ChampSim completed all CPUs' not in text:
        return 'not a complete run'
    span = {int(c): (int(a), int(b)) for c, a, b in re.findall(r'^CPU (\d+) MEASURED POSITIONS: from (\d+) to (\d+)$', text, re.M)}
    bins = {}
    for c, rest in re.findall(r'^CPU (\d+) GEM5-RULE RFO EVENTS BY POSITION:(.*)$', text, re.M):
        bins[int(c)] = {int(k): int(n) for k, n in (x.split(':') for x in rest.split())}
    thread = {}
    for c, path in re.findall(r'^CPU (\d+) runs (\S+)$', text, re.M):
        mt = re.search(r'raw(\d+)(?:_aligned)?\.champsimtrace', os.path.basename(path))
        if not mt:
            return f'CPU {c}: cannot read the thread from {path}'
        thread[int(c)] = int(mt.group(1))
    ins = sum(int(x) for x in re.findall(r'^Simulation complete CPU \d+ instructions: (\d+) ', text, re.M))
    roi = text.find('Region of Interest Statistics')
    mg = re.search(r'^LLC COHERENCE DIR RFO GEM5-RULE EVENTS:\s+(\d+)$', text[roi:], re.M) if roi >= 0 else None
    if not (span and set(span) == set(bins) == set(thread)) or not mg or not ins:
        return 'the positions, bins, traces or counter lines are incomplete'
    return dict(B=B, W=int(wu.group(1)), span=span, bins=bins, thread=thread, ins=ins, g5=int(mg.group(1)))


def in_span(L):
    """QM1's quantity: events in bins whose start lies in each core's measured span"""
    return sum(n for c in L['span'] for k, n in L['bins'][c].items() if L['span'][c][0] <= k * L['B'] < L['span'][c][1])


def matched(L, locpt, win, key):
    """{run: (events, instructions)} or {run: reason}"""
    out = {}
    for k in v2_located.RUNS:
        ev = ins = 0
        why = None
        for c, t in sorted(L['thread'].items()):
            if (k, t) not in locpt or (key, k, t) not in win:
                why = f'no located or counter window for thread {t}'
                break
            rl, rh = locpt[(k, t)]
            base = win[(key, k, t)][0] - L['W']
            plo, phi = rl - base, rh - base
            flo, fto = L['span'][c]
            clip = max(0, flo - plo) + max(0, phi - fto)
            if clip > CLIP_LIMIT:
                why = f'core {c} (thread {t}) clipped by {clip:,} (window {plo:,}-{phi:,}, span {flo:,}-{fto:,})'
                break
            plo, phi = max(plo, flo), min(phi, fto)
            ev += sum(n for b, n in L['bins'][c].items() if plo <= b * L['B'] < phi)
            ins += phi - plo
        out[k] = why if why else (ev, ins)
    return out


def score(run_log, loc_rows, count_rows, gem5_rows, key, ga, gb):
    L = parse_log(open(run_log, errors='replace').read())
    if isinstance(L, str):
        print(f'{key}: not scored -- {L}')
        return 1
    P, N = read_locpt(loc_rows)
    if key not in P:
        print(f'{key}: not scored -- not located ({N.get(key, "no LOCPT rows")})')
        return 1
    G = b3_score.load(gem5_rows, b3_score.GEM5, lambda r: r['run'])
    w = b3_score.window(G, ga, gb)
    if w is None:
        print(f'{key}: not scored -- no gem5 pair {ga} / {gb}')
        return 1
    g = 1000.0 * (w['ss_getx'] + w['mt_getx']) / w['insts']
    r_g5 = 1000.0 * L['g5'] / L['ins'] / g
    qm1 = in_span(L)
    print(f'== {key}: {run_log}')
    print(f'   R_g5 (this log) {r_g5:.3f}: {L["g5"]} events in {L["ins"]:,} instructions; gem5 {g:.4f} per 1,000')
    print(f'   QM1 (reported): binned events in the measured spans {qm1} against the counter {L["g5"]}')
    vals = []
    for k, v in matched(L, P[key], read_win(count_rows), key).items():
        if isinstance(v, str):
            print(f'   counter run {k}: R_g5m not computed -- {v}')
            continue
        ev, ins = v
        rm = 1000.0 * ev / ins / g if ins else float('nan')
        vals.append(rm)
        print(f'   counter run {k}: R_g5m {rm:.3f} ({ev} events in {ins:,} instructions)')
    if not vals:
        print('   -> R_g5m not computed')
        return 1
    lo, hi = min(vals), max(vals)
    side = lambda x: 0 if x < BAND[0] else (2 if x > BAND[1] else 1)
    sens = side(r_g5) != side(lo) or side(r_g5) != side(hi)
    print(f'   -> R_g5m [{lo:.3f}, {hi:.3f}] beside R_g5 {r_g5:.3f}' + (': PLACEMENT-SENSITIVE (a band edge lies between them)' if sens else ''))
    return 0


def selftest():
    ok = bad = 0

    def expect(name, cond, detail=''):
        nonlocal ok, bad
        ok, bad = ok + bool(cond), bad + (not cond)
        print(f'   {"ok  " if cond else "FAIL"}  {name}' + ('' if cond else f': {detail}'))

    d = tempfile.mkdtemp(prefix='matched_b3_')
    J = lambda *p: os.path.join(d, *p)
    # two cores replaying threads 1 and 2; warm-up 50 M; bins of 100,000
    log = '\n'.join([
        'Warmup Instructions: 50000000', 'CPU 0 runs /t/sync_h2/x/raw1.champsimtrace.xz', 'CPU 1 runs /t/sync_h2/x/raw2_aligned.champsimtrace.xz',
        'Simulation complete CPU 0 instructions: 100000000 cycles: 1', 'Simulation complete CPU 1 instructions: 110000000 cycles: 1',
        'ChampSim completed all CPUs', 'LLC COHERENCE DIR RFO GEM5-RULE EVENTS:         99', 'Region of Interest Statistics',
        'LLC COHERENCE DIR RFO GEM5-RULE EVENTS:        250', 'B3 POSITION BINS: 100000 instructions',
        'CPU 0 MEASURED POSITIONS: from 50000000 to 150000000', 'CPU 1 MEASURED POSITIONS: from 50000000 to 160000000',
        # core 0: 100 events at 60 M, 100 at 140 M, 7 in warm-up; core 1: 50 at 70 M, 3 after its span
        'CPU 0 GEM5-RULE RFO EVENTS BY POSITION: 100:7 600:100 1400:100', 'CPU 1 GEM5-RULE RFO EVENTS BY POSITION: 700:50 1650:3', ''])
    with open(J('run.log'), 'w') as f:
        f.write(log)
    L = parse_log(log)
    expect('P1 parse: bins, spans, threads, ROI counter, instructions', isinstance(L, dict) and L['thread'] == {0: 1, 1: 2} and L['g5'] == 250
           and L['ins'] == 210_000_000 and L['bins'][0][600] == 100, L)
    expect('P2 QM1: the events in the measured spans', in_span(L) == 250, in_span(L))
    expect('P3 an instrument-off log is refused', isinstance(parse_log(log.replace('B3 POSITION BINS', 'X')), str), '')
    # counter: thread 1 based at 0 (WIN lo 50 M), thread 2 cut at 2 M (WIN lo 52 M)
    win = '\n'.join(f'WIN x gem5 {k} t{t} lo {lo} hi {lo + 100_000_000} rec 1' for k in '123' for t, lo in ((1, 50_000_000), (2, 52_000_000))) + '\n'
    with open(J('count.txt'), 'w') as f:
        f.write(win)
    # located: run 1 = the counter windows; run 2: thread 1 ends 20 M early (lags), thread 2 as run 1; run 3: thread 1 starts 2 M early (clipped)
    loc = []
    for k, t, rl, rh in (('1', 1, 50_000_000, 150_000_000), ('1', 2, 52_000_000, 152_000_000), ('2', 1, 50_000_000, 130_000_000),
                         ('2', 2, 52_000_000, 152_000_000), ('3', 1, 48_000_000, 150_000_000), ('3', 2, 52_000_000, 152_000_000)):
        loc.append(f'LOCPT x {k} {t} {rl} {rh} 0 0 0 0')
    with open(J('loc.txt'), 'w') as f:
        f.write('\n'.join(loc) + '\n')
    P, _ = read_locpt(J('loc.txt'))
    M = matched(L, P['x'], read_win(J('count.txt')), 'x')
    expect('M1 run 1: both windows inside, 250 events in 200 M', M['1'] == (250, 200_000_000), M)
    expect('M2 run 2: thread 1 ends at 130 M, its 140 M bin left out', M['2'] == (150, 180_000_000), M)
    expect('M3 run 3: 2 M clipped on core 0 -> not computed', isinstance(M['3'], str) and 'clipped by 2,000,000' in M['3'], M)
    # step 1's lag: run 2 lags 20 M at the end
    import io
    import contextlib
    with contextlib.redirect_stdout(io.StringIO()) as o:
        lag([J('loc.txt'), J('count.txt')])
    t = o.getvalue()
    expect('S1 lag: 20 M at the end -> RERUN', 'LAG x max 20000000 start [-2000000, 0] end [-20000000, 0] -> RERUN' in t, t)
    with open(J('loc_small.txt'), 'w') as f:
        f.write('LOCPT x 1 1 50100000 149000000 0 0 0 0\nLOCPT x 1 2 52000000 152000000 0 0 0 0\n')
    with contextlib.redirect_stdout(io.StringIO()) as o:
        lag([J('loc_small.txt'), J('count.txt')])
    expect('S2 lag: 1 M -> not rerun', 'max 1000000' in o.getvalue() and 'not rerun' in o.getvalue(), o.getvalue())
    # the score: gem5 1,000 events in 800 M (0.00125 per 1,000) -> run 1 R_g5m (1000 x 250 / 200 M) / 0.00125 = 1.000,
    # run 2 (1000 x 150 / 180 M) / 0.00125 = 0.667, R_g5 (1000 x 250 / 210 M) / 0.00125 = 0.952
    hdr = 'run ended insts ss_getx mt_getx ss_upgrade getx_all demand_acc demand_hits cpus\n'
    with open(J('g5.txt'), 'w') as f:
        f.write(hdr + 'a max_insts 100000000 0 0 0 0 0 0 1,1\nb max_insts 900000000 500 500 0 0 0 0 2,2\n')
    with contextlib.redirect_stdout(io.StringIO()) as o:
        rc = score(J('run.log'), J('loc.txt'), J('count.txt'), J('g5.txt'), 'x', 'a', 'b')
    t = o.getvalue()
    expect('S3 score: R_g5m per run, R_g5 from the ROI block, run 3 not computed', rc == 0 and 'counter run 1: R_g5m 1.000 (250 events in 200,000,000' in t
           and 'counter run 2: R_g5m 0.667 (150' in t and 'R_g5 (this log) 0.952' in t and 'counter run 3: R_g5m not computed' in t
           and '-> R_g5m [0.667, 1.000] beside R_g5 0.952' in t and 'PLACEMENT' not in t, t)
    # gem5 at 0.0021645 per 1,000: R_g5 0.550, run 2 0.385 -> a band edge between them
    with open(J('g5b.txt'), 'w') as f:
        f.write(hdr + 'a max_insts 100000000 0 0 0 0 0 0 1,1\nb max_insts 1100000000 1082 1082 0 0 0 0 2,2\n')
    with contextlib.redirect_stdout(io.StringIO()) as o:
        score(J('run.log'), J('loc.txt'), J('count.txt'), J('g5b.txt'), 'x', 'a', 'b')
    expect('S4 a band edge between R_g5 and R_g5m: PLACEMENT-SENSITIVE', 'PLACEMENT-SENSITIVE' in o.getvalue(), o.getvalue())
    print(f'== selftest: {ok} hold, {bad} fail ==')
    return 1 if bad else 0


def main(a):
    if a[:1] == ['loc2'] and len(a) == 3:
        return loc2(a[1], a[2])
    if a[:1] == ['lag'] and len(a) >= 3 and len(a) % 2 == 1:
        return lag(a[1:])
    if a[:1] == ['score'] and len(a) == 8:
        return score(*a[1:])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
