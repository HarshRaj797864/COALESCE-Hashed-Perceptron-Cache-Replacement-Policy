#!/usr/bin/env python3
"""Part B of the breadth plan: the checks, then the score
(bench/policy_sanity/breadth_bc_design_2026-11-10.md; the scoring note is its
amendment 7 = Note 3). Set 2's checker (heldout2_score.py, check_program) with
each key's own threads, CPUs, stops, cut and tree; canneal at 16 cores by its
older procedure (amendment 1). Run on the laptop, from pulled files.

Rows (facts only, no verdict):
  partB_score.py keys SIZING > bench/policy_sanity/partB_keys_vN.txt
      SIZING  simulator/results/partB  (partB_all.sh pull: <key>/SIZED, NTHR, NCPU,
              SKIP, GEM5, PROGS, JOBS, MD5)
  partB_score.py tracerows KEYS TRACES > bench/policy_sanity/partB_trace_rows_vN.txt
      TRACES  simulator/results/partB/stage2/traces  (partB_all.sh tpull)
  partB_score.py countrows COUNT > bench/policy_sanity/partB_count_rows_vN.txt
      COUNT   simulator/results/partB/stage2/count   (heldout2_score.py's rows)
  partB_score.py runrows KEYS LOGS DRIVER_LOG > bench/policy_sanity/partB_run_rows_vN.txt
      LOGS    simulator/results/partB/stage2/logs; DRIVER_LOG simulator/results/partB/stage2/driver.log
  partB_score.py gem5cfg KEYS GEM5 > bench/policy_sanity/partB_gem5_config_vN.txt
      GEM5    simulator/results/gem5_b3  (pull_results.sh; with each run's limit.rc)

Verdicts:
  partB_score.py check KEYS TRACE_ROWS COUNT_ROWS RUN_ROWS GEM5_CONFIG GEM5_PERCPU GEM5_MIX GEM5_B3_ROWS PHASEA_ROWS B3_ROWS TRACE_MIX
      every check, per key; no B3 ratio is printed
  partB_score.py score (the same eleven files)
      the checks, then b3_score.py's blocks (b1@partB, b2@partB, b16@partB,
      p2@partB) for the keys that pass every check and only those, then the
      count per core count
  partB_score.py selftest
      hand cases (a stand-in world in a temporary directory)

On the F-C binary (amendment 10, F-C adopted 2026-11-14): the same commands
with --fc first. Each key's tree is read as phaseA_b3_fc_<tag>_<suffix>, the
chain's binary must be champsim_fc_a2e88e46 (runrows on the partBfc logs and
~/partBfc/driver.log), and check / score take a twelfth file, the FCQ rows:
  partB_score.py --fc fcrows KEYS REFLOGS FCLOGS > bench/policy_sanity/partB_fcq_rows_vN.txt
      REFLOGS simulator/results/partB/stage2fc/ref; FCLOGS simulator/results/partB/stage2fc/logs
      (partBfc_all.sh pull): each rerun against its g6 reference by
      lock_fix_score.py's qualify (the three extra 4-core points too)
  partB_score.py --fc check|score ... TRACE_MIX FCQ_ROWS
A key passes every check only if its rerun qualifies; the blocks are
fc_b1@partB, fc_b2@partB, fc_b16@partB, fc_p2@partB. Without --fc nothing
changes.
The cut-off (amendment 11): fcrows takes the partBfc chain log as a fifth
argument and ends each row 'ended <time>' (its 'END rc=0 complete' time, or -):
  partB_score.py --fc fcrows KEYS REFLOGS FCLOGS simulator/results/partB/stage2fc/driver.log
  partB_score.py --fc --cutoff 2026-12-05T23:59:00 --g6rows G6_RUN_ROWS check|score ...
A key whose FCQ row is not 'ok', or whose rerun ended after the cut-off (server
time), is checked and scored on its g6 run (its g6 tree, the g6 run rows from
runrows on the g6 chain, Q3 against champsim_g6_1e3060c1), labelled
'before F-C (g6)', in a block of its own after the F-C keys. Without --cutoff
nothing changes.
GEM5_PERCPU: stream_check2.py gem5rows; GEM5_MIX: b3_stream_check.py extract;
GEM5_B3_ROWS: b3_score.py gem5-rows; PHASEA_ROWS / B3_ROWS: pull_results.sh;
TRACE_MIX: a trace_mix file holding canneal_16t_t1..t16 (b3_stream_check.py window).

The checks are set 2's (heldout2_score.py states each), at each key's thread
count: QB (B1: the 8-thread key's binaries, SIZED there, and gem5 ran that
key's static binary), QT, Q3 (3 private caches a core), QG (the key's CPUs and
stops; a run stopped by its time limit fails it), QW, QC, v2, 500 events. A
key with no trace set, run log or counter run yet, or a gem5 run not started
or still running, is PENDING, not failed. canneal_16 (amendment 1): QG, the v1
same-stream check (5%), Q3 from its step 5 rows, 500 events; QW reported only.
"""
import contextlib
import io
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import b3_score            # noqa: E402
import b3_stream_check     # noqa: E402
import heldout2_score as h2  # noqa: E402
import lock_fix_score     # noqa: E402
import v2_located         # noqa: E402

FC = False                              # --fc: amendment 10
V2LOC = None                            # --v2loc FILE: amendment 12 (v2 on the located windows)
CUTOFF = None                           # --cutoff YYYY-MM-DDTHH:MM:SS (server time): amendment 11, with --fc
G6ROWS = None                           # --g6rows FILE: the g6 run rows a key falls back to (amendment 11)
G6_BIN0 = h2.G6_BIN                     # the g6 chain's binary (Q3 of a key scored on its g6 run)
FCQ_END = {}                            # key -> the F-C rerun's END time in the partBfc chain log, or None
FC_BIN = 'champsim_fc_a2e88e46'
FC_EXTRA = {'waternsq4': 'phaseA_b3_g3_waternsq4', 'raytrace4': 'phaseA_b3_n2_raytrace4',
            'streamcluster4': 'phaseA_b3_h2_streamcluster4'}   # amendment 10: 4-core points, scored by their own procedures


def fc_tree(tree):
    """phaseA_b3_<tag>_<suffix> -> phaseA_b3_fc_<tag>_<suffix>"""
    assert tree.startswith('phaseA_b3_') and not tree.startswith('phaseA_b3_fc_'), tree
    return 'phaseA_b3_fc_' + tree[len('phaseA_b3_'):]

M = 1_000_000
TRACER = h2.TRACER_H2           # Note 2: h2's tracer for every key
CPUID_FILE = '/sync_pb/gem5.cpuid'
B1 = {'fft_4': 'newbench/fft/l2_2MB_mi{}M/fft_4c', 'volrend_4': 'newbench/volrend/l2_2MB_mi{}M/volrend_4c',
      'fmm_4': 'heldout/fmm/l2_2MB_mi{}M/fmm_4c'}
ORDER = ['fft_4', 'volrend_4', 'fmm_4'] + [f'{p}_{n}' for n in (8, 16) for p in b3_score.PARTB_PROGRAMS] + ['canneal_16']
GEN = {4: 'b1', 8: 'b2', 16: 'b16'}
h2.ROLE.update({'b1': 'Part B, B1 (4 cores; step 4\'s P8-P10)', 'b2': 'Part B, B2 (8 cores; P18-P20)',
                'b16': 'Part B, B16 (16 cores; P22-P24)', 'v1': 'Part B, canneal at 16 cores (its older procedure; P22-P24)'})


def rd(path):
    return open(path).read().strip() if os.path.exists(path) else ''


def wsl_cpus(w):
    a, _, b = w.partition(':')
    return list(range(int(a), int(b)))


