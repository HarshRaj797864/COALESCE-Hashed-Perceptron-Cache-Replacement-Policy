#!/usr/bin/env python3
"""The same-stream check v2, and the diagnosis of step 4's failures
(bench/policy_sanity/stream_fix_design_2026-11-02.md).

    stream_check2.py gem5rows GEM5_ROOT > bench/policy_sanity/gem5_percpu_v1.txt
    stream_check2.py rows STREAMFIX_DIR > bench/policy_sanity/stream_v2_rows_v1.txt
    stream_check2.py check ROWS GEM5_PERCPU GEM5_MIX TRACE_MIX [NEWBENCH_TRACES]
    stream_check2.py ncheck ROWS GEM5_PERCPU GEM5_MIX TRACE_MIX NC_TRACE_MIX [NEWBENCH_TRACES]

gem5rows  every stats.txt under GEM5_ROOT: per CPU, the committed
          instructions and memory micro-ops (MemRead, FloatMemRead, MemWrite,
          FloatMemWrite).
rows      the counter's runs (simulator/results/streamfix, pulled by
          streamfix_all.sh): for every workload window and traced thread, the
          counts in record units and gem5 units; per run, thread 0's
          pthread_create, its serial start (and how much of it is libm), the
          REP write micro-ops in libc in each thread's window, and any
          AVX / EVEX / FMA routine in libc, libm or ld.so.
check     QE, QC, QA, the v2 table, and the verdict on each prediction S0-S4
          as pre-registered; then F2's comparison for the earlier programs.
ncheck    amendment 1: the programs traced again with gem5's CPUID (NC_SET;
          NC_TRACE_MIX holds their traces' window rows, made as v1's with
          b3_stream_check.py window). Only if check prints F2 YES: per program,
          QC-nc (the new traces against the counter's gem5-CPUID run, QC's
          rule) and v2 with gem5's CPUID (F3's native range for RMWs where F3
          holds); a program passing both may have its ratios read.
          (lunc is in rows and ncheck, not in check: it has no host trace, so
          check's QA would list it as failing; no verdict of check uses QA.)

v2 compares, over the windows v1 uses (the records ChampSim simulates, located
in the counter's run by instruction position), in gem5's units:
  loads   read micro-ops per 1,000 instructions (a REP instruction once)
          against gem5's MemRead + FloatMemRead per 1,000 numInsts
  stores  write micro-ops, against MemWrite + FloatMemWrite
  RMWs    instructions with an operand read and written, against Ruby's
          RMW_Read + Locked_RMW_Read (gem5_mix, as v1)
summed over the traced threads and their CPUs (CPU c runs thread c), with v1's
tolerances: 5%; 0.05 per 1,000 for RMWs; for held-out programs, loads and
stores up to 8% are scored with the miss stated.
"""
import os
import re
import sys

M = 1_000_000
TOL, ABS_RMW, SOFT = 0.05, 0.05, 0.08
LIBS = ('libc.so', 'libm.so', 'ld-linux', 'libpthread')

