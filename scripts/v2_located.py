#!/usr/bin/env python3
"""The v2 misses of Part B: where gem5's window lies
(bench/policy_sanity/v2_located_design_2026-11-14.md). Laptop, pulled files only.

  v2_located.py run KEYS COUNT_ROWS COUNT_RUNS GEM5_PERCPU GEM5_MIX
      KEYS        bench/policy_sanity/partB_keys_v1.txt
      COUNT_ROWS  bench/policy_sanity/partB_count_rows_v1.txt  (the counter windows, as check reads them)
      COUNT_RUNS  simulator/results/partB/stage2/count/runs    (each run's c.t<t>.cnt and c.t<t>.rtn)
      GEM5_PERCPU bench/policy_sanity/gem5_percpu_v3.txt
      GEM5_MIX    bench/policy_sanity/gem5_mix_v7.txt
  v2_located.py rows KEYS COUNT_RUNS GEM5_PERCPU > bench/policy_sanity/partB_v2loc_rows_vN.txt
      (breadth_bc_design amendment 12) per key and gem5-CPUID counter run, the located sums over the
      traced threads (LOC), each thread's grid points (LOCPT), or why none (LOCNOT); partB_score.py
      --v2loc judges v2 on them
  v2_located.py selftest

Per key (procedure set2, sized, with three gem5-CPUID counter runs and both
gem5 runs): QV (the counter-window rates equal check's v2 computation), the
counter-window range, the located range (each thread from the grid point whose
ginst is nearest CPU t's numInsts at the low stop to the one nearest it at the
high stop), gem5's rates, v2's rule on both, the readings W1 / W2 (and L1-L3
for an RMW miss below the range), the lock-wait bound B, and the placement
offsets.
"""
import bisect
import contextlib
import io
import os
import statistics
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import heldout2_score as h2  # noqa: E402

M = 1_000_000
FIELDS = ('rec', 'ld', 'st', 'rmw', 'ginst', 'gld', 'gst', 'rep')
NAMES = ('loads', 'stores', 'RMWs')
PRIMARY = ('barnes_16',)
SECONDARY = ('fmm_4', 'fmm_8', 'fmm_16', 'volrend_4', 'volrend_8', 'volrend_16')
RUNS = ('1', '2', '3')


def load_keys(path):
    K = {}
    for ln in open(path):
        q = ln.split()
        if not q or q[0] != 'KEY':
            continue
        d = h2.kv(q[2:])
        if d.get('sized') == 'no' or d.get('procedure') != 'set2':
            continue
        K[q[1]] = dict(tids=tuple(int(x) for x in d['tids'].split(',')), run=d['run'],
                       stopsM=tuple(int(x) for x in d['stopsM'].split(',')))
    return K


def load_win(path):
    W = {}
    for ln in open(path):
        q = ln.split()
        if len(q) > 6 and q[0] == 'WIN' and q[5] == 'lo':
            d = h2.kv(q[5:])
            W[(q[1], q[2], q[3], int(q[4][1:]))] = {k: int(v) for k, v in d.items()}
    return W


def rates(T):
    return (1000 * T['gld'] / T['ginst'], 1000 * T['gst'] / T['ginst'], 1000 * T['rmw'] / T['ginst'])


def read_grid(path):
    at = h2.read_cnt(path)
    recs = sorted(at)
    return [at[r] for r in recs]


def nearest(grid, g):
    gs = [v[4] for v in grid]
    i = bisect.bisect_left(gs, g)
    if i >= len(gs):
        return None
    if i > 0 and g - gs[i - 1] <= gs[i] - g:
        i -= 1
    return i


def lockwait(path):
    """(stores, records) in routines named *lll_lock_wait*, W lines"""
    st = rec = 0
    if os.path.exists(path):
        for ln in open(path):
            p = ln.split(None, 9)
            if len(p) >= 10 and p[0] == 'W' and 'lll_lock_wait' in p[9]:
                rec += int(p[1])
                st += int(p[3])
    return st, rec


def judge(g, lo, hi, i):
    return h2.in_range(g, lo, hi, h2.V2_WIDEN, h2.V2_RMW_ABS if i == 2 else None)