# ------------------------------------------------------------------ rows
def keys(sizing):
    """one KEY row a key, from sizing's records (the B1 keys from their
    8-thread key's records and the existing gem5 runs)"""
    print('# partB_score.py keys', sizing)
    for key in ORDER:
        prog, n = key.rsplit('_', 1)
        n = int(n)
        if key in B1:
            kd8 = os.path.join(sizing, f'{prog}_8')
            sta = next((ln.split()[2] for ln in rd(os.path.join(kd8, 'MD5')).splitlines() if ln.startswith('static ')), '-')
            sized = 'b1' if os.path.exists(os.path.join(kd8, 'SIZED')) else 'no'
            print(f'KEY {key} prog {prog} cores 4 tids 0,1,2,3 ncpu 4 stops 1,2,3 stopsM 50,150 skip 0 cut auto exe {sta} '
                  f'tree phaseA_b3_b1_{prog}4 wl {prog} run {B1[key]} sized {sized} procedure set2')
            continue
        kd = os.path.join(sizing, key)
        if not os.path.exists(os.path.join(kd, 'SIZED')):
            why = rd(os.path.join(kd, 'FAILED_E3')).replace('\n', ' ')[:120] or 'no SIZED'
            print(f'KEY {key} prog {prog} cores {n} sized no reason {why.replace(" ", "_")}')
            continue
        g = rd(os.path.join(kd, 'GEM5')).split('|')     # key|static|args|stdin|files|ncpu|wsl|limit|lo|hi
        lo, hi = int(g[8]) // M, int(g[9]) // M
        cpus = wsl_cpus(g[6])
        if key == 'canneal_16':   # amendment 1: its sync_mx traces (threads 1-16), step 5's run
            print(f'KEY {key} prog canneal cores 16 tids {",".join(str(t) for t in range(1, 17))} ncpu {g[5]} stops {",".join(map(str, cpus))} '
                  f'stopsM {lo},{hi} skip 0 cut 0 exe {g[1]} tree phaseA_b3_p2_canneal16 wl canneal run partB/{key}/l2_2MB_mi{{}}M/{key}c '
                  f'sized yes procedure v1')
            continue
        pr = rd(os.path.join(kd, 'PROGS')).splitlines()[0].split('|')   # key|dyn|args|stdin|files|tids|skip|cut0
        jb = rd(os.path.join(kd, 'JOBS')).splitlines()[0].split('|')    # suffix|wl|cores|scaled|warm|sim|key
        tids = pr[5].split()
        print(f'KEY {key} prog {prog} cores {n} tids {",".join(tids)} ncpu {g[5]} stops {",".join(map(str, cpus))} stopsM {lo},{hi} '
              f'skip {pr[6] or 0} cut {pr[7] or 0} exe {g[1]} tree phaseA_b3_{GEN[n]}_{jb[0]} wl {jb[1]} run partB/{key}/l2_2MB_mi{{}}M/{key}c '
              f'sized yes procedure set2')


def load_keys(path):
    K = {}
    for ln in open(path):
        q = ln.split()
        if not q or q[0] != 'KEY':
            continue
        d = h2.kv(q[2:])
        key = q[1]
        if d.get('sized') == 'no':
            K[key] = {'sized': 'no', 'prog': d['prog'], 'cores': int(d['cores']), 'reason': d.get('reason', '-').replace('_', ' ')}
            continue
        tids = tuple(int(x) for x in d['tids'].split(','))
        n = int(d['cores'])
        role = 'v1' if d['procedure'] == 'v1' else GEN[n]
        s = h2._p(tids, int(d['ncpu']), d['run'], d['exe'], TRACER, role,
                  tree=d['tree'], wl=d['wl'], cores=n, tdir='sync_pb', cut=d['cut'], skip=int(d['skip']),
                  stopsM=tuple(int(x) for x in d['stopsM'].split(',')), cpuid_file=CPUID_FILE, gem5_pending=True)
        s['stops'] = tuple(int(x) for x in d['stops'].split(','))
        s.update(sized=d['sized'], prog=d['prog'], procedure=d['procedure'])
        if FC:
            s.update(tree=fc_tree(s['tree']), g6_tree=s['tree'])
        K[key] = s
    return K


def tracerows(keys_path, top):
    K = load_keys(keys_path)
    print('# partB_score.py tracerows', keys_path, top)
    for key, s in K.items():
        if s['sized'] == 'no' or s['procedure'] == 'v1':
            continue
        print(f'SIZED {key} {s["sized"]}')
        h2.trace_set(key, s, os.path.join(top, key))


def runrows(keys_path, top, driver_log):
    K = {k: s for k, s in load_keys(keys_path).items() if s['sized'] != 'no' and s['procedure'] == 'set2'}
    h2.runrows(top, driver_log, K, 'partB_score.py')


def _one_log(top, tree, n):
    import glob
    f = sorted(glob.glob(os.path.join(top, tree, 'regime_shared', f'*_{n}core', 'lru', 'run.log')))
    return f[0] if f else None


def chain_ends(driver_log):
    """amendment 11: label -> the last 'END rc=0 complete' time in the partBfc chain log (YYYY-MM-DDTHH:MM:SS)"""
    ends = {}
    for ln in open(driver_log, errors='replace'):
        m = re.match(r'(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) (\S+): END rc=0 complete', ln)
        if m:
            ends[m.group(3)] = f'{m.group(1)}T{m.group(2)}'
    return ends


def fc_label(g6_tree):
    """phaseA_b3_b2_fmm8 -> fmm8 (the chain log's label)"""
    return re.search(r'^phaseA_b3_[a-z0-9]+?_(.*)$', g6_tree).group(1)


def fcrows(keys_path, ref_top, fc_top, driver_log=None):
    """amendment 10: one FCQ row a rerun -- ok, PENDING (no complete F-C log
    or reference yet) or FAILS with lock_fix_score.qualify's reason; with the
    chain log (amendment 11), each row ends 'ended <time>' or 'ended -'"""
    K = load_keys(keys_path)
    print('# partB_score.py --fc fcrows', keys_path, ref_top, fc_top, *([driver_log] if driver_log else []))
    ends = chain_ends(driver_log) if driver_log else None
    tail = (lambda g6: f' ended {ends.get(fc_label(g6), "-")}') if ends is not None else (lambda g6: '')
    items = [(k, K[k]['g6_tree'], K[k]['cores']) for k in ORDER if k in K and K[k]['sized'] != 'no']
    items += [(k, t, 4) for k, t in FC_EXTRA.items()]
    for key, g6, n in items:
        ref, new = _one_log(ref_top, g6, n), _one_log(fc_top, fc_tree(g6), n)
        if not ref or not new:
            print(f'FCQ {key} PENDING {"no F-C log" if ref else "no reference log"}' + tail(g6))
            continue
        old_txt, new_txt = open(ref, errors='replace').read(), open(new, errors='replace').read()
        if lock_fix_score.DONE not in old_txt or lock_fix_score.DONE not in new_txt:
            print(f'FCQ {key} PENDING {"the F-C rerun" if lock_fix_score.DONE in old_txt else "the reference"} has not completed' + tail(g6))
            continue
        why = lock_fix_score.qualify(old_txt, new_txt)
        print(f'FCQ {key} ' + ('ok' if not why else 'FAILS ' + why) + tail(g6))


def load_fcq(path):
    """FCQ rows -> {key: status}; their 'ended <time>' tails (amendment 11) go to FCQ_END"""
    Q = {}
    FCQ_END.clear()
    for ln in open(path):
        q = ln.split(None, 2)
        if len(q) >= 3 and q[0] == 'FCQ':
            st = q[2].strip()
            m = re.match(r'^(.*?) ended (\S+)$', st)
            if m:   # a row without the tail (fcrows without the chain log) leaves no FCQ_END entry
                st = m.group(1)
                FCQ_END[q[1]] = None if m.group(2) == '-' else m.group(2)
            Q[q[1]] = st
        elif len(q) == 2 and q[0] == 'FCQ':
            Q[q[1]] = ''
    return Q


def fallback_why(key):
    """amendment 11: why a key is scored on its g6 run at the cut-off, or None"""
    if not (FC and CUTOFF):
        return None
    q, e = FCQ.get(key), FCQ_END.get(key)
    if q != 'ok':
        return f'its F-C rerun at the cut-off: {"no FCQ row" if q is None else q}'
    if not e:
        return 'its F-C rerun has no END time in the chain log'
    if e > CUTOFF:
        return f'its F-C rerun ended {e}, after the cut-off'
    return None


def gem5cfg(keys_path, root):
    K = {k: s for k, s in load_keys(keys_path).items() if s['sized'] != 'no'}
    h2.gem5cfg(root, K, 'partB_score.py', limit=True)