# workload, counter run, traced threads, window (from, to) after each thread's
# base (from None: thread 0 from its very start, as v1's barnes std start
# rows), gem5 runs at the two stops (None = the program's start), held-out,
# v1's trace-row prefix (for QC)
NB = 'newbench/{p}/l2_2MB_mi{n}M/{p}_4c'
WORKLOADS = [
    ('ocean', 'ocean4', (0, 1, 2, 3), (50 * M, 150 * M), 'l2_2MB_mi50M/ocean_4c', 'l2_2MB_mi150M/ocean_4c', False, 'ocean_4t_ocean'),
    ('canneal', 'canneal4', (1, 2, 3, 4), (50 * M, 150 * M), 'canneal/l2_2MB_mi50M/canneal_4c', 'canneal/l2_2MB_mi150M/canneal_4c', False, 'canneal_4t_canneal'),
    ('canneal8', 'canneal8', tuple(range(1, 9)), (50 * M, 150 * M), 'canneal8/l2_2MB_mi50M/canneal_8c', 'canneal8/l2_2MB_mi150M/canneal_8c', False, 'canneal_8t_t'),
    ('barnes256', 'barnes256', (0, 1, 2, 3), (50 * M, 150 * M), 'barnes_leaf256/l2_2MB_mi50M/barnes_4c', 'barnes_leaf256/l2_2MB_mi150M/barnes_4c', False, 'barnes_4t'),
    ('bstd-start', 'barnesstd', (0, 1, 2, 3), (None, 37_900_000), None, 'barnes/l2_2MB_mi50M/barnes_4c', False, 'barnes_std_4t_start_'),
    ('bstd-force', 'barnesstd', (0, 1, 2, 3), (37_900_000, 87_900_000), 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi100M/barnes_4c', False, 'barnes_std_4t_force_'),
    ('bstd-window', 'barnesstd', (0, 1, 2, 3), (37_900_000, 137_900_000), 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi150M/barnes_4c', False, 'barnes_std_4t_window_'),
    ('radix', 'radix', (0, 1, 2, 3), (50 * M, 150 * M), 'heldout/radix/l2_2MB_mi830M/radix_4c', 'heldout/radix/l2_2MB_mi930M/radix_4c', True, 'radix_4t_window_'),
    ('waternsq', 'waternsq', (0, 1, 2, 3), (50 * M, 150 * M), 'heldout/waternsq/l2_2MB_mi50M/waternsq_4c', 'heldout/waternsq/l2_2MB_mi150M/waternsq_4c', True, 'waternsq_4t_window_'),
    ('fmm', 'fmm', (0, 1, 2, 3), (50 * M, 150 * M), 'heldout/fmm/l2_2MB_mi50M/fmm_4c', 'heldout/fmm/l2_2MB_mi150M/fmm_4c', True, 'fmm_4t_window_'),
] + [(p, p, (1, 2, 3, 4) if p == 'streamcluster' else (0, 1, 2, 3), (50 * M, 150 * M), NB.format(p=p, n=50), NB.format(p=p, n=150), True, f'{p}_4t_window_')
     for p in ('fft', 'lu', 'raytrace', 'streamcluster', 'volrend')]
# amendment 1: LU non-contiguous (rule c), counted and checked only with the nc set
NC_EXTRA = [('lunc', 'lunc', (0, 1, 2, 3), (50 * M, 150 * M), NB.format(p='lunc', n=50), NB.format(p='lunc', n=150), True, 'lunc_4t_window_')]
NC_SET = ('fft', 'volrend', 'lu', 'raytrace', 'streamcluster', 'lunc')
V1_PASSES = ('ocean', 'canneal', 'canneal8', 'barnes256', 'bstd-force', 'bstd-start', 'bstd-window', 'radix', 'waternsq', 'lu', 'raytrace')
B3_SET = ('ocean', 'canneal', 'canneal8', 'barnes256', 'bstd-start', 'bstd-force', 'bstd-window', 'radix', 'waternsq', 'fmm')
FIELDS = ('rec', 'ld', 'st', 'rmw', 'ginst', 'gld', 'gst', 'rep')


# ---------------------------------------------------------------- gem5rows
def gem5rows(root):
    print('# run cpu insts MemRead FloatMemRead MemWrite FloatMemWrite (stream_check2.py gem5rows; the last value in stats.txt)')
    pat = re.compile(r'system\.cpu(\d+)\.commitStats0\.(numInsts|committedInstType::(?:MemRead|FloatMemRead|MemWrite|FloatMemWrite))\s+(\d+)')
    for d, _, files in sorted(os.walk(root)):
        if 'stats.txt' not in files or '.prev_' in os.path.relpath(d, root):
            continue   # .prev_: a stopped run kept as <dir>.prev_<time> (heldout2_design Note 3), never read
        cpus, dumps = {}, 0
        for ln in open(os.path.join(d, 'stats.txt')):
            if ln.startswith('---------- Begin Simulation Statistics'):
                dumps += 1
            m = pat.match(ln)
            if m:
                cpus.setdefault(int(m.group(1)), {})[m.group(2).split('::')[-1]] = int(m.group(3))
        run = os.path.relpath(d, root)
        if dumps != 1:
            print(f'# {run}: {dumps} statistics dumps, the last one used')
        for c in sorted(cpus):
            v = cpus[c]
            print(run, c, *(v.get(k, 0) for k in ('numInsts', 'MemRead', 'FloatMemRead', 'MemWrite', 'FloatMemWrite')))


def read_percpu(path):
    g = {}
    for ln in open(path):
        p = ln.split()
        if p and not p[0].startswith('#'):
            g.setdefault(p[0], {})[int(p[1])] = tuple(int(x) for x in p[2:7])
    return g


# ---------------------------------------------------------------- rows
def read_cnt(path):
    at, last = {}, None
    for ln in open(path):
        p = ln.split()
        if p and p[0] in ('C', 'T'):
            v = tuple(int(x) for x in p[1:9])
            if p[0] == 'C':
                at[v[0]] = v
            else:
                last = v
    return at, last


def read_rtn(path):
    t = {'A': [], 'W': [], 'S': []}
    if os.path.exists(path):
        for ln in open(path):
            p = ln.split(None, 9)
            if len(p) >= 9 and p[0] in t:
                t[p[0]].append((tuple(int(x) for x in p[1:8]), p[8], p[9].strip() if len(p) > 9 else '?'))
    return t


def is_lib(image):
    return any(image.startswith(x) for x in LIBS)


def rows(top):
    print('# stream_check2.py rows', top)
    log = os.path.join(top, 'driver.log')
    if os.path.exists(log):
        for ln in open(log):
            if 'QE holds' in ln or 'QE FAILED' in ln or 'exact:' in ln:
                print('LOG', ln.strip())
    runs = os.path.join(top, 'runs')
    for rd in sorted(os.listdir(runs)) if os.path.isdir(runs) else []:
        name, mode, k = rd.split('__')
        d = os.path.join(runs, rd)
        st = open(os.path.join(d, 'STATUS')).read().split() if os.path.exists(os.path.join(d, 'STATUS')) else []
        st = dict(zip(st[0::2], st[1::2]))   # "exit RC seconds N", or "exit nofile FILE"
        st = ['exit', st.get('exit', '?'), 'seconds', st.get('seconds', '?')]
        prog = open(os.path.join(d, 'PROGS')).read().strip().split('|') if os.path.exists(os.path.join(d, 'PROGS')) else []
        skip = int(prog[6]) if len(prog) > 6 and prog[6] else 0
        cut0 = prog[7] if len(prog) > 7 and prog[7] else '0'
        creates = [tuple(int(x) for x in ln.split()[1:4]) for ln in open(os.path.join(d, 'c.summary')) if re.match(r'CREATE \d', ln)] \
            if os.path.exists(os.path.join(d, 'c.summary')) else []
        c0 = [c for c in creates if c[0] == 0]
        last0 = c0[-1] if c0 else (0, 0, 0)
        cpuid = [ln.strip() for ln in open(os.path.join(d, 'c.summary')) if ln.startswith('CPUID ')] if os.path.exists(os.path.join(d, 'c.summary')) else []
        # CPUID questions the emulation answered with zeros because FILE lacks them (-1: no emulation)
        unl = [int(m.group(1)) for m in (re.match(r'CPUID replaced \d+ unlisted (\d+)', x) for x in cpuid) if m]
        unlisted = unl[0] if unl else -1
        r0 = read_rtn(os.path.join(d, 'c.t0.rtn'))
        setup = sum(c[0] for c, _, _ in r0['S'])
        setup_libm = sum(c[0] for c, img, _ in r0['S'] if img.startswith('libm.so'))
        # QE's second half: no AVX / EVEX / FMA routine of the libraries runs (any thread, whole run)
        bad, badn = 0, set()
        for f in os.listdir(d):
            if re.match(r'c\.t\d+\.rtn$', f):
                for c, img, rtn in read_rtn(os.path.join(d, f))['A']:
                    if is_lib(img) and re.search(r'avx|evex|fma', rtn, re.I):
                        bad += c[0]
                        badn.add(rtn)
        print(f'RUN {name} {mode} {k} exit {st[1]} seconds {st[3]} skip {skip} cut0 {cut0} creates0 {len(c0)} '
              f'first0 {c0[0][1] if c0 else -1} last0 {last0[1]} last0_g {last0[2]} setup {setup} setup_libm {setup_libm} unlisted {unlisted} '
              f'avx_evex_fma_records {bad} {",".join(sorted(badn)) or "-"} ; {" ; ".join(cpuid) or "cpuid host"}')
        for wl, run, tids, (lo, hi), _, _, _, _ in WORKLOADS + NC_EXTRA:
            if run != name:
                continue
            for t in tids:
                path = os.path.join(d, f'c.t{t}.cnt')
                if not os.path.exists(path):
                    print(f'WIN {wl} {mode} {k} t{t} MISSING')
                    continue
                at, last = read_cnt(path)
                base = skip if (t != 0 or cut0 == '0') else last0[1]   # thread 0, cut: its last pthread_create
                a = 0 if lo is None else base + lo                      # None: from the thread's very start
                b = base + hi
                step = 100000
                ka, kb = int(round(a / step)) * step, int(round(b / step)) * step
                if ka not in at or kb not in at:
                    print(f'WIN {wl} {mode} {k} t{t} SHORT lo {a} hi {b} records {last[0] if last else 0}')
                    continue
                v = [y - x for x, y in zip(at[ka], at[kb])]
                rw = read_rtn(os.path.join(d, f'c.t{t}.rtn'))['W']
                libc_rep_gst = sum(c[6] for c, img, _ in rw if img.startswith('libc.so'))
                print(f'WIN {wl} {mode} {k} t{t} lo {ka} hi {kb} ' + ' '.join(f'{n} {x}' for n, x in zip(FIELDS, v)) +
                      f' wtable_libc_rep_gst {libc_rep_gst}')


# ---------------------------------------------------------------- check
def read_rows(path):
    runs, wins, log = {}, {}, []
    for ln in open(path):
        p = ln.split()
        if not p or p[0].startswith('#'):
            continue
        if p[0] == 'LOG':
            log.append(ln.strip())
        elif p[0] == 'RUN':
            kv = dict(zip(p[4::2], p[5::2]))
            runs[(p[1], p[2], p[3])] = kv
        elif p[0] == 'WIN' and len(p) > 6 and p[5] == 'lo':
            kv = dict(zip(p[5::2], p[6::2]))
            wins.setdefault((p[1], p[2], p[3]), {})[int(p[4][1:])] = {k: int(v) for k, v in kv.items()}
        elif p[0] == 'WIN':
            wins.setdefault((p[1], p[2], p[3]), {})[int(p[4][1:])] = None
    return runs, wins, log


def read_gem5_mix(path):
    rows = {}
    for ln in open(path):
        p = ln.split()
        if p and not p[0].startswith('#'):
            rows[p[0]] = dict(zip(('insts', 'LD', 'ST', 'RMW_Read', 'Locked_RMW_Read', 'Locked_RMW_Write', 'IFETCH'), map(int, p[1:])))
    return rows


def read_trace_mix(path):
    rows = {}
    for ln in open(path):
        m = re.match(r'\s*(\S+)\s+records (\d+) loads (\d+) stores (\d+) rmw (\d+)', ln)
        if m:
            rows[m.group(1)] = tuple(int(x) for x in m.groups()[1:])
    return rows


def gem5_window(percpu, a, b, cpus):
    """per CPU (insts, loads, stores) between the two stops"""
    out = {}
    for c in cpus:
        y = percpu.get(b, {}).get(c)
        x = percpu.get(a, {}).get(c, (0,) * 5) if a else (0,) * 5
        if y is None:
            return None
        d = [q - p for p, q in zip(x, y)]
        out[c] = (d[0], d[1] + d[2], d[3] + d[4])
    return out


def judge(x, y, rmw, held):
    """v1's rule: (verdict, note); x = trace, y = gem5"""
    if x == 0 and y == 0:
        return 'ok', ''
    off = abs(y - x) > TOL * x and not (rmw and abs(y - x) <= ABS_RMW)
    if off and held and not rmw and abs(y - x) <= SOFT * x:
        return 'soft', '   <-- 5-8% apart: scored with the miss stated'
    return ('off', '   <-- differs') if off else ('ok', '')


def v2(wl, mode, k, wins, percpu, gmix, verbose=True):
    """returns (holds, rates trace, rates gem5, per-thread) or None"""
    spec = next(w for w in WORKLOADS + NC_EXTRA if w[0] == wl)
    _, run, tids, _, a, b, held, _ = spec
    w = wins.get((wl, mode, k))
    if not w or any(w.get(t) is None for t in tids):
        if verbose:
            print(f'  {wl:13s} {mode:4s} {k}  -> NOT CHECKED (counter window missing or short)')
        return None
    g = gem5_window(percpu, a, b, tids)
    ga, gb = (gmix.get(a) if a else None), gmix.get(b)
    if g is None or gb is None:
        if verbose:
            print(f'  {wl:13s} {mode:4s} {k}  -> NOT CHECKED (gem5 run missing)')
        return None
    T = {f: sum(w[t][f] for t in tids) for f in FIELDS}
    gi = sum(g[t][0] for t in tids)
    tr = (1000 * T['gld'] / T['ginst'], 1000 * T['gst'] / T['ginst'], 1000 * T['rmw'] / T['ginst'])
    gw = {key: gb[key] - (ga[key] if ga else 0) for key in gb}
    gr = (1000 * sum(g[t][1] for t in tids) / gi, 1000 * sum(g[t][2] for t in tids) / gi,
          1000 * (gw['RMW_Read'] + gw['Locked_RMW_Read']) / gw['insts'])
    verdicts = []
    for name, x, y, isr in zip(('loads (micro-ops)', 'stores (micro-ops)', 'read-modify-write'), tr, gr, (False, False, True)):
        v, note = judge(x, y, isr, held)
        verdicts.append(v)
        if verbose:
            print(f'  {wl:13s} {mode:4s} {k}  {name:20s} {x:9.3f} {y:9.3f}   {y / x if x else float("nan"):7.3f}{note}')
    holds = 'off' not in verdicts
    per = {}
    for t in tids:
        xi = w[t]['ginst']
        per[t] = (1000 * w[t]['gld'] / xi if xi else 0, 1000 * w[t]['gst'] / xi if xi else 0,
                  1000 * g[t][1] / g[t][0] if g[t][0] else 0, 1000 * g[t][2] / g[t][0] if g[t][0] else 0, xi, g[t][0])
    if verbose:
        print(f'  {wl:13s} {mode:4s} {k}  -> {"same stream (v2)" if holds else "NOT THE SAME STREAM (v2)"}'
              f'{" (held-out rule, a 5-8% miss stated)" if "soft" in verdicts else ""}')
        for t in tids:
            l, s_, gl, gs, xi, gi_ = per[t]
            print(f'  {"":13s}           t{t}: loads {l:8.3f} / {gl:8.3f} ({gl / l if l else float("nan"):.3f})  stores {s_:8.3f} / {gs:8.3f} '
                  f'({gs / s_ if s_ else float("nan"):.3f})   instructions {xi / M:7.2f} M / {gi_ / M:7.2f} M')
    return holds, tr, gr, per


def check(rows_path, percpu_path, gmix_path, tmix_path, nbtraces='simulator/results/newbench/traces'):
    runs, wins, log = read_rows(rows_path)
    percpu, gmix, tmix = read_percpu(percpu_path), read_gem5_mix(gmix_path), read_trace_mix(tmix_path)
    verdict = {}

    print('== QE: the emulation takes')
    for ln in log:
        print('  ', ln)
    qe_dump = any('QE holds' in ln for ln in log)
    qe_routines = all(int(kv.get('avx_evex_fma_records', 1)) == 0 for (n, m, k), kv in runs.items() if m == 'gem5')
    for (n, m, k), kv in sorted(runs.items()):
        if m == 'gem5' and int(kv.get('avx_evex_fma_records', 0)):
            print(f'   {n} gem5 {k}: AVX/EVEX/FMA routines ran, {kv["avx_evex_fma_records"]} records')
    have_gem5 = any(m == 'gem5' for (_, m, _) in runs)
    # reported, not a condition (amendment 2): gem5 answers zeros for a leaf it lacks, as the emulation does
    for (n, m, k), kv in sorted(runs.items()):
        if m == 'gem5' and kv.get('unlisted', '0') != '0':
            print(f'   {n} gem5 {k}: {kv.get("unlisted")} CPUID questions not in gem5.cpuid (answered 0, as gem5 answers a leaf it lacks)')
    verdict['QE'] = qe_dump and qe_routines and have_gem5
    print(f'   QE {"HOLDS" if verdict["QE"] else "FAILS"} (dump {qe_dump}, no AVX/EVEX/FMA library routine in any gem5-CPUID run {qe_routines}, gem5 runs {have_gem5})')
    for (n, m, k), kv in sorted(runs.items()):
        if kv.get('exit') != '0':
            print(f'   run {n} {m} {k}: exit {kv.get("exit")}')

    print('\n== QC: the counter reproduces the trace (host CPUID; record units; v1\'s trace windows)')
    qc_fail = set()
    for wl, run, tids, _, _, _, _, prefix in WORKLOADS:
        w = wins.get((wl, 'host', '1'))
        t = {int(re.search(r'(\d+)$', key).group(1)): v for key, v in tmix.items() if key.startswith(prefix)}
        if wl == 'barnes256':
            t = {int(key[-1]): v for key, v in tmix.items() if re.match(r'barnes_4t\d$', key)}
        if wl in ('canneal',):
            t = {int(key[-1]): v for key, v in tmix.items() if re.match(r'canneal_4t_canneal\d$', key)}
        if wl == 'bstd-start':
            t = {int(key[-1]): v for key, v in tmix.items() if key.startswith('barnes_std_4t_start_t')}
        used = [x for x in tids if x in t]
        if not w or not used or any(w.get(x) is None for x in used):
            print(f'  {wl:13s} NOT CHECKED (trace rows {sorted(t)}, counter window {"present" if w else "missing"})')
            qc_fail.add(run)
            continue
        tr = [sum(t[x][i] for x in used) for i in range(4)]       # records loads stores rmw
        co = [sum(w[x][f] for x in used) for f in ('rec', 'ld', 'st', 'rmw')]
        bad = []
        cells = []
        for i, name in ((1, 'loads'), (2, 'stores'), (3, 'rmw')):
            rt, rc = 1000 * tr[i] / tr[0], 1000 * co[i] / co[0]
            ok = abs(rc - rt) <= 0.01 * rt or (i == 3 and abs(rc - rt) <= 0.01)
            cells.append(f'{name} {rt:8.3f} / {rc:8.3f}{"" if ok else " <--"}')
            if not ok:
                bad.append(name)
        if bad:
            qc_fail.add(run)
        print(f'  {wl:13s} threads {used}: trace / counter per 1,000: ' + '  '.join(cells) + f'   -> {"holds" if not bad else "FAILS: " + ", ".join(bad)}')
    verdict['QC_fail'] = qc_fail

    print('\n== QA: thread 0\'s last pthread_create in the counter\'s run against the trace\'s cut (host CPUID)')
    qa_fail = set()
    for (n, m, k), kv in sorted(runs.items()):
        if m != 'host' or k != '1' or kv.get('cut0', '0') == '0':
            continue
        cut = None
        if kv['cut0'] == 'auto':
            anc = os.path.join(nbtraces, n, 'anchor.txt')
            if os.path.exists(anc):
                mm = re.search(r'CUT (\d+)', open(anc).read())
                cut = int(mm.group(1)) if mm else None
        else:
            cut = int(kv['cut0'])
        mine = int(kv['last0'])
        ok = cut is not None and abs(mine - cut) <= 0.005 * cut
        if not ok:
            qa_fail.add(n)
        print(f'  {n:13s} trace cut {cut if cut is not None else "?":>13}  counter {mine:13,}  ({(mine - cut) / cut * 100 if cut else float("nan"):+.3f}%)  -> {"holds" if ok else "FAILS"}')
    verdict['QA_fail'] = qa_fail

    print('\n== v2, per 1,000 instructions (gem5 units), trace (counter) / gem5, gem5/trace')
    res = {}
    for wl, run, *_ in WORKLOADS:
        for mode, k in (('host', '1'), ('gem5', '1')):
            if (wl, mode, k) in wins:
                res[(wl, mode, k)] = v2(wl, mode, k, wins, percpu, gmix)
        print()

    def ok_run(run):
        return run not in verdict['QC_fail']

    print('== Predictions')
    # S0
    s0 = []
    for wl in V1_PASSES:
        r = res.get((wl, 'host', '1'))
        s0.append(bool(r and r[0]))
        if not (r and r[0]):
            print(f'  S0: {wl} {"not checked" if not r else "fails v2"}')
    r = res.get(('barnes256', 'host', '1'))
    b256 = bool(r) and abs(r[2][1] / r[1][1] - 1) < 0.03
    print(f'  S0: barnes256 stores gem5/trace {r[2][1] / r[1][1] if r else float("nan"):.3f} (within 3%: {b256})')
    r = res.get(('fmm', 'host', '1'))
    fmm_fails = bool(r) and not r[0]
    print(f'  S0: fmm fails v2: {fmm_fails}')
    S0 = all(s0) and b256 and fmm_fails
    print(f'  S0 {"HOLDS" if S0 else "FAILS"}')
    # S1
    r = res.get(('fft', 'host', '1'))
    S1 = None
    if r and ok_run('fft'):
        S1 = all(abs(r[3][t][2] / r[3][t][0] - 1) <= TOL and abs(r[3][t][3] / r[3][t][1] - 1) <= TOL for t in (1, 2, 3))
        for t in (1, 2, 3):
            l, s_, gl, gs, _, _ = r[3][t]
            print(f'  S1: fft t{t}: loads gem5/trace {gl / l:.3f}, stores {gs / s_:.3f}')
    print(f'  S1 {"HOLDS" if S1 else ("NOT SCORED (QC or data)" if S1 is None else "FAILS")}')
    # S2
    S2 = None
    h, g5 = runs.get(('fft', 'host', '1')), runs.get(('fft', 'gem5', '1'))
    a50 = 'newbench/fft/l2_2MB_mi50M/fft_4c'
    if h and g5 and a50 in percpu and verdict['QE'] and ok_run('fft'):
        g = percpu[a50]
        wbar = sum(g[c][0] for c in (1, 2, 3)) / 3
        dh = g[0][0] - int(h['last0_g']) - wbar
        dg = g[0][0] - int(g5['last0_g']) - wbar
        ds = int(h['setup']) - int(g5['setup'])
        dl = int(h['setup_libm']) - int(g5['setup_libm'])
        share = dl / ds if ds else float('nan')
        S2 = abs(dh - 99.21 * M) <= 2 * M and abs(dg) <= 5 * M and ds != 0 and share >= 0.8
        print(f'  S2: delta host {dh / M:+.2f} M (99 +- 2), gem5 CPUID {dg / M:+.2f} M (within 5); serial start host - gem5 '
              f'{ds / M:+.2f} M, of it libm {dl / M:+.2f} M ({share * 100:.0f}%, needs 80%)')
    print(f'  S2 {"HOLDS" if S2 else ("NOT SCORED (QE, QC or data)" if S2 is None else "FAILS")}')
    # S3
    S3 = None
    rh, rg = res.get(('streamcluster', 'host', '1')), res.get(('streamcluster', 'gem5', '1'))
    wh = wins.get(('streamcluster', 'host', '1'))
    if rh and rg and wh and verdict['QE'] and ok_run('streamcluster'):
        ts = (2, 3, 4)
        gst = sum(wh[t]['gst'] for t in ts)
        gin = sum(wh[t]['ginst'] for t in ts)
        g = gem5_window(percpu, NB.format(p='streamcluster', n=50), NB.format(p='streamcluster', n=150), ts)
        grate = sum(g[t][2] for t in ts) / sum(g[t][0] for t in ts)
        ratio = (gst / gin) / grate
        excess = gst - grate * gin
        rep = sum(wh[t]['wtable_libc_rep_gst'] for t in ts)
        part1 = ratio > 1 + TOL and excess > 0 and rep >= 0.6 * excess
        part2 = rg[0] and all(abs(rg[3][t][2] / rg[3][t][0] - 1) <= TOL and abs(rg[3][t][3] / rg[3][t][1] - 1) <= TOL for t in (1, 2, 3, 4))
        S3 = bool(part1 and part2)
        print(f'  S3: host, threads 2-4: write micro-ops trace/gem5 {ratio:.3f} (needs > 1.05); excess {excess / M:.3f} M, '
              f'of it libc REP {rep / M:.3f} M ({rep / excess * 100 if excess > 0 else float("nan"):.0f}%, needs 60%)')
        print(f'  S3: gem5 CPUID: v2 {"holds" if rg[0] else "fails"}; every worker within 5%: '
              f'{all(abs(rg[3][t][2] / rg[3][t][0] - 1) <= TOL and abs(rg[3][t][3] / rg[3][t][1] - 1) <= TOL for t in (1, 2, 3, 4))}')
    print(f'  S3 {"HOLDS" if S3 else ("NOT SCORED (QE, QC or data)" if S3 is None else "FAILS")}')
    # S4
    S4 = None
    vr = [wins.get(('volrend', 'gem5', k)) for k in ('1', '2', '3')]
    b = NB.format(p='volrend', n=150)
    a = NB.format(p='volrend', n=50)
    if all(vr) and all(all(w.get(t) for t in (0, 1, 2, 3)) for w in vr) and a in gmix and b in gmix and verdict['QE']:
        rates = [1000 * sum(w[t]['rmw'] for t in (0, 1, 2, 3)) / sum(w[t]['rec'] for t in (0, 1, 2, 3)) for w in vr]
        gw = {key: gmix[b][key] - gmix[a][key] for key in gmix[b]}
        grm = 1000 * (gw['RMW_Read'] + gw['Locked_RMW_Read']) / gw['insts']
        lo, hi = 0.95 * min(rates), 1.05 * max(rates)
        S4 = lo <= grm <= hi
        print(f'  S4: volrend RMWs per 1,000, three gem5-CPUID runs {", ".join(f"{x:.3f}" for x in rates)}; widened '
              f'[{lo:.3f}, {hi:.3f}]; gem5 {grm:.3f}')
    print(f'  S4 {"HOLDS" if S4 else ("NOT SCORED (QE or data)" if S4 is None else "FAILS")}')

    print('\n== What follows (stream_fix_design, "What follows")')
    qc_ok = not verdict['QC_fail']
    print(f'  F1 (v2 replaces v1): QC on every program {qc_ok}, S0 {S0}, S1 {S1} -> {"ADOPTED" if qc_ok and S0 and S1 else "not adopted"}')
    print(f'  F2 (traces with gem5\'s CPUID): QE {verdict["QE"]}, S2 {S2}, S3 {S3} -> {"YES" if verdict["QE"] and S2 and S3 else "no"}')
    print(f'  F3 (the native range for RMWs): S4 {S4} -> {"YES" if S4 else "no"}')
    print('\n== F2, the earlier programs: v2 with gem5\'s CPUID against v2 with the host\'s (trace side; under 2% on every rate keeps their traces)')
    for wl in B3_SET:
        rh, rg = res.get((wl, 'host', '1')), res.get((wl, 'gem5', '1'))
        if not (rh and rg):
            print(f'  {wl:13s} not compared')
            continue
        d = [abs(y / x - 1) if x else (0 if y == 0 else float('inf')) for x, y in zip(rh[1], rg[1])]
        print(f'  {wl:13s} loads {d[0] * 100:5.2f}%  stores {d[1] * 100:5.2f}%  RMWs {d[2] * 100:5.2f}%   -> {"under 2%" if max(d) < 0.02 else "2% OR MORE"}')
    return 0


# ---------------------------------------------------------------- ncheck
def nc_program(wl, wins, percpu, gmix, tmix, f3_range=None):
    """amendment 1, one program traced with gem5's CPUID: (read?, reason).
    f3_range: (lo, hi, gem5 rate) when F3 holds and the program has the three
    gem5-CPUID runs (record units, as S4), else None"""
    spec = next(w for w in WORKLOADS + NC_EXTRA if w[0] == wl)
    _, run, tids, _, a, b, held, prefix = spec
    w = wins.get((wl, 'gem5', '1'))
    t = {int(re.search(r'(\d+)$', key).group(1)): v for key, v in tmix.items() if key.startswith(prefix)}
    if not w or any(t_ not in t for t_ in tids) or any(w.get(x) is None for x in tids):
        print(f'  {wl:13s} QC-nc NOT CHECKED (trace rows {sorted(t)}, counter window {"present" if w else "missing"})')
        return False, 'QC-nc not checked'
    tr = [sum(t[x][i] for x in tids) for i in range(4)]
    co = [sum(w[x][f] for x in tids) for f in ('rec', 'ld', 'st', 'rmw')]
    bad, cells = [], []
    for i, name in ((1, 'loads'), (2, 'stores'), (3, 'rmw')):
        rt, rc = 1000 * tr[i] / tr[0], 1000 * co[i] / co[0]
        ok = abs(rc - rt) <= 0.01 * rt or (i == 3 and abs(rc - rt) <= 0.01)
        cells.append(f'{name} {rt:8.3f} / {rc:8.3f}{"" if ok else " <--"}')
        if not ok:
            bad.append(name)
    print(f'  {wl:13s} QC-nc, new traces / counter (gem5 CPUID) per 1,000: ' + '  '.join(cells) + f'   -> {"holds" if not bad else "FAILS: " + ", ".join(bad)}')
    if bad:
        return False, 'QC-nc fails'
    r = v2(wl, 'gem5', '1', wins, percpu, gmix)
    if r is None:
        return False, 'v2 not checked'
    if r[0]:
        return True, 'QC-nc and v2 hold'
    # F3: the RMW criterion met within the native range, if only RMWs miss
    lds = judge(r[1][0], r[2][0], False, held)[0]
    sts = judge(r[1][1], r[2][1], False, held)[0]
    if lds != 'off' and sts != 'off' and f3_range:
        lo, hi, g = f3_range
        print(f'  {wl:13s} F3: gem5 RMWs {g:.3f} per 1,000 against the native range widened [{lo:.3f}, {hi:.3f}] -> {"inside" if lo <= g <= hi else "outside"}')
        if lo <= g <= hi:
            return True, 'QC-nc holds; v2 holds with F3 for RMWs'
    return False, 'v2 fails'


def ncheck(rows_path, percpu_path, gmix_path, tmix_path, nc_tmix_path, nbtraces='simulator/results/newbench/traces'):
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        check(rows_path, percpu_path, gmix_path, tmix_path, nbtraces)
    out = buf.getvalue()
    f2 = re.search(r'F2 \(traces with gem5.s CPUID\):.*-> (YES|no)', out)
    f3 = re.search(r'F3 \(the native range for RMWs\):.*-> (YES|no)', out)
    print('== ncheck (stream_fix_design amendment 1): the programs traced with gem5\'s CPUID')
    print('  from check:', f2.group(0) if f2 else 'no F2 line', '|', f3.group(0) if f3 else 'no F3 line')
    if not (f2 and f2.group(1) == 'YES'):
        print('  F2 does not hold: the nc traces are not used, and no ratio from them is read')
        return 1
    runs, wins, log = read_rows(rows_path)
    percpu, gmix, tmix = read_percpu(percpu_path), read_gem5_mix(gmix_path), read_trace_mix(nc_tmix_path)
    f3_range = None
    if f3 and f3.group(1) == 'YES':
        vr = [wins.get(('volrend', 'gem5', k)) for k in ('1', '2', '3')]
        a, b = NB.format(p='volrend', n=50), NB.format(p='volrend', n=150)
        rates = [1000 * sum(w[t]['rmw'] for t in (0, 1, 2, 3)) / sum(w[t]['rec'] for t in (0, 1, 2, 3)) for w in vr]
        gw = {key: gmix[b][key] - gmix[a][key] for key in gmix[b]}
        f3_range = (0.95 * min(rates), 1.05 * max(rates), 1000 * (gw['RMW_Read'] + gw['Locked_RMW_Read']) / gw['insts'])
    verdicts = {}
    for wl in NC_SET:
        verdicts[wl] = nc_program(wl, wins, percpu, gmix, tmix, f3_range if wl == 'volrend' else None)
        print()
    print('== ncheck verdicts')
    for wl in NC_SET:
        ok, why = verdicts[wl]
        print(f'  {wl:13s} {"READ: its ratios may be read" if ok else "NOT READ"} ({why})')
    return 0


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == 'gem5rows':
        gem5rows(a[1])
    elif len(a) == 2 and a[0] == 'rows':
        rows(a[1])
    elif len(a) in (5, 6) and a[0] == 'check':
        return check(*a[1:])
    elif len(a) in (6, 7) and a[0] == 'ncheck':
        return ncheck(*a[1:])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