def one_key(key, s, W, runs_dir, percpu, gmix, out):
    tids = s['tids']
    a, b = (s['run'].format(x) for x in s['stopsM'])
    say = out.append
    say(f'== {key}: threads {",".join(map(str, tids))}; gem5 runs {a} and {b}')
    if a not in percpu or b not in percpu or a not in gmix or b not in gmix or any(t not in percpu[a] or t not in percpu[b] for t in tids):
        say('   NOT READ: a gem5 run is missing from the per-CPU or mix rows')
        return None
    if any((key, 'gem5', k, t) not in W for k in RUNS for t in tids):
        say('   NOT READ: a counter window is missing')
        return None
    gpc = {t: tuple(y - x for x, y in zip(percpu[a][t], percpu[b][t])) for t in tids}
    gi = sum(gpc[t][0] for t in tids)
    gw = {k: gmix[b][k] - gmix[a][k] for k in gmix[b]}
    g = (1000 * sum(gpc[t][1] + gpc[t][2] for t in tids) / gi, 1000 * sum(gpc[t][3] + gpc[t][4] for t in tids) / gi,
         1000 * (gw['RMW_Read'] + gw['Locked_RMW_Read']) / gw['insts'])
    cw, loc, lw, offs = [], [], [], {t: [] for t in tids}
    for k in RUNS:
        cw.append(rates({f: sum(W[(key, 'gem5', k, t)][f] for t in tids) for f in FIELDS}))
        d = os.path.join(runs_dir, f'{key}__gem5__{k}')
        T = dict.fromkeys(FIELDS, 0)
        short = []
        for t in tids:
            grid = read_grid(os.path.join(d, f'c.t{t}.cnt'))
            ia, ib = nearest(grid, percpu[a][t][0]), nearest(grid, percpu[b][t][0])
            if ia is None or ib is None:
                short.append(t)
                continue
            for j, f in enumerate(FIELDS):
                T[f] += grid[ib][j] - grid[ia][j]
            w = W[(key, 'gem5', k, t)]
            byrec = {v[0]: v for v in grid}
            if w['lo'] in byrec and w['hi'] in byrec:
                offs[t].append(((grid[ia][4] - byrec[w['lo']][4]) / M, (grid[ib][4] - byrec[w['hi']][4]) / M))
        if short:
            say(f'   counter run {k}: located window past the run\'s end on thread(s) {",".join(map(str, short))}: NOT READ')
            return None
        loc.append(rates(T))
        st = sum(lockwait(os.path.join(d, f'c.t{t}.rtn'))[0] for t in tids)
        lw.append(1000 * st / sum(W[(key, 'gem5', k, t)]['ginst'] for t in tids))
    res = {}
    for i, name in enumerate(NAMES):
        clo, chi = min(c[i] for c in cw), max(c[i] for c in cw)
        llo, lhi = min(c[i] for c in loc), max(c[i] for c in loc)
        okc, okl = judge(g[i], clo, chi, i), judge(g[i], llo, lhi, i)
        line = (f'   {name:7s} gem5 {g[i]:8.3f}   counter windows {h2.fmt_range(clo, chi)} -> {"inside" if okc else "OUTSIDE"}'
                f'   located {h2.fmt_range(llo, lhi)} -> {"inside" if okl else "OUTSIDE"}')
        if not okc:
            line += f'   reading {"W1" if okl else "W2"}'
        say(line)
        res[name] = (okc, okl)
        if i == 2 and not okc and g[i] < clo:
            edge = min(clo * (1 - h2.V2_WIDEN), clo - h2.V2_RMW_ABS)
            s_, gap, B = edge - g[i], clo - g[i], max(lw)
            say(f'           lock-wait stores per 1,000 (counter windows) {", ".join(f"{x:.4f}" for x in lw)}; B {B:.4f}; '
                f's {s_:.3f}; gap {gap:.3f} -> reading {"L1" if B < s_ else "L2" if B >= gap else "L3"}')
    o = [x for t in tids for x in offs[t]]
    if o:
        st_, en_ = [x[0] for x in o], [x[1] for x in o]
        say(f'   placement (gem5 window minus counter window, M instructions, over threads and runs): start median {statistics.median(st_):+.2f} '
            f'[{min(st_):+.2f}, {max(st_):+.2f}]; end median {statistics.median(en_):+.2f} [{min(en_):+.2f}, {max(en_):+.2f}]')
        for t in tids:
            if offs[t]:
                say(f'           t{t}: start {statistics.mean(x[0] for x in offs[t]):+7.2f}  end {statistics.mean(x[1] for x in offs[t]):+7.2f}')
    return res