# ------------------------------------------------------------------ check
def check_v1(key, s, G, g5rows, P, B, percpu, trace_mix, gmix_path, out):
    """canneal at 16 cores, by the procedure of its 4- and 8-core points"""
    say = out.append
    fails = []
    say(f'== {key} ({h2.ROLE["v1"]}); traced threads 1-16 (sync_mx/canneal16), run phaseA_b3_p2_canneal16 (step 5, LRU)')
    lo, hi = s['stopsM']
    pending = [f'{st} M' for st in (lo, hi) if (key, st) in G and (G[(key, st)] is None or G[(key, st)]['ended'] == 'NOT_ENDED')
               and (G[(key, st)] or {}).get('limit', '-') != '124']
    # QG
    why, rows = [], {}
    for st in (lo, hi):
        g = G.get((key, st))
        if not g:
            why.append(f'{st} M: no configuration')
            continue
        want = ','.join(f'{c}:{st * M if c in s["stops"] else 0}' for c in range(s['ncpu']))
        for cond, msg in ((g['ended'] == 'max_insts', f'{st} M stopped by its time limit (limit.rc 124)' if g.get('limit') == '124' else f'{st} M ended {g["ended"]}'),
                          (g['ncpu'] == str(s['ncpu']), f'{st} M: {g["ncpu"]} CPUs'), (g['exe'] == s['exe'], f'{st} M: binary {g["exe"]}'),
                          (g['l2'] == str(h2.L2_BYTES), f'{st} M: L2 {g["l2"]}'), (g['randomization'] == 'false', f'{st} M: randomization {g["randomization"]}'),
                          (g['stops'] == want, f'{st} M: stops {g["stops"]}')):
            if not cond:
                why.append(msg)
        rows[st] = g5rows.get(g['run'])
        if rows[st] is None:
            why.append(f'{st} M: no gem5 row')
    ev = None
    if rows.get(lo) and rows.get(hi):
        d = {k: int(rows[hi][k]) - int(rows[lo][k]) for k in ('insts', 'ss_getx', 'mt_getx', 'ss_upgrade', 'getx_all', 'demand_acc', 'demand_hits')}
        if min(d.values()) < 0:
            why.append('a gem5 counter went backwards between the stops')
        else:
            ev = d['ss_getx'] + d['mt_getx']
    say(f'   QG    {"holds" if not why else "FAILS: " + "; ".join(why)}: {s["ncpu"]} CPUs, {s["exe"]}, L2 2 MB, randomization false, '
        f'stop on CPUs {s["stops"][0]}-{s["stops"][-1]}')
    if why:
        fails.append('QG')
    # v1, the same-stream check of canneal's 4- and 8-core points (5%)
    buf = io.StringIO()
    keep = b3_stream_check.WORKLOADS
    b3_stream_check.WORKLOADS = tuple(w for w in keep if w[0] == 'canneal16')
    try:
        with contextlib.redirect_stdout(buf):
            b3_stream_check.check(trace_mix, gmix_path)
    finally:
        b3_stream_check.WORKLOADS = keep
    lines = [ln for ln in buf.getvalue().splitlines() if ln.strip().startswith('canneal16')]
    verdict = next((ln.split('->', 1)[1].strip() for ln in lines if '->' in ln), 'not checked')
    ok = verdict.startswith('same stream')
    say(f'   v1    {"holds" if ok else "FAILS"}: {verdict}')
    for ln in lines:
        if '->' not in ln:
            say('         ' + ln.strip())
    if not ok:
        fails.append('v1')
    # Q3, from its step 5 rows
    tree = s['tree']
    pr, br = P.get((tree, 'shared')), B.get((tree, 'shared'))
    why = []
    if not pr or not br:
        why.append('no LRU rows')
    else:
        for cond, msg in ((pr['st'] == 'complete' and br['st'] == 'complete', 'rows incomplete'), (pr['ins'] == br['ins'], 'the rows files disagree'),
                          (br.get('selfcheck') == '0' and br.get('registered') == '48', f'self-check {br.get("selfcheck")} / registered {br.get("registered")}'),
                          (br.get('stale_holders') == '0', f'stale-holders {br.get("stale_holders")}'), (br.get('level') == '2', f'level {br.get("level")}'),
                          (pr['vm'] == 'ok' and pr['tw'] == 'ok', f'vm {pr["vm"]} tw {pr["tw"]}')):
            if not cond:
                why.append(msg)
    say(f'   Q3    {"holds" if not why else "FAILS: " + "; ".join(why)} (its run log\'s view-order and deadlock checks: step 5\'s, policy_results_2026-11-10.md)')
    if why:
        fails.append('Q3')
    # QW, reported only (not part of canneal's procedure)
    a, b = s['run'].format(lo), s['run'].format(hi)
    if a in percpu and b in percpu:
        win = {c: percpu[b][c][0] - percpu[a][c][0] for c in percpu[b] if c in percpu[a]}
        trd = sum(win.get(t, 0) for t in s['tids'])
        unt = sum(v for c, v in win.items() if c not in s['tids'])
        say(f'   QW    reported only: untraced CPUs commit {100 * unt / trd if trd else float("nan"):.3f}% of the traced CPUs\' window instructions')
    if ev is None:
        say('   500   FAILS: no gem5 window')
        fails.append('500')
    else:
        say(f'   500   {"holds" if ev >= h2.MIN_EVENTS else "FAILS"}: gem5 counts {ev} store misses that find another core in the window (at least 500)')
        if ev < h2.MIN_EVENTS:
            fails.append('500')
    if pending:
        say(f'   -> PENDING: gem5 run{"s" if len(pending) > 1 else ""} at {" and ".join(pending)} not ended yet')
        return ['PENDING: gem5 not ended'], []
    say(f'   -> {"SCORED" if not fails else "NOT SCORED: fails " + ", ".join(fails)}')
    return fails, []


def fc_verdict(v, q, out):
    """amendment 10: a key's verdict (fails, notes) after its FCQ row q
    ('ok', 'PENDING ...', 'FAILS ...' or None); appends the FC line to out"""
    f, notes = v
    if q == 'ok':
        out.append('   FC    holds: the F-C rerun qualifies against its g6 reference (lock_fix_score.py qualify)')
        return v
    if q is None or q.startswith('PENDING'):
        out.append(f'   FC    PENDING: {"no FCQ row" if q is None else q[8:]}')
        # 2026-11-14: Q3 read from an F-C log still being written fails only as "not complete";
        # it is decided once the rerun completes, so it does not make the key "not scored"
        f = [x for x in f if x != 'Q3']
        return (['PENDING: F-C rerun not complete'], notes) if not f else (f, notes)
    out.append(f'   FC    FAILS: {q[6:]}')
    out.append('   -> NOT SCORED: fails FC')
    return (['FC'], notes) if not f or f[0].startswith('PENDING') else (f + ['FC'], notes)


def check(paths, quiet=False):
    global FCQ
    FCQ = load_fcq(paths[11]) if FC else {}
    if FC and CUTOFF and any(k not in FCQ_END for k in FCQ):
        sys.exit(f'--cutoff needs FCQ rows with END times: {paths[11]} was made without the chain log '
                 '(fcrows KEYS REFLOGS FCLOGS DRIVER_LOG, amendment 11)')
    K = load_keys(paths[0])
    T, C, R, G = h2.load_rows(paths[1:5])
    percpu, gmix = h2.read_percpu(paths[5]), h2.read_gem5_mix(paths[6])
    g5rows = b3_score.load(paths[7], b3_score.GEM5, lambda r: r['run'])
    P = b3_score.load(paths[8], b3_score.PHASEA, lambda r: (r['tree'], r['rg']), b3_score.lru)
    B = b3_score.load(paths[9], b3_score.B3, lambda r: (r['tree'], r['rg']), b3_score.lru)
    out = ['== Part B: the checks (breadth_bc_design_2026-11-10.md, Note 3' + ('; on the F-C binary, amendment 10' if FC else '')
           + (f'; F-C cut-off {CUTOFF} server time, amendment 11' if FC and CUTOFF else '')
           + ('; v2 on the located windows, amendment 12' if V2LOC is not None else '') + ')']
    R6 = h2.load_rows([paths[1], paths[2], G6ROWS, paths[4]])[2] if FC and CUTOFF else None
    for ln in C['log']:
        out.append('   counter ' + ln)
    out.append(f'   counter markers: {C["markers"]}')
    verdict = {}
    for key in ORDER:
        s = K.get(key)
        out.append('')
        if s is None:
            out.append(f'== {key}: no KEY row')
            verdict[key] = (['no KEY row'], [])
        elif s['sized'] == 'no':
            out.append(f'== {key}: NOT SIZED ({s["reason"]}): reported, excluded')
            verdict[key] = (['not sized'], [])
        elif fallback_why(key):   # amendment 11: scored on its g6 run, labelled
            s6 = dict(s, tree=s['g6_tree'], fallback=fallback_why(key))
            K[key] = s6
            keep = h2.G6_BIN
            h2.G6_BIN = G6_BIN0
            try:
                if s['procedure'] == 'v1':
                    verdict[key] = check_v1(key, s6, G, g5rows, P, B, percpu, paths[10], paths[6], out)
                else:
                    verdict[key] = h2.check_program(key, s6, T, C, R6, G, percpu, gmix, g5rows, P, B, out, v2loc=V2LOC)
            finally:
                h2.G6_BIN = keep
            out.append(f"   FC    amendment 11: {s6['fallback']} ({CUTOFF}): checked on its g6 run {s['g6_tree']}, labelled 'before F-C (g6)'")
        elif s['procedure'] == 'v1':
            verdict[key] = check_v1(key, s, G, g5rows, P, B, percpu, paths[10], paths[6], out)
        else:
            verdict[key] = h2.check_program(key, s, T, C, R, G, percpu, gmix, g5rows, P, B, out, v2loc=V2LOC)
        if FC and s is not None and s['sized'] != 'no' and not K[key].get('fallback'):
            verdict[key] = fc_verdict(verdict[key], FCQ.get(key), out)
    out.append('')
    out.append('== Verdicts')
    for key in ORDER:
        f, _ = verdict[key]
        g6 = ' [before F-C (g6)]' if (K.get(key) or {}).get('fallback') else ''
        out.append(f'   {key:18s} {"SCORED" if not f else "pending" + f[0][7:] if f[0].startswith("PENDING") else "not scored (" + ", ".join(f) + ")"}{g6}')
    if not quiet:
        print('\n'.join(out))
    return K, verdict


PN = re.compile(r'(P\d+) (R_g5|R_b) ([0-9.]+)|(P\d+) traffic ([0-9.]+) (holds|FAILS)')


def score(paths, checked=None):
    K, verdict = check(paths) if checked is None else checked
    passing = [k for k in ORDER if k in K and not verdict[k][0]]
    print('\n== The score, the keys that pass every check only (b3_score.py, @partB)')
    if not passing:
        print('   none passes every check: nothing is scored')
        return 0
    keep = b3_score.REFS['partB']
    sufs = {re.search(r'phaseA_b3_(?:fc_)?[a-z0-9]+?_(.*)$', K[k]['tree']).group(1): k for k in passing}
    g6keys = [k for k in passing if K[k].get('fallback')]
    text = ''
    # amendment 11: the keys on the F-C binary, then those scored on their g6 run (labelled); one block each
    for pre, group in (('fc_' if FC else '', [k for k in passing if k not in g6keys]), ('', g6keys)):
        if not group:
            continue
        mine = {sf: k for sf, k in sufs.items() if k in group}
        b3_score.REFS['partB'] = {suf: v for suf, v in keep.items() if suf in mine}
        gens = [pre + g for g in ('b1@partB', 'b2@partB', 'b16@partB', 'p2@partB')
                if any(K[k]['tree'].startswith(f'phaseA_b3_{pre}{g.split("@")[0]}_') for k in group)]
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                b3_score.score(paths[8], paths[9], paths[7], gens)
        finally:
            b3_score.REFS['partB'] = keep
        if group is g6keys:
            print(f"\n== Scored on their g6 run, labelled 'before F-C (g6)' (amendment 11): {', '.join(g6keys)}")
        print(buf.getvalue(), end='')
        text += buf.getvalue()
    for k in passing:
        if verdict[k][1]:
            print(f'   {k}: stated with its score (v2, the held-out rule): {"; ".join(verdict[k][1])}')
    # the count per core count: keys scored, discriminating, and the first prediction (R_g5 in the band)
    print('\n== Per core count (every key reported above; this counts the scored ones)')
    blocks = re.split(r'\n(?=   \S)', text)
    for n, gname, pfirst in ((4, 'B1', 'P8'), (8, 'B2', 'P18'), (16, 'B16', 'P22')):
        mine = [k for k in passing if K[k]['cores'] == n]
        disc, agree = [], []
        for k in mine:
            label = b3_score.REFS['partB'][next(sf for sf, kk in sufs.items() if kk == k)][0]
            blk = next((b for b in blocks if b.startswith(f'   {label}')), '')
            if 'not discriminating' in blk:
                continue
            m = re.search(rf'{pfirst} R_g5 ([0-9.]+) (holds|FAILS)', blk)
            if m:
                disc.append(k)
                if m.group(2) == 'holds':
                    agree.append(k + (' (g6)' if K[k].get('fallback') else ''))
        print(f'   {gname} ({n} cores): {len(mine)} scored, {len(disc)} discriminating, {pfirst} holds on {len(agree)} '
              f'({", ".join(agree) or "none"}); of {sum(1 for k in ORDER if k in K and K[k]["cores"] == n)} keys')
    return 0