def located(key, s, runs_dir, percpu):
    """amendment 12: ({run: {field: sum over the traced threads}}, [grid points]) or (reason, None)"""
    tids = s['tids']
    a, b = (s['run'].format(x) for x in s['stopsM'])
    if a not in percpu or b not in percpu or any(t not in percpu[a] or t not in percpu[b] for t in tids):
        return 'gem5 per-CPU rows missing (a gem5 run not ended)', None
    res, pts = {}, []
    for k in RUNS:
        d = os.path.join(runs_dir, f'{key}__gem5__{k}')
        T = dict.fromkeys(FIELDS, 0)
        for t in tids:
            f = os.path.join(d, f'c.t{t}.cnt')
            if not os.path.exists(f):
                return f'counter run {k}: no counts for thread {t}', None
            grid = read_grid(f)
            ia, ib = nearest(grid, percpu[a][t][0]), nearest(grid, percpu[b][t][0])
            if ia is None or ib is None:
                return f"counter run {k}: located window past the run's end on thread {t}", None
            for j, fld in enumerate(FIELDS):
                T[fld] += grid[ib][j] - grid[ia][j]
            pts.append((k, t, grid[ia][0], grid[ib][0], grid[ia][4], grid[ib][4], percpu[a][t][0], percpu[b][t][0]))
        res[k] = T
    return res, pts


def loc_rows(keys_path, runs_dir, percpu_path):
    K, percpu = load_keys(keys_path), h2.read_percpu(percpu_path)
    print(f'# v2_located.py rows {keys_path} {runs_dir} {percpu_path} (breadth_bc_design amendment 12)')
    print('# LOC key run <sums over the traced threads>; LOCPT key run t rec_lo rec_hi ginst_lo ginst_hi gem5_lo gem5_hi; LOCNOT key reason')
    for key in K:
        r, pts = located(key, K[key], runs_dir, percpu)
        if pts is None:
            print(f'LOCNOT {key} {r}')
            continue
        for k in RUNS:
            print(f'LOC {key} {k} ' + ' '.join(f'{f} {r[k][f]}' for f in FIELDS))
        for q in pts:
            print('LOCPT ' + key + ' ' + ' '.join(map(str, q)))
    return 0


def load_loc(path):
    """the rows' file -> {key: {run: {field: int}}} or {key: reason}"""
    L = {}
    for ln in open(path):
        q = ln.split()
        if len(q) >= 3 and q[0] == 'LOCNOT':
            L[q[1]] = ' '.join(q[2:])
        elif len(q) == 3 + 2 * len(FIELDS) and q[0] == 'LOC':
            d = h2.kv(q[3:])
            assert set(d) == set(FIELDS), ln
            L.setdefault(q[1], {})[q[2]] = {f: int(v) for f, v in d.items()}
    return L


def run(keys_path, rows_path, runs_dir, percpu_path, gmix_path):
    K, W = load_keys(keys_path), load_win(rows_path)
    percpu, gmix = h2.read_percpu(percpu_path), h2.read_gem5_mix(gmix_path)
    print(f'# v2_located.py run {keys_path} {rows_path} {runs_dir} {percpu_path} {gmix_path}')
    res = {}
    for key in K:
        out = []
        r = one_key(key, K[key], W, runs_dir, percpu, gmix, out)
        print('\n'.join(out))
        if r is not None:
            res[key] = r
    print('\n== Control C: keys passing v2 on the counter windows, on the located windows')
    passing = [k for k, r in res.items() if all(x[0] for x in r.values())]
    still = [k for k in passing if all(x[1] for x in res[k].values())]
    print(f'   {len(still)} of {len(passing)} still pass' + (f'; failing on located windows: {", ".join(k for k in passing if k not in still)}' if len(still) < len(passing) else ''))
    print('== Readings, primary then secondary')
    for key in PRIMARY + SECONDARY:
        if key not in res:
            print(f'   {key}: not read')
            continue
        miss = [n for n, x in res[key].items() if not x[0]]
        print(f'   {key}: ' + ('passes v2 (nothing to explain)' if not miss else
                               '; '.join(f'{n} {"W1" if res[key][n][1] else "W2"}' for n in miss)))
    return 0