# ------------------------------------------------------------------ selftest
def selftest():
    """a stand-in world: one 8-thread key (thread 0 cut at its anchor), one
    16-thread key not cut, B1's fft_4, canneal_16; then faults"""
    ok = bad = 0

    def expect(name, cond, got=''):
        nonlocal ok, bad
        if cond:
            ok += 1
        else:
            bad += 1
            print(f'   FAIL  {name}: {got}')

    with tempfile.TemporaryDirectory() as tmp:
        J = lambda *a: os.path.join(tmp, *a)  # noqa: E731

        def w(path, text):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, 'w').write(text)

        # sizing records
        for key, nthr, ncpu, wsl, tids, skip, cut, lo, hi in (('fmm_8', 8, 8, '1:8', '0 1 2 3 4 5 6 7', 0, 'auto', 50, 150),
                                                             ('radix_16', 16, 16, '1:16', ' '.join(map(str, range(16))), 1560 * M, '0', 1610, 1710),
                                                             ('fft_8', 8, 8, '1:8', '0 1 2 3 4 5 6 7', 0, 'auto', 50, 150)):
            p, n = key.rsplit('_', 1)
            sd = J('sizing', key)
            w(os.path.join(sd, 'SIZED'), '')
            w(os.path.join(sd, 'GEM5'), f'{key}|/srv/{p.upper()}|args|||{ncpu}|{wsl}|168h|{lo * M}|{hi * M}\n')
            w(os.path.join(sd, 'PROGS'), f'{key}|/srv/{p}.dyn|args|||{tids}|{skip}|{cut}\n')
            w(os.path.join(sd, 'JOBS'), f'{p}{n}|{p}|{n}|0|50000000|100000000|{key}\n')
            w(os.path.join(sd, 'MD5'), f'dynamic aa /srv/{p}.dyn\nstatic bb /srv/{p.upper()}\n')
        w(J('sizing', 'canneal_16', 'SIZED'), '')
        w(J('sizing', 'canneal_16', 'GEM5'), 'canneal_16|/srv/CANNEAL|16 15000 2000 n 128|||17|1:17|240h|50000000|150000000\n')
        w(J('sizing', 'barnes_8', 'FAILED_E3'), '9 thread starts, the recipe has 8\n')
        with contextlib.redirect_stdout(io.StringIO()) as o:
            keys(J('sizing'))
        w(J('keys.txt'), o.getvalue())
        K = load_keys(J('keys.txt'))
        expect('K1 fmm_8 stops', K['fmm_8']['stops'] == tuple(range(1, 8)) and K['fmm_8']['stopsM'] == (50, 150), K.get('fmm_8'))
        expect('K2 radix_16 stops at the skip', K['radix_16']['stopsM'] == (1610, 1710) and K['radix_16']['skip'] == 1560 * M, K.get('radix_16'))
        expect('K3 fft_4 from fft_8', K['fft_4']['sized'] == 'b1' and K['fft_4']['exe'] == '/srv/FFT' and K['fft_4']['run'].startswith('newbench/fft/'), K.get('fft_4'))
        expect('K4 volrend_4 without volrend_8: not sized', K['volrend_4']['sized'] == 'no', K.get('volrend_4'))
        expect('K5 barnes_8 FAILED_E3', K['barnes_8']['sized'] == 'no' and 'thread starts' in K['barnes_8']['reason'], K.get('barnes_8'))
        expect('K6 canneal_16 v1', K['canneal_16']['procedure'] == 'v1' and K['canneal_16']['tids'] == tuple(range(1, 17)), K.get('canneal_16'))
        expect('K7 trees', K['fmm_8']['tree'] == 'phaseA_b3_b2_fmm8' and K['radix_16']['tree'] == 'phaseA_b3_b16_radix16'
               and K['fft_4']['tree'] == 'phaseA_b3_b1_fft4', [K[k].get('tree') for k in ('fmm_8', 'radix_16', 'fft_4')])
        expect('K8 cut thread 0 runs raw0_aligned', h2.trace_name('fmm_8', K['fmm_8'], 0) == 'sync_pb/fmm_8/raw0_aligned.champsimtrace.xz'
               and h2.trace_name('radix_16', K['radix_16'], 0) == 'sync_pb/radix_16/raw0.champsimtrace.xz', '')

        # counter: thread 0 based at its last create (cut), a worker at the skip
        rd_ = J('count', 'runs', 'fmm_8__gem5__1')
        w(os.path.join(rd_, 'STATUS'), 'exit 0 seconds 5\n')
        w(os.path.join(rd_, 'RUN'), 'counter x\ncpuid y\n')
        w(os.path.join(rd_, 'PROGS'), 'fmm_8|/srv/fmm.dyn|||| 0 1|0|auto\n')
        w(os.path.join(rd_, 'c.summary'), 'KNOBS step 100000 skip 0 from 50000000 to 150000000 cut0 1 cpuid /x/sync_pb/gem5.cpuid (5 leaf/subleaf pairs)\n'
          'CREATE 0 1000000 1000000\nCREATE 0 2300000 2300000\nEXIT 0\n')
        for t, base in ((0, 2300000), (1, 0)):
            lines = ''.join(f'C {r} {r} {r // 2} {r // 4} 0 {r} {r // 2} {r // 4} 0\n' for r in range(0, 160 * M, 100000))
            w(os.path.join(rd_, f'c.t{t}.cnt'), lines)
        with contextlib.redirect_stdout(io.StringIO()) as o:
            h2.countrows(J('count'))
        txt = o.getvalue()
        expect('C1 thread 0 window from its last create', 'WIN fmm_8 gem5 1 t0 lo 52300000 hi 152300000' in txt, txt)
        expect('C2 a worker from its start', 'WIN fmm_8 gem5 1 t1 lo 50000000 hi 150000000' in txt, txt)
        expect('C3 RUN line names the base', 'start auto creates0 2 last0 2300000' in txt, txt)

        # gem5-rows: a run not ended has no row; an ended one with no dump still stops
        g5 = J('g5')
        w(os.path.join(g5, 'partB', 'fmm_8', 'l2_2MB_mi50M', 'fmm_8c', 'stats.txt'), '')
        w(os.path.join(g5, 'partB', 'fmm_8', 'l2_2MB_mi50M', 'fmm_8c', 'run.log'), 'still running\n')
        with contextlib.redirect_stdout(io.StringIO()) as o:
            b3_score.gem5_rows(g5)
        expect('G1 an unfinished run is skipped', 'not ended, no statistics -- no row' in o.getvalue(), o.getvalue())
        w(os.path.join(g5, 'partB', 'fmm_8', 'l2_2MB_mi50M', 'fmm_8c', 'run.log'), 'Exiting @ tick 5 because a thread reached the max instruction count\n')
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                b3_score.gem5_rows(g5)
            expect('G2 an ended run without statistics stops the rows', False, 'no exit')
        except SystemExit as e:
            expect('G2 an ended run without statistics stops the rows', 'statistics dumps' in str(e), str(e))

        # check_program on fmm_8 with stand-in rows: the pass, then faults
        s = K['fmm_8']
        T = {'sized': {'fmm_8': 'yes'}, 'set': {'fmm_8': {'done': TRACER, 'cpuid': h2.CPUID_MD5, 'len': '-', 'failed': '-', 'start0': '-', 'unbalanced': '0'}},
             'trace': {('fmm_8', t): {'records': '220000000', 'sync': '1000', 'instr': '219999000', 'wrec': str(100 * M), 'wld': str(40 * M),
                                      'wst': str(20 * M), 'wrmw': '1000'} for t in range(8)}}
        win = {f: v for f, v in zip(h2.FIELDS, (100 * M, 40 * M, 20 * M, 1000, 100 * M, 41 * M, 21 * M, 0))}
        C = {'runs': {('fmm_8', m, k): {'exit': '0', 'summary_exit': '0', 'counter': h2.COUNTER_MD5, 'cpuid': h2.CPUID_MD5 if m == 'gem5' else 'host',
                                        'knobs_cpuid': '/home/x/sync_pb/gem5.cpuid' if m == 'gem5' else 'host', 'from': str(h2.WIN[0]), 'to': str(h2.WIN[1]),
                                        'threads': ','.join(map(str, range(8))), 'cut0': '1', 'knobs_base0': '0', 'start': 'auto', 'skip': '0',
                                        'creates0': '3', 'base0': '-', 'bcast0': '0'}
                      for m, k in (('gem5', '1'), ('gem5', '2'), ('gem5', '3'), ('host', '1'))},
             'win': {('fmm_8', m, k, t): dict(win) for m, k in (('gem5', '1'), ('gem5', '2'), ('gem5', '3'), ('host', '1')) for t in range(8)},
             'log': [], 'markers': {}}
        R = {'chain': [h2.G6_BIN], 'run': {'fmm_8': {'complete': '1', 'deadlock': '0', 'eot': '0', 'raw': '2', 'bysilent': '2', 'unexplained': '0',
                                                      'mutex_order': 'timing', 'not_held': '0', 'replay': 'on',
                                                      'traces': ','.join(f'{c}:{h2.trace_name("fmm_8", s, c)}' for c in range(8))}}}
        run50, run150 = s['run'].format(50), s['run'].format(150)
        G = {('fmm_8', st): {'run': s['run'].format(st), 'ncpu': '8', 'exe': '/srv/FMM', 'nargs': '0', 'l2': str(h2.L2_BYTES), 'randomization': 'false',
                             'stops': ','.join(f'{c}:{st * M if c else 0}' for c in range(8)), 'ended': 'max_insts', 'limit': '0'} for st in (50, 150)}
        g5rows = {run50: dict(zip(b3_score.GEM5, [run50, 'max_insts', '400000000', '1000', '200', '50', '9000', '5000000', '4000000', '-'])),
                  run150: dict(zip(b3_score.GEM5, [run150, 'max_insts', '1200000000', '3000', '600', '150', '27000', '15000000', '12000000', '-']))}
        percpu = {run50: {c: (50 * M, 20 * M, 0, 10 * M, 0) for c in range(8)}, run150: {c: (150 * M, 61 * M, 0, 31 * M, 0) for c in range(8)}}
        gmix = {run50: {'insts': 400 * M, 'LD': 0, 'ST': 0, 'RMW_Read': 0, 'Locked_RMW_Read': 0, 'Locked_RMW_Write': 0, 'IFETCH': 0},
                run150: {'insts': 1200 * M, 'LD': 0, 'ST': 0, 'RMW_Read': 0, 'Locked_RMW_Read': 0, 'Locked_RMW_Write': 0, 'IFETCH': 0}}
        tree = s['tree']
        P = {(tree, 'shared'): {'st': 'complete', 'ins': '800000000', 'vm': 'ok', 'tw': 'ok'}}
        Bq = {(tree, 'shared'): {'st': 'complete', 'ins': '800000000', 'selfcheck': '0', 'registered': '24', 'stale_holders': '0', 'level': '2'}}

        def run(v2loc=None, **chg):
            import copy
            a = dict(T=copy.deepcopy(T), C=copy.deepcopy(C), R=copy.deepcopy(R), G=copy.deepcopy(G), percpu=copy.deepcopy(percpu), P=copy.deepcopy(P),
                     B=copy.deepcopy(Bq), s=copy.deepcopy(s))
            for k, f in chg.items():
                f(a[k])
            out = []
            f, _ = h2.check_program('fmm_8', a['s'], a['T'], a['C'], a['R'], a['G'], a['percpu'], gmix, g5rows, a['P'], a['B'], out, v2loc=v2loc)
            return f, '\n'.join(out)
        f, txt = run()
        expect('P0 the stand-in key passes every check', f == [], txt)
        cases = (
            ('F1 tracer not h2\'s', 'QT', dict(T=lambda x: x['set']['fmm_8'].update(done='f39707f3e4e197c409b362706a69e268'))),
            ('F2 thread 3 short', 'QT', dict(T=lambda x: x['trace'][('fmm_8', 3)].update(instr='170000000'))),
            ('F3 registered 12 at 8 cores', 'Q3', dict(B=lambda x: x[(tree, 'shared')].update(registered='12'))),
            ('F4 CPU 0 runs raw0 (not the cut trace)', 'Q3', dict(R=lambda x: x['run']['fmm_8'].update(traces=x['run']['fmm_8']['traces'].replace('raw0_aligned', 'raw0')))),
            ('F5 a stop on CPU 0', 'QG', dict(G=lambda x: x[('fmm_8', 50)].update(stops='0:50000000,' + x[('fmm_8', 50)]['stops'].split(',', 1)[1]))),
            ('F6 7 CPUs', 'QG', dict(G=lambda x: x[('fmm_8', 150)].update(ncpu='7'))),
            ('F7 counter cut0 0', 'QC', dict(C=lambda x: x['runs'][('fmm_8', 'gem5', '2')].update(cut0='0'))),
            ('F8 counter on h2\'s cpuid file', 'QC', dict(C=lambda x: x['runs'][('fmm_8', 'gem5', '1')].update(knobs_cpuid='/home/x/sync_h2/gem5.cpuid'))),
            ('F9 an untraced CPU at 2%', 'QW', dict(percpu=lambda x: (x[run50].__setitem__(8, (0, 0, 0, 0, 0)), x[run150].__setitem__(8, (16 * M, 0, 0, 0, 0))))),
            ('F10 a time-limit stop', 'QG', dict(G=lambda x: x[('fmm_8', 150)].update(ended='NOT_ENDED', limit='124'))),
        )
        for name, want, chg in cases:
            f, txt = run(**chg)
            expect(name, want in f, f'{f}\n{txt}')
        f, txt = run(G=lambda x: x[('fmm_8', 150)].update(ended='NOT_ENDED', limit='-'))
        expect('F11 a gem5 run still running: PENDING, not failed', f and f[0].startswith('PENDING') and 'not ended yet' in f[0], f)
        f, txt = run(G=lambda x: x.__setitem__(('fmm_8', 150), None))
        expect('F12 a gem5 run not started: PENDING', f and f[0].startswith('PENDING'), f)
        # amendment 12: v2 on the located windows. gem5 410 loads, 210 stores, 0 RMWs per 1,000 (gem5 units)
        def loc(ld, st, rmw):
            return {'fmm_8': {k: dict(ginst=800 * M, gld=int(ld * 800_000), gst=int(st * 800_000), rmw=int(rmw * 800_000)) for k in ('1', '2', '3')}}
        f0, t0 = run()
        f1, t1 = run(v2loc=loc(410, 210, 0.01))
        expect('L1 located rates equal: v2 holds, labelled, counter windows reported', f1 == [] and "counter runs' located range (amendment 12)" in t1
               and 'counter windows (reported): loads [410.000, 410.000], stores [210.000, 210.000], RMWs [0.010, 0.010]' in t1, t1)
        expect('L1b without --v2loc the block is unchanged', 'amendment 12' not in t0 and 'counter windows (reported)' not in t0, t0)
        f, t = run(v2loc=loc(410, 180, 0.01))
        expect('L2 located stores 16.7% apart: v2 fails though the counter windows pass', 'v2' in f and 'stores 210.000 in [180.000, 180.000] <-- outside' in t, t)
        f, t = run(v2loc=loc(410, 210, 0.01), C=lambda x: [w.update(gst=15 * M) for kk, w in x['win'].items() if kk[1] == 'gem5'])
        expect('L3 counter windows 29% apart, located equal: v2 holds', f == [] and 'stores [150.000, 150.000]' in t, t)
        f, t = run(v2loc=loc(410, 197, 0.01))
        expect('L4 located stores 6.6% apart: scored with the miss stated', f == [] and '5-8% outside: scored, the miss stated' in t, t)
        f, t = run(v2loc={'other_8': loc(1, 1, 1)['fmm_8']})
        expect('L5 no located rows for the key: v2 not checked', 'v2' in f and 'no located rows for the three counter runs' in t, t)
        f, t = run(v2loc={'fmm_8': 'gem5 per-CPU rows missing (a gem5 run not ended)'})
        expect('L6 LOCNOT: v2 not checked, the reason printed', 'v2' in f and 'amendment 12: gem5 per-CPU rows missing' in t, t)
        f, t = run(v2loc={'fmm_8': {k: v for k, v in loc(410, 210, 0.01)['fmm_8'].items() if k != '3'}})
        expect('L7 two of three runs located: v2 not checked', 'v2' in f, t)
        f, t = run(v2loc=loc(410, 210, 0.2))
        expect('L8 located RMWs 0.200 against gem5 0: RMWs gate', 'v2' in f and 'RMWs 0.000 in [0.200, 0.200] <-- outside' in t, t)
        expect('F10b its message names the limit', 'stopped by its time limit' in run(G=lambda x: x[('fmm_8', 150)].update(ended='NOT_ENDED', limit='124'))[1], '')

        # canneal_16 (v1): the stream check reads only canneal16's rows
        cs = K['canneal_16']
        tm = J('trace_mix.txt')
        w(tm, ''.join(f'canneal_16t_t{t} records 100000000 loads 37600000 stores 21500000 rmw 1158000 rmw_per_ki 11.58 (trace_mix.c)\n' for t in range(1, 17)))
        a50, a150 = cs['run'].format(50), cs['run'].format(150)
        gm = J('gem5_mix.txt')
        w(gm, '# run insts ' + ' '.join(b3_stream_check.TYPES) + '\n'
          f'{a50} 800000000 0 0 0 0 0 0\n{a150} 2400000000 {int(1600e6 * (0.376 - 0.01158))} {int(1600e6 * (0.215 - 0.01158))} 0 {int(1600e6 * 0.01158)} {int(1600e6 * 0.01158)} 0\n')
        Gc = {('canneal_16', st): {'run': cs['run'].format(st), 'ncpu': '17', 'exe': '/srv/CANNEAL', 'nargs': '5', 'l2': str(h2.L2_BYTES),
                                   'randomization': 'false', 'stops': ','.join(f'{c}:{st * M if c else 0}' for c in range(17)), 'ended': 'max_insts', 'limit': '0'}
              for st in (50, 150)}
        g5c = {a50: dict(zip(b3_score.GEM5, [a50, 'max_insts', '800000000', '1000', '0', '0', '2000', '1', '0', '-'])),
               a150: dict(zip(b3_score.GEM5, [a150, 'max_insts', '2400000000', '3000', '0', '0', '6000', '3', '0', '-']))}
        Pc = {('phaseA_b3_p2_canneal16', 'shared'): {'st': 'complete', 'ins': '1', 'vm': 'ok', 'tw': 'ok'}}
        Bc = {('phaseA_b3_p2_canneal16', 'shared'): {'st': 'complete', 'ins': '1', 'selfcheck': '0', 'registered': '48', 'stale_holders': '0', 'level': '2'}}
        out = []
        f, _ = check_v1('canneal_16', cs, Gc, g5c, Pc, Bc, {}, tm, gm, out)
        expect('V1 canneal_16 passes by its procedure', f == [], '\n'.join(out))
        w(tm, ''.join(f'canneal_16t_t{t} records 100000000 loads 30000000 stores 21500000 rmw 1158000 rmw_per_ki 11.58 (trace_mix.c)\n' for t in range(1, 17)))
        out = []
        f, _ = check_v1('canneal_16', cs, Gc, g5c, Pc, Bc, {}, tm, gm, out)
        expect('V2 loads 25% apart: v1 fails', 'v1' in f, '\n'.join(out))
        out = []
        f, _ = check_v1('canneal_16', cs, Gc, g5c, Pc, {k: dict(v, registered='12') for k, v in Bc.items()}, {}, tm, gm, out)
        expect('V3 registered 12: Q3 fails', 'Q3' in f, '\n'.join(out))

        # the score: hand-computed rows. gem5 window 800 M instructions, 2,400
        # events (0.003/KI), demand 10 M (12.5/KI). fmm_8: R_g5 1,800 events =
        # 0.75 (P18 holds), R_b 2,000 = 0.833, traffic 1.000. radix_16: R_g5 0.30
        # (P22 fails). fft_16: gem5 400 events, not discriminating.
        rows = J('rows')
        Kx = {'fmm_8': K['fmm_8'], 'radix_16': K['radix_16'],
              'fft_16': dict(K['radix_16'], tree='phaseA_b3_b16_fft16', run='partB/fft_16/l2_2MB_mi{}M/fft_16c', cores=16, stopsM=(50, 150))}
        pa, b3, gg = [], [], ['# gem5 rows']
        for key, tree, n, rg5, prot, ev in (('fmm_8', 'phaseA_b3_b2_fmm8', 8, 1800, 2000, 2400), ('radix_16', 'phaseA_b3_b16_radix16', 16, 720, 2000, 2400),
                                            ('fft_16', 'phaseA_b3_b16_fft16', 16, 300, 400, 400)):
            pa.append(f'{tree} lru {key.split("_")[0]} {n} shared complete ok ok 9 9 800000000 0 0 12000000 0 2000000 0 0 0 0 0 1 0')
            b3.append(f'{tree} lru {key.split("_")[0]} {n} shared complete 800000000 0 0 0 0 0 0 {prot} 0 {3 * n} 0 0 2 0 0 0 0 0 0 {prot} 0 {rg5} 0 0 0 0')   # B3's 32 columns: rfo_bounded = prot, rfo_g5 = rg5
            lo, hi = b3_score.REFS['partB'][re.search(r'_([a-z]+\d+)$', tree).group(1)][1:]
            gg.append(f'{lo} max_insts 400000000 0 0 0 0 0 0 0,0')
            gg.append(f'{hi} max_insts 1200000000 {ev - ev // 6} {ev // 6} 0 {ev} 10000000 0 400000000,400000000')
        w(os.path.join(rows, 'pa.txt'), '\n'.join(pa) + '\n')
        w(os.path.join(rows, 'b3.txt'), '\n'.join(b3) + '\n')
        w(os.path.join(rows, 'g5.txt'), '\n'.join(gg) + '\n')
        paths = [None] * 11
        paths[7], paths[8], paths[9] = os.path.join(rows, 'g5.txt'), os.path.join(rows, 'pa.txt'), os.path.join(rows, 'b3.txt')
        with contextlib.redirect_stdout(io.StringIO()) as o:
            score(paths, (Kx, {k: ([], []) for k in Kx}))
        txt = o.getvalue()
        expect('S1 fmm_8: P18 R_g5 0.750 holds, R_b 0.833, traffic 1.000', 'P18 R_g5 0.750 holds; P19 R_b 0.833 >= R_g5: holds; P20 traffic 1.000 holds' in txt, txt)
        expect('S2 radix_16: P22 R_g5 0.300 FAILS', 'P22 R_g5 0.300 FAILS' in txt, txt)
        expect('S3 fft_16 not discriminating', 'not discriminating: gem5 counts 400' in txt, txt)
        expect('S4 the counts', 'B2 (8 cores): 1 scored, 1 discriminating, P18 holds on 1 (fmm_8)' in txt
               and 'B16 (16 cores): 2 scored, 1 discriminating, P22 holds on 0 (none)' in txt, txt)
        with contextlib.redirect_stdout(io.StringIO()) as o:
            score(paths, (Kx, {'fmm_8': (['QW'], []), 'radix_16': (['PENDING: x'], []), 'fft_16': (['QC'], [])}))
        expect('S5 nothing passes: nothing scored', 'nothing is scored' in o.getvalue() and 'R_g5' not in o.getvalue(), o.getvalue())

        # amendment 10 (--fc): trees, the FCQ rows, the check, the score
        global FC
        expect('F1 fc_tree', fc_tree('phaseA_b3_b2_fmm8') == 'phaseA_b3_fc_b2_fmm8' and fc_tree('phaseA_b3_p2_canneal16') == 'phaseA_b3_fc_p2_canneal16')
        FC = True
        try:
            Kf = load_keys(J('keys.txt'))
            expect('F2 --fc keys: trees fc_, g6_tree kept', Kf['fmm_8']['tree'] == 'phaseA_b3_fc_b2_fmm8' and Kf['fmm_8']['g6_tree'] == 'phaseA_b3_b2_fmm8'
                   and Kf['canneal_16']['tree'] == 'phaseA_b3_fc_p2_canneal16' and Kf['fft_4']['tree'] == 'phaseA_b3_fc_b1_fft4', Kf.get('fmm_8'))
            new = '\n'.join(['Number of CPUs: 1', 'CPU 0 runs a.xz', 'Warmup Instructions: 10', 'Simulation Instructions: 20',
                             'PRIVATE-CACHE COHERENCE LEVEL: 2', 'cpu0_L1D COHERENCE DIR SELF-CHECK MISMATCHES: 0',
                             'LLC COHERENCE DIR STALE-HOLDER VIOLATIONS: 0', 'LLC COHERENCE DIR PRIVATE CACHES REGISTERED: 3',
                             'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED: 0',
                             'CPU 0 MUTEX WAITED ACQUIRES: measured contended 3 own 1 cycles 60; warmup contended 1 own 0',
                             'SYNC LOCK WORD: request', 'CPU 0 LOCK-WORD REQUESTS: measured 3 warmup 1', lock_fix_score.DONE, ''])
            old = '\n'.join(ln for ln in new.splitlines() if 'LOCK WORD' not in ln and 'LOCK-WORD' not in ln)
            for top, tree, n_, txt in (('ref', 'phaseA_b3_b2_fmm8', 8, old), ('fc', 'phaseA_b3_fc_b2_fmm8', 8, new),                         # ok
                                       ('ref', 'phaseA_b3_b16_radix16', 16, old), ('fc', 'phaseA_b3_fc_b16_radix16', 16, old),          # no request
                                       ('ref', 'phaseA_b3_b1_fft4', 4, old),                                                            # no F-C log
                                       ('ref', 'phaseA_b3_g3_waternsq4', 4, old), ('fc', 'phaseA_b3_fc_g3_waternsq4', 4, new.replace(lock_fix_score.DONE, ''))):
                w(J('fcq', top, tree, 'regime_shared', f'{tree.rsplit("_", 1)[1][:-len(str(n_))]}_{n_}core', 'lru', 'run.log'), txt)
            with contextlib.redirect_stdout(io.StringIO()) as o:
                fcrows(J('keys.txt'), J('fcq', 'ref'), J('fcq', 'fc'))
            Q = {ln.split()[1]: ln.split(None, 2)[2] for ln in o.getvalue().splitlines() if ln.startswith('FCQ ')}
            expect('F3 fcrows: a qualifying rerun ok', Q.get('fmm_8') == 'ok', Q)
            expect('F4 fcrows: a rerun without the request FAILS', Q.get('radix_16', '').startswith('FAILS no single'), Q)
            expect('F5 fcrows: no F-C log PENDING; incomplete rerun PENDING; extras listed',
                   Q.get('fft_4', '').startswith('PENDING no F-C') and Q.get('waternsq4', '').startswith('PENDING the F-C rerun')
                   and Q.get('raytrace4', '').startswith('PENDING no reference') and 'canneal_16' in Q, Q)
            # the check's FC step (fc_verdict), on verdicts as check_program leaves them
            for name, f0, q, want in (('ok, passing', [], 'ok', []), ('FAILS, passing', [], 'FAILS no single line', ['FC']),
                                      ('no row, passing', [], None, ['PENDING: F-C rerun not complete']),
                                      ('PENDING row, passing', [], 'PENDING no F-C log', ['PENDING: F-C rerun not complete']),
                                      ('ok, failing QW', ['QW'], 'ok', ['QW']), ('FAILS, failing QW', ['QW'], 'FAILS x', ['QW', 'FC']),
                                      ('FAILS, gem5 pending', ['PENDING: gem5 not ended'], 'FAILS x', ['FC']),
                                      ('Q3 from a rerun still running, PENDING row', ['Q3'], 'PENDING the F-C rerun has not completed', ['PENDING: F-C rerun not complete']),
                                      ('Q3 and 500, PENDING row', ['Q3', '500'], 'PENDING the F-C rerun has not completed', ['500'])):
                out = []
                got = fc_verdict((list(f0), []), q, out)[0]
                expect(f'F6 fc_verdict: {name}', got == want and out and out[0].startswith('   FC '), (got, out))
            # the score on fc_ trees: the same hand rows, block fc_b2@partB / fc_b16@partB
            Kfx = {k: dict(v, tree=fc_tree(v['tree'])) for k, v in Kx.items()}
            fx = [os.path.join(rows, n_) for n_ in ('g5.txt', 'pa_fc.txt', 'b3_fc.txt')]
            w(fx[1], '\n'.join(ln.replace('phaseA_b3_', 'phaseA_b3_fc_', 1) for ln in pa) + '\n')
            w(fx[2], '\n'.join(ln.replace('phaseA_b3_', 'phaseA_b3_fc_', 1) for ln in b3) + '\n')
            pf = [None] * 12
            pf[7], pf[8], pf[9] = fx
            with contextlib.redirect_stdout(io.StringIO()) as o:
                score(pf, (Kfx, {k: ([], []) for k in Kfx}))
            t2 = o.getvalue()
            expect('F7 --fc score: the same verdicts from the fc_ trees', 'P18 R_g5 0.750 holds; P19 R_b 0.833 >= R_g5: holds; P20 traffic 1.000 holds' in t2
                   and 'P22 R_g5 0.300 FAILS' in t2 and 'phaseA_b3_fc_b2_*' in t2 and 'B2 (8 cores): 1 scored, 1 discriminating, P18 holds on 1 (fmm_8)' in t2, t2)
            # amendment 11: the cut-off, the chain log's END times, the fallback to the g6 run
            global CUTOFF, G6ROWS, FCQ
            w(J('fcq', 'driver.log'), '2026-11-15 04:33:15 fmm8: END rc=0 complete; SYNC LOCK WORD request lines 1\n'
              '2026-11-15 04:00:00 radix16: START\n2026-12-06 01:00:00 radix16: END rc=0 complete; x\n'
              '2026-11-14 11:24:06 fft4: END rc=1 failed\n')
            expect('A1 chain_ends and fc_label', chain_ends(J('fcq', 'driver.log')) == {'fmm8': '2026-11-15T04:33:15', 'radix16': '2026-12-06T01:00:00'}
                   and fc_label('phaseA_b3_p2_canneal16') == 'canneal16' and fc_label('phaseA_b3_h2_streamcluster4') == 'streamcluster4', '')
            with contextlib.redirect_stdout(io.StringIO()) as o:
                fcrows(J('keys.txt'), J('fcq', 'ref'), J('fcq', 'fc'), J('fcq', 'driver.log'))
            rows_ = [ln for ln in o.getvalue().splitlines() if ln.startswith('FCQ ')]
            expect('A2 fcrows with the chain log: every row ends with its END time or -',
                   all(re.search(r' ended (\S+)$', ln) for ln in rows_) and 'FCQ fmm_8 ok ended 2026-11-15T04:33:15' in rows_
                   and any(ln.startswith('FCQ fft_4 PENDING') and ln.endswith(' ended -') for ln in rows_), rows_)
            w(J('fcq', 'rows.txt'), o.getvalue())
            FCQ = load_fcq(J('fcq', 'rows.txt'))
            expect('A3 load_fcq splits the status from the END time', FCQ.get('fmm_8') == 'ok' and FCQ_END.get('fmm_8') == '2026-11-15T04:33:15'
                   and FCQ_END.get('fft_4') is None and FCQ.get('radix_16', '').startswith('FAILS no single'), (FCQ, FCQ_END))
            w(J('fcq', 'rows_old.txt'), 'FCQ fmm_8 ok\nFCQ fft_4 PENDING no F-C log\n')
            load_fcq(J('fcq', 'rows_old.txt'))
            expect('A3b rows without the chain log leave no END entry', FCQ_END == {}, FCQ_END)
            FCQ = load_fcq(J('fcq', 'rows.txt'))
            CUTOFF = None
            expect('A4 no cut-off: no fallback', fallback_why('fft_4') is None, '')
            CUTOFF = '2026-12-05T23:59:00'
            FCQ.update(late='ok', nend='ok')
            FCQ_END.update(late='2026-12-06T00:00:01', nend=None)
            for name, key, want in (('ok before the cut-off', 'fmm_8', None), ('ok after it', 'late', 'after the cut-off'),
                                    ('no END time', 'nend', 'no END time'), ('PENDING', 'fft_4', 'PENDING'),
                                    ('FAILS', 'radix_16', 'FAILS no single'), ('no row', 'nokey', 'no FCQ row')):
                got = fallback_why(key)
                expect(f'A5 fallback_why: {name}', (got is None) if want is None else (got is not None and want in got), got)
            # the score: fmm_8 on its F-C tree, radix_16 on its g6 tree (labelled); both groups printed
            K11 = {'fmm_8': dict(Kx['fmm_8'], tree=fc_tree(Kx['fmm_8']['tree'])),
                   'radix_16': dict(Kx['radix_16'], fallback='its F-C rerun ended 2026-12-06T01:00:00, after the cut-off')}
            f11 = [os.path.join(rows, n_) for n_ in ('g5.txt', 'pa_11.txt', 'b3_11.txt')]
            w(f11[1], '\n'.join([ln.replace('phaseA_b3_', 'phaseA_b3_fc_', 1) for ln in pa] + pa) + '\n')
            w(f11[2], '\n'.join([ln.replace('phaseA_b3_', 'phaseA_b3_fc_', 1) for ln in b3] + b3) + '\n')
            p11 = [None] * 12
            p11[7], p11[8], p11[9] = f11
            with contextlib.redirect_stdout(io.StringIO()) as o:
                score(p11, (K11, {k: ([], []) for k in K11}))
            t3 = o.getvalue()
            expect('A6 score: the F-C key on fc_b2, the late key on b16 under its label, counted with (g6)',
                   'phaseA_b3_fc_b2_*' in t3 and "Scored on their g6 run, labelled 'before F-C (g6)' (amendment 11): radix_16" in t3
                   and 'phaseA_b3_b16_*' in t3 and 'phaseA_b3_fc_b16_*' not in t3 and 'P22 R_g5 0.300 FAILS' in t3
                   and 'B2 (8 cores): 1 scored, 1 discriminating, P18 holds on 1 (fmm_8)' in t3
                   and 'B16 (16 cores): 1 scored, 1 discriminating, P22 holds on 0 (none)' in t3, t3)
            CUTOFF = G6ROWS = None
        finally:
            FC = False
            FCQ = {}
            FCQ_END.clear()
            CUTOFF = G6ROWS = None
    print(f'== selftest: {ok} hold, {bad} fail ==')
    return 1 if bad else 0