def selftest():
    d = tempfile.mkdtemp()
    keys = os.path.join(d, 'keys')
    open(keys, 'w').write('KEY x_2 prog x cores 2 tids 0,1 ncpu 2 stops 1 stopsM 50,150 skip 0 cut 0 exe e tree t wl x '
                          'run g/x/l2_mi{}M/x sized yes procedure set2\n')
    # each thread: 300 grid points of 1 M ginst (step 1 M records = 1 M ginst); RMW density 10 per 1,000 before
    # position 100 M and 8 after; loads 300, stores 200 per 1,000 throughout
    runs = os.path.join(d, 'runs')
    win = []
    for k in RUNS:
        rd_ = os.path.join(runs, f'x_2__gem5__{k}')
        os.makedirs(rd_)
        for t in (0, 1):
            c = [0] * 8
            lines = []
            for i in range(301):
                lines.append('C ' + ' '.join(map(str, c)))
                pos = i * M
                dr = 10_000 if pos < 100 * M else 8_000
                c = [c[0] + M, c[1] + 300_000, c[2] + 200_000, c[3] + dr, c[4] + M, c[5] + 300_000, c[6] + 200_000, 0]
            open(os.path.join(rd_, f'c.t{t}.cnt'), 'w').write('\n'.join(lines) + '\n')
            open(os.path.join(rd_, f'c.t{t}.rtn'), 'w').write(
                'W 1000 500 400 0 500 400 0 libc.so.6 __lll_lock_wait\nW 9 1 1 0 1 1 0 libc.so.6 other\n')
            # counter window 50-150 M: rmw 50 M x 10 + 50 M x 8 per 1,000 = 900,000
            win.append(f'WIN x_2 gem5 {k} t{t} lo {50 * M} hi {150 * M} rec {100 * M} ld {30 * M} st {20 * M} rmw 900000 '
                       f'ginst {100 * M} gld {30 * M} gst {20 * M} rep 0')
    rows = os.path.join(d, 'rows')
    open(rows, 'w').write('\n'.join(win) + '\n')
    # gem5: both CPUs at 120 M and 220 M (located window wholly after 100 M: RMW 8.000); gem5 RMW 8.0 per 1,000
    pc = os.path.join(d, 'pc')
    open(pc, 'w').write('g/x/l2_mi50M/x 0 120000000 36000000 0 24000000 0\ng/x/l2_mi50M/x 1 120000000 36000000 0 24000000 0\n'
                        'g/x/l2_mi150M/x 0 220000000 66000000 0 44000000 0\ng/x/l2_mi150M/x 1 220000000 66000000 0 44000000 0\n')
    gm = os.path.join(d, 'gm')
    open(gm, 'w').write('g/x/l2_mi50M/x 240000000 0 0 0 1920000 0 0\ng/x/l2_mi150M/x 440000000 0 0 0 3520000 0 0\n')
    K, W = load_keys(keys), load_win(rows)
    out = []
    r = one_key('x_2', K['x_2'], W, runs, h2.read_percpu(pc), h2.read_gem5_mix(gm), out)
    txt = '\n'.join(out)
    ok = True
    want = {'loads': (True, True), 'stores': (True, True), 'RMWs': (False, True)}   # counter windows 9.000: outside; located 8.000: inside
    if r != want:
        ok = False
        print('selftest: verdicts', r)
    for frag in ('counter windows [9.000, 9.000]', 'located [8.000, 8.000]', 'reading W1', 'placement', 'start median +70.00', 'end median +70.00'):
        if frag not in txt:
            ok = False
            print('selftest: missing', repr(frag))
    # the lock-wait bound: 400 stores x 2 threads / 200 M ginst x 1,000 = 0.004; s = min(8.55, 8.95) - 8 = 0.55 -> L1 would read
    # (not printed here: gem5 is inside on the located windows but outside, below, on the counter windows -> L printed)
    if 'B 0.0040' not in txt or 'reading L1' not in txt:
        ok = False
        print('selftest: lock-wait bound line', [ln for ln in out if 'lock-wait' in ln])
    # amendment 12: the rows (both threads from 120 M to 220 M: 100 M ginst, 30 M loads, 20 M stores, 800,000 RMWs each)
    pcd = h2.read_percpu(pc)
    with contextlib.redirect_stdout(io.StringIO()) as o:
        loc_rows(keys, runs, pc)
    lf = os.path.join(d, 'loc')
    open(lf, 'w').write(o.getvalue())
    L = load_loc(lf)
    want_loc = {f: v for f, v in zip(FIELDS, (200 * M, 60 * M, 40 * M, 1_600_000, 200 * M, 60 * M, 40 * M, 0))}
    if L.get('x_2') != {k: want_loc for k in RUNS} or o.getvalue().count('LOCPT x_2 ') != 6 or 'LOCPT x_2 1 0 120000000 220000000 ' not in o.getvalue():
        ok = False
        print('selftest: rows', o.getvalue(), L.get('x_2'))
    far = {r: {t: ((400 * M,) + v[1:] if 'mi150M' in r and t == 1 else v) for t, v in c.items()} for r, c in pcd.items()}
    if located('x_2', K['x_2'], runs, far)[0] != "counter run 1: located window past the run's end on thread 1":
        ok = False
        print('selftest: past the end', located('x_2', K['x_2'], runs, far)[0])
    if located('x_2', K['x_2'], runs, {})[1] is not None or not located('x_2', K['x_2'], runs, {})[0].startswith('gem5 per-CPU rows missing'):
        ok = False
        print('selftest: missing gem5 rows not refused')
    print(txt)
    print('selftest PASS' if ok else 'selftest FAIL')
    return 0 if ok else 1


def main(a):
    if a[:1] == ['run'] and len(a) == 6:
        return run(*a[1:])
    if a[:1] == ['rows'] and len(a) == 4:
        return loc_rows(*a[1:])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]) or 0)