FCQ = {}


def main():
    global FC, V2LOC, CUTOFF, G6ROWS
    a = sys.argv[1:]
    while a[:1] in (['--v2loc'], ['--cutoff'], ['--g6rows']) or (a[:1] == ['--fc'] and not FC):
        if a[0] == '--fc':
            FC, a = True, a[1:]
            continue
        if len(a) < 2:
            print(__doc__)
            return 1
        if a[0] == '--v2loc' and V2LOC is None:
            V2LOC = v2_located.load_loc(a[1])
        elif a[0] == '--cutoff' and CUTOFF is None and re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d', a[1]):
            CUTOFF = a[1]
        elif a[0] == '--g6rows' and G6ROWS is None:
            G6ROWS = a[1]
        else:
            print(__doc__)
            return 1
        a = a[2:]
    if (CUTOFF is None) != (G6ROWS is None) or (CUTOFF and not FC):
        print('--cutoff and --g6rows go together, with --fc (amendment 11)')
        return 1
    if FC:
        h2.G6_BIN = FC_BIN           # Q3: the chain's binary (CHAIN START of ~/partBfc/driver.log)
        if len(a) in (4, 5) and a[0] == 'fcrows':
            fcrows(*a[1:])
            return 0
        if a[:1] in (['check'], ['score']):
            if len(a) != 13:
                print(__doc__)
                return 1
            if a[0] == 'check':
                check(a[1:])
                return 0
            return score(a[1:])
    if len(a) == 2 and a[0] == 'keys':
        keys(a[1])
    elif len(a) == 3 and a[0] == 'tracerows':
        tracerows(a[1], a[2])
    elif len(a) == 2 and a[0] == 'countrows':
        h2.countrows(a[1])
    elif len(a) == 4 and a[0] == 'runrows':
        runrows(a[1], a[2], a[3])
    elif len(a) == 3 and a[0] == 'gem5cfg':
        gem5cfg(a[1], a[2])
    elif len(a) == 12 and a[0] == 'check':
        check(a[1:])
    elif len(a) == 12 and a[0] == 'score':
        return score(a[1:])
    elif a == ['selftest']:
        return selftest()
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
