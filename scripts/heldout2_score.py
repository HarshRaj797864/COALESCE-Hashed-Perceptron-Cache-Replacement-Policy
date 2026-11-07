#!/usr/bin/env python3
"""Held-out set 2 and streamcluster: the checks, then the score
(bench/policy_sanity/heldout2_design_2026-11-04.md, Note 8; streamcluster by
bench/policy_sanity/newbench_design_2026-10-19.md, amendment 3).

Rows, each from pulled files (facts only, no verdict; run on the laptop):
  heldout2_score.py tracerows TRACES SIZING NB_SIZING > bench/policy_sanity/h2_trace_rows_vN.txt
      TRACES     simulator/results/heldout2/traces   (traces/sync_h2 reports: DONE, CPUID, LEN, FAILED, pin.err, raw<t>.mix)
      SIZING     simulator/results/heldout2/server   (~/heldout2: <p>/SIZED)
      NB_SIZING  simulator/results/newbench/server   (~/newbench: streamcluster/CHOSEN)
  heldout2_score.py countrows COUNT > bench/policy_sanity/h2_count_rows_vN.txt
      COUNT      simulator/results/heldout2/count    (heldout2_all.sh pullcount)
  heldout2_score.py runrows LOGS DRIVER_LOG > bench/policy_sanity/h2_run_rows_vN.txt
      LOGS       simulator/results/heldout2/logs     (phaseA_b3_h2_<p>4/.../run.log)
      DRIVER_LOG simulator/results/heldout2/driver.log (~/sync_h2/driver.log)
  heldout2_score.py gem5cfg GEM5 > bench/policy_sanity/h2_gem5_config_vN.txt
      GEM5       simulator/results/gem5_b3           (config.ini and run.log of each run)

Verdicts:
  heldout2_score.py check TRACE_ROWS COUNT_ROWS RUN_ROWS GEM5_CONFIG GEM5_PERCPU GEM5_MIX GEM5_B3_ROWS PHASEA_ROWS B3_ROWS
      every check, per program, and whether it is scored. No B3 ratio is printed.
  heldout2_score.py score (the same nine files)
      the checks, then b3_score.py's block (h2@set2) for the programs that pass
      every check and only those, then the target.
GEM5_PERCPU: stream_check2.py gem5rows; GEM5_MIX: b3_stream_check.py extract;
GEM5_B3_ROWS: b3_score.py gem5-rows; PHASEA_ROWS / B3_ROWS: pull_results.sh.

The checks (Note 8 states each; the tolerances are the design's, unchanged):
  QB   the program was sized (set 2: SIZED, written only after QB held;
       streamcluster: step 4's sizing, CHOSEN)
  QT   the trace set's DONE names the tracer Note 6 / amendment 3 gives, CPUID
       is gem5.cpuid's md5, no FAILED; every traced thread's trace holds at
       least 172.5 M instructions (records minus sync records) and reaches
       record 150 M; facesim's thread 0 opened at its broadcast
  Q3   the ChampSim run completed on the g6 binary: no SYNC DEADLOCK, no end
       of trace, VIEW-ORDER VIOLATIONS UNEXPLAINED 0 (raw = by silent
       re-listing), self-check 0 with 12 private caches, stale-holders 0,
       level 2, sync replay on, mutex order by timing, each CPU on its thread's
       trace; the two rows files agree on the instructions
  QG   both gem5 runs ended at their stop; the configuration shows the static
       binary, the CPUs, the 2 MB L2, randomization false, the stop on the
       traced CPUs but CPU 0 (Note 3) and no other; no counter goes backwards
  QW   in gem5's window, the untraced CPUs commit under 1% of the traced CPUs'
       instructions
  QC   per 1,000 records over records 50-150 M, summed over the traced
       threads: the trace's loads, stores and RMWs lie inside the three
       gem5-CPUID counter runs' range widened by 1% on each side (RMWs: or
       within 0.01 per 1,000 of it). Each counter run: exit 0, the h2 counter,
       gem5's CPUID, the window 50-150 M, facesim based at its broadcast
  v2   per 1,000 instructions in gem5's units: gem5's loads and stores (the
       traced CPUs) and RMWs (Ruby, all CPUs) lie inside the three counter
       runs' range widened by 5% (RMWs: or within 0.05 per 1,000). Loads and
       stores up to 8% outside are scored with the miss stated; RMWs gate
  500  gem5 counts at least 500 events (SS + MT L1_GETX) in the window
A program failing any check is reported with it and not scored.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import b3_score  # noqa: E402  (the score block, REFS['set2'])

M = 1_000_000
STEP = 100_000                 # the counter's running-count step (records)
WIN = (50 * M, 150 * M)        # v1's window: records 50-150 M of each traced thread
MIN_TRACE = 172_500_000        # QT (Note 6)
MIN_EVENTS = 500
CPUID_MD5 = '74d72229d62c92e4ce627b5298375a23'      # QE's gem5.cpuid
COUNTER_MD5 = '22776143da830acac58082ebc8f2eede'    # h2's counter (QR held, Note 5)
TRACER_H2 = '02ff8f48654b81f6f277cdac8a13d60b'      # -start0 broadcast (Note 4)
TRACER_NC = 'f39707f3e4e197c409b362706a69e268'      # nc's (QS, QK)
G6_BIN = 'champsim_g6_1e3060c1'
L2_BYTES = 2 * 1024 * 1024
QW_MAX = 0.01
QC_WIDEN, QC_RMW_ABS = 0.01, 0.01
V2_WIDEN, V2_RMW_ABS, V2_SOFT = 0.05, 0.05, 0.08
SRV = '/home/harshraj'
FIELDS = ('rec', 'ld', 'st', 'rmw', 'ginst', 'gld', 'gst', 'rep')


def _p(tids, ncpu, run, exe, tracer, role):
    return dict(tids=tids, ncpu=ncpu, run=run, exe=exe, tracer=tracer, role=role,
                stops=tuple(t for t in tids if t != 0))


def _h2run(p):
    return f'heldout2/{p}/l2_2MB_mi{{}}M/{p}_4c'


# program: traced threads (thread t on gem5 CPU t), gem5 CPUs, gem5 runs (stop
# in M), the static binary gem5 ran, the tracer, the role (Notes 2, 3, 4, 6;
# newbench amendment 3). Fixed by Note 8.
PROGRAMS = {
    'fluidanimate': _p((1, 2, 3, 4), 5, _h2run('fluidanimate'), f'{SRV}/heldout2_static/fluidanimate', TRACER_NC, 'counted'),
    'bodytrack': _p((1, 2, 3, 4), 6, _h2run('bodytrack'), f'{SRV}/heldout2_static/bodytrack', TRACER_NC, 'counted'),
    'facesim': _p((0, 1, 2, 3), 4, _h2run('facesim'), f'{SRV}/heldout2_static/facesim', TRACER_H2, 'counted'),
    'vips': _p((3, 4, 5, 6), 7, _h2run('vips'), f'{SRV}/heldout2_static/vips', TRACER_NC, 'counted'),
    'oceannc': _p((0, 1, 2, 3), 4, _h2run('oceannc'), f'{SRV}/heldout2_static/OCEAN-NC', TRACER_NC, 'apart'),
    'streamcluster': _p((1, 2, 3, 4), 5, 'newbench/streamcluster/l2_2MB_mi{}M/streamcluster_4c', f'{SRV}/splash-newbench/streamcluster', TRACER_NC, 'step4'),
}
ROLE = {'counted': 'held-out set 2, counted', 'apart': 'reported apart, never counted',
        'step4': 'step 4 program, scored by set 2\'s procedure (newbench amendment 3)'}


def first_word(path):
    if not os.path.exists(path):
        return '-'
    w = open(path).read().split()
    return w[0] if w else '-'


# ------------------------------------------------------------------ rows
def tracerows(top, sizing, nb_sizing):
    print('# heldout2_score.py tracerows', top, sizing, nb_sizing)
    for p, s in PROGRAMS.items():
        if p == 'streamcluster':
            sized = 'step4' if os.path.exists(os.path.join(nb_sizing, p, 'CHOSEN')) else 'no'
        else:
            sized = 'yes' if os.path.exists(os.path.join(sizing, p, 'SIZED')) else 'no'
        print(f'SIZED {p} {sized}')
        d = os.path.join(top, p)
        if not os.path.isdir(d):
            print(f'SET {p} ABSENT')
            continue
        err = open(os.path.join(d, 'pin.err')).read() if os.path.exists(os.path.join(d, 'pin.err')) else ''
        start0 = ('never' if 'window NEVER opened' in err else
                  'opened' if "start0: thread 0's window opens after" in err else '-')
        print(f'SET {p} done {first_word(os.path.join(d, "DONE"))} cpuid {first_word(os.path.join(d, "CPUID"))} '
              f'len {first_word(os.path.join(d, "LEN"))} failed {first_word(os.path.join(d, "FAILED"))} '
              f'start0 {start0} unbalanced {err.count("UNBALANCED")}')
        for t in s['tids']:
            f = os.path.join(d, f'raw{t}.mix')
            if not os.path.exists(f):
                print(f'TRACE {p} t{t} MISSING')
                continue
            at, T = {}, None
            for ln in open(f):
                q = ln.split()
                if q and q[0] == 'C':
                    at[int(q[1])] = tuple(int(x) for x in q[2:5])
                elif q and q[0] == 'T':
                    T = q
            if T is None:
                print(f'TRACE {p} t{t} NO-T-LINE')
                continue
            rec = int(T[1])
            sync = int(T[-1]) if T[-2] == 'sync' else 0
            a, b = WIN
            if a in at and b in at:   # as b3_stream_check.py window: records [50 M, 150 M), sync records count as records
                ld, st, rmw = (at[b][i] - at[a][i] for i in range(3))
                print(f'TRACE {p} t{t} records {rec} sync {sync} instr {rec - sync} wrec {b - a} wld {ld} wst {st} wrmw {rmw}')
            else:
                print(f'TRACE {p} t{t} records {rec} sync {sync} instr {rec - sync} SHORT')


def read_cnt(path):
    at = {}
    for ln in open(path):
        q = ln.split()
        if q and q[0] == 'C':
            v = tuple(int(x) for x in q[1:9])
            at[v[0]] = v
    return at


def countrows(top):
    print('# heldout2_score.py countrows', top)
    log = os.path.join(top, 'driver.log')
    if os.path.exists(log):
        for ln in open(log):
            if re.search(r'QE-h2 (holds|FAILED)|COUNT (DONE|ENDED)', ln):
                print('LOG', ln.strip())
    print(f'MARKERS done {"yes" if os.path.exists(os.path.join(top, "DONE")) else "no"} counter_md5 {first_word(os.path.join(top, "COUNTER_MD5"))}')
    runs = os.path.join(top, 'runs')
    for rd in sorted(os.listdir(runs)) if os.path.isdir(runs) else []:
        parts = rd.split('__')
        if len(parts) != 3:
            continue
        p, mode, k = parts
        d = os.path.join(runs, rd)
        st = open(os.path.join(d, 'STATUS')).read().split() if os.path.exists(os.path.join(d, 'STATUS')) else []
        st = dict(zip(st[0::2], st[1::2]))
        run = {}
        if os.path.exists(os.path.join(d, 'RUN')):
            for ln in open(os.path.join(d, 'RUN')):
                q = ln.split(None, 1)
                if q:
                    run[q[0]] = q[1].strip() if len(q) > 1 else ''
        prog = open(os.path.join(d, 'PROGS')).read().strip().split('|') if os.path.exists(os.path.join(d, 'PROGS')) else []
        tids = [int(x) for x in prog[5].split()] if len(prog) > 5 and prog[5].strip() else []
        skip = int(prog[6]) if len(prog) > 6 and prog[6] else 0
        start = prog[7] if len(prog) > 7 and prog[7] else '0'
        summ = open(os.path.join(d, 'c.summary')).read().splitlines() if os.path.exists(os.path.join(d, 'c.summary')) else []
        kn = next((ln for ln in summ if ln.startswith('KNOBS step ')), '')
        m = re.match(r'KNOBS step (\d+) skip (\d+) from (\d+) to (\d+) cut0 (\d+) cpuid (\S+) \(', kn)
        kf, kt, kc, kcpu = (m.group(3), m.group(4), m.group(5), m.group(6)) if m else ('-', '-', '-', '-')
        kbase0 = any(ln.strip() == 'KNOBS base0 broadcast' for ln in summ)
        b0 = [ln.split()[2] for ln in summ if ln.startswith('BASE0 broadcast ')]
        bc0 = [ln for ln in summ if re.match(r'BROADCAST 0 ', ln)]
        ex = next((ln.split()[1] for ln in summ if ln.startswith('EXIT ')), '-')
        un = next((m2.group(1) for m2 in (re.match(r'CPUID replaced \d+ unlisted (\d+)', ln) for ln in summ) if m2), '-')
        print(f'RUN {p} {mode} {k} exit {st.get("exit", "?")} summary_exit {ex} counter {run.get("counter", "-")} cpuid {run.get("cpuid", "-")} '
              f'attempt {run.get("attempt", "-")} binary {run.get("binary", "-")} from {kf} to {kt} cut0 {kc} knobs_cpuid {kcpu} '
              f'knobs_base0 {int(kbase0)} base0 {",".join(b0) or "-"} bcast0 {len(bc0)} unlisted {un} threads {",".join(map(str, tids)) or "-"} '
              f'skip {skip} start {start}')
        for t in tids:
            path = os.path.join(d, f'c.t{t}.cnt')
            if not os.path.exists(path):
                print(f'WIN {p} {mode} {k} t{t} MISSING')
                continue
            if start.startswith('start0:') and t == 0:
                if len(b0) != 1 or not b0[0].isdigit():
                    print(f'WIN {p} {mode} {k} t{t} NOBASE')
                    continue
                base = int(b0[0])       # thread 0 based at its first broadcast (Note 5)
            elif start == '0' or start.startswith('start0:'):
                base = skip             # each thread from its start (a worker: its creation); facesim's workers too (Note 8, amendment 1)
            else:
                print(f'WIN {p} {mode} {k} t{t} UNSUPPORTED start {start}')
                continue
            at = read_cnt(path)
            a, b = base + WIN[0], base + WIN[1]
            ka, kb = int(round(a / STEP)) * STEP, int(round(b / STEP)) * STEP   # the counter's grid, as stream_check2.py rows
            if ka not in at or kb not in at:
                print(f'WIN {p} {mode} {k} t{t} SHORT lo {a} hi {b}')
                continue
            v = [y - x for x, y in zip(at[ka], at[kb])]
            print(f'WIN {p} {mode} {k} t{t} lo {ka} hi {kb} ' + ' '.join(f'{n} {x}' for n, x in zip(FIELDS, v)))


def roi(lines):
    out, on = [], False
    for ln in lines:
        if ln.startswith('Region of Interest Statistics'):
            on = True
        if on:
            out.append(ln)
    return out


def runrows(top, driver_log):
    print('# heldout2_score.py runrows', top, driver_log)
    if os.path.exists(driver_log):
        for ln in open(driver_log):
            if 'CHAIN START' in ln:
                b = re.findall(r'champsim_\S+', ln)
                print(f'CHAIN start binary {b[-1] if b else "-"} | {ln.strip()}')
    for p, s in PROGRAMS.items():
        f = os.path.join(top, f'phaseA_b3_h2_{p}4', 'regime_shared', f'{p}_4core', 'lru', 'run.log')
        if not os.path.exists(f):
            print(f'RUNLOG {p} ABSENT')
            continue
        lines = open(f, errors='replace').read().splitlines()
        r = roi(lines)

        def llc(name):
            v = [ln.split()[-1] for ln in r if re.match(rf'LLC COHERENCE DIR {name}:', ln)]
            return v[0] if v else '-'
        cpus = {}
        for ln in lines:
            m = re.match(r'CPU (\d+) runs (\S+)', ln)
            if m:
                cpus[int(m.group(1))] = m.group(2)
        traces = ','.join(f'{c}:{cpus[c].split("/traces/")[-1] if "/traces/" in cpus[c] else cpus[c]}' for c in sorted(cpus))
        rep = next((ln.split(':', 1)[1].strip() for ln in lines if ln.startswith('SYNC REPLAY:')), '-')
        mx = next((ln for ln in lines if ln.startswith('SYNC MUTEX ORDER:')), '')
        mm = re.match(r'SYNC MUTEX ORDER: (\S+) \(.*releases of a mutex not held (\d+)\)', mx)
        print(f'RUNLOG {p} complete {int(any("ChampSim completed all CPUs" in ln for ln in lines))} '
              f'deadlock {sum("SYNC DEADLOCK" in ln for ln in lines)} eot {sum("Reached end of trace" in ln for ln in lines)} '
              f'raw {llc("VIEW-ORDER VIOLATIONS")} bysilent {llc("VIEW-ORDER LINES BY SILENT RE-LISTING")} '
              f'unexplained {llc("VIEW-ORDER VIOLATIONS UNEXPLAINED")} mutex_order {mm.group(1) if mm else "-"} '
              f'not_held {mm.group(2) if mm else "-"} replay {rep.replace(" ", "_")} traces {traces or "-"}')


def gem5cfg(root):
    print('# heldout2_score.py gem5cfg', root)
    for p, s in PROGRAMS.items():
        for stop in (50, 150):
            run = s['run'].format(stop)
            d = os.path.join(root, run)
            c = os.path.join(d, 'config.ini')
            if not os.path.exists(c):
                print(f'G5CFG {p} {stop} ABSENT {run}')
                continue
            sec, stops, ncpu, rnd, l2, cmd = '', {}, 0, '-', '-', None
            for ln in open(c):
                ln = ln.rstrip('\n')
                if ln.startswith('['):
                    sec = ln[1:-1]
                    continue
                k, _, v = ln.partition('=')
                if re.fullmatch(r'system\.cpu\d+', sec) and k == 'max_insts_any_thread':
                    n = int(sec[10:])
                    stops[n] = v
                    ncpu = max(ncpu, n + 1)
                elif sec == 'system.ruby' and k == 'randomization':
                    rnd = v
                elif re.fullmatch(r'system\.ruby\.l2_cntrl\d+\.L2cache', sec) and k == 'size':
                    l2 = v
                elif re.fullmatch(r'system\.cpu\d+\.workload', sec) and k == 'cmd' and cmd is None:
                    cmd = v.split()
            log = open(os.path.join(d, 'run.log'), errors='replace').read() if os.path.exists(os.path.join(d, 'run.log')) else ''
            m = re.search(r'Exiting @ tick \d+ because (.*)', log)
            ended = 'max_insts' if m and 'max instruction count' in m.group(1) else ('program_end' if m else 'NOT_ENDED')
            print(f'G5CFG {p} {stop} run {run} ncpu {ncpu} exe {cmd[0] if cmd else "-"} nargs {len(cmd) - 1 if cmd else -1} '
                  f'l2 {l2} randomization {rnd} stops {",".join(f"{n}:{stops[n]}" for n in sorted(stops))} ended {ended}')


# ------------------------------------------------------------------ check
def kv(words):
    return dict(zip(words[0::2], words[1::2]))


def load_rows(paths):
    tr_rows, cnt, runr, cfg = paths[:4]
    T = {'sized': {}, 'set': {}, 'trace': {}}
    for ln in open(tr_rows):
        q = ln.split()
        if not q or q[0].startswith('#'):
            continue
        if q[0] == 'SIZED':
            T['sized'][q[1]] = q[2]
        elif q[0] == 'SET':
            T['set'][q[1]] = None if q[2] == 'ABSENT' else kv(q[2:])
        elif q[0] == 'TRACE':
            T['trace'][(q[1], int(q[2][1:]))] = q[3] if len(q) == 4 else kv(q[3:])
    C = {'runs': {}, 'win': {}, 'log': [], 'markers': {}}
    for ln in open(cnt):
        q = ln.split()
        if not q or q[0].startswith('#'):
            continue
        if q[0] == 'LOG':
            C['log'].append(ln.strip())
        elif q[0] == 'MARKERS':
            C['markers'] = kv(q[1:])
        elif q[0] == 'RUN':
            C['runs'][(q[1], q[2], q[3])] = kv(q[4:])
        elif q[0] == 'WIN':
            key = (q[1], q[2], q[3], int(q[4][1:]))
            C['win'][key] = q[5] if len(q) <= 7 or q[5] != 'lo' else {a: int(b) for a, b in kv(q[5:]).items()}
    R = {'chain': [], 'run': {}}
    for ln in open(runr):
        q = ln.split()
        if not q or q[0].startswith('#'):
            continue
        if q[0] == 'CHAIN':
            R['chain'].append(q[3])
        elif q[0] == 'RUNLOG':
            R['run'][q[1]] = None if q[2] == 'ABSENT' else kv(q[2:])
    G = {}
    for ln in open(cfg):
        q = ln.split()
        if q and q[0] == 'G5CFG':
            G[(q[1], int(q[2]))] = None if q[3] == 'ABSENT' else kv(q[3:])
    return T, C, R, G


def read_percpu(path):
    g = {}
    for ln in open(path):
        q = ln.split()
        if q and not q[0].startswith('#'):
            g.setdefault(q[0], {})[int(q[1])] = tuple(int(x) for x in q[2:7])
    return g


def read_gem5_mix(path):
    rows = {}
    for ln in open(path):
        q = ln.split()
        if q and not q[0].startswith('#'):
            rows[q[0]] = dict(zip(('insts', 'LD', 'ST', 'RMW_Read', 'Locked_RMW_Read', 'Locked_RMW_Write', 'IFETCH'), map(int, q[1:])))
    return rows


def in_range(x, lo, hi, widen, absol=None):
    """x inside [lo, hi] widened by `widen` (a fraction of each end), or by `absol` per 1,000"""
    if lo * (1 - widen) <= x <= hi * (1 + widen):
        return True
    return absol is not None and lo - absol <= x <= hi + absol


def fmt_range(lo, hi):
    return f'[{lo:.3f}, {hi:.3f}]'


def check_program(p, s, T, C, R, G, percpu, gmix, g5rows, P, B, out):
    """returns (failed checks, notes); prints the program's block into out"""
    fails, notes = [], []
    say = out.append
    tids = s['tids']
    say(f'== {p} ({ROLE[s["role"]]}); traced threads {",".join(map(str, tids))}')
    # not yet made (not a failure): no trace set, no ChampSim run log, or no counter run at all
    pending = [why for cond, why in ((T['set'].get(p) is None, 'not traced yet'), (R['run'].get(p) is None, 'no ChampSim run log yet'),
                                     (not any(key[0] == p for key in C['runs']), 'no counter run yet')) if cond]

    # QB
    sz = T['sized'].get(p, 'no')
    ok = sz in ('yes', 'step4')
    say(f'   QB    {"holds" if ok else "FAILS"}: {"SIZED (written only after QB held)" if sz == "yes" else "step 4 sizing (CHOSEN; QB held then)" if sz == "step4" else "not sized"}')
    if not ok:
        fails.append('QB')

    # QT
    st = T['set'].get(p)
    why = []
    if not st:
        why.append('no trace set')
    else:
        if st.get('done') != s['tracer']:
            why.append(f'DONE {st.get("done")} is not the tracer {s["tracer"][:8]}')
        if st.get('cpuid') != CPUID_MD5:
            why.append(f'CPUID {st.get("cpuid")}')
        if st.get('failed', '-') != '-':
            why.append(f'FAILED {st.get("failed")}')
        if st.get('unbalanced', '0') != '0':
            why.append('unbalanced sync calls')
        if p == 'facesim' and st.get('start0') != 'opened':
            why.append(f"thread 0's window {st.get('start0')}")
        for t in tids:
            r = T['trace'].get((p, t))
            if not isinstance(r, dict):
                why.append(f't{t} {r or "MISSING"}')
            elif int(r['instr']) < MIN_TRACE:
                why.append(f't{t} {int(r["instr"]) / M:.1f} M instructions < 172.5 M')
            elif 'wrec' not in r:
                why.append(f't{t} does not reach record 150 M')
    if st:
        lens = ', '.join(f't{t} {int(T["trace"][(p, t)]["instr"]) / M:.1f} M' for t in tids if isinstance(T['trace'].get((p, t)), dict))
        say(f'   QT    {"holds" if not why else "FAILS: " + "; ".join(why)}: tracer {st.get("done", "-")[:8]}, CPUID {st.get("cpuid", "-")[:8]}, '
            f'length rule {"applied (LEN " + st["len"] + ")" if st.get("len", "-") != "-" else "not applied"}; instructions {lens}')
    else:
        say(f'   QT    FAILS: {"; ".join(why)}')
    if why:
        fails.append('QT')

    # Q3
    rr = R['run'].get(p)
    why = []
    tree = f'phaseA_b3_h2_{p}4'
    pr, br = P.get((tree, 'shared')), B.get((tree, 'shared'))
    if not R['chain'] or any(b != G6_BIN for b in R['chain']):
        why.append(f'chain binary {",".join(R["chain"]) or "unknown"}')
    if not rr:
        why.append('no run log')
    else:
        for cond, msg in ((rr['complete'] == '1', 'not complete'), (rr['deadlock'] == '0', f'SYNC DEADLOCK x{rr["deadlock"]}'),
                          (rr['eot'] == '0', f'end of trace x{rr["eot"]}'), (rr['unexplained'] == '0', f'unexplained {rr["unexplained"]}'),
                          (rr['raw'] == rr['bysilent'], f'raw {rr["raw"]} != by silent re-listing {rr["bysilent"]}'),
                          (rr['mutex_order'] == 'timing', f'mutex order {rr["mutex_order"]}'),
                          (rr['replay'].startswith('on'), f'sync replay {rr["replay"]}')):
            if not cond:
                why.append(msg)
        want = ','.join(f'{c}:sync_h2/{p}/raw{t}.champsimtrace.xz' for c, t in enumerate(tids))
        if rr['traces'] != want:
            why.append(f'traces {rr["traces"]} (want {want})')
    if not pr or not br:
        why.append('no rows')
    else:
        for cond, msg in ((pr['st'] == 'complete' and br['st'] == 'complete', 'rows incomplete'), (pr['ins'] == br['ins'], 'the rows files disagree'),
                          (br.get('selfcheck') == '0' and br.get('registered') == '12', f'self-check {br.get("selfcheck")} / registered {br.get("registered")}'),
                          (br.get('stale_holders') == '0', f'stale-holders {br.get("stale_holders")}'), (br.get('level') == '2', f'level {br.get("level")}'),
                          (pr['vm'] == 'ok' and pr['tw'] == 'ok', f'vm {pr["vm"]} tw {pr["tw"]}')):
            if not cond:
                why.append(msg)
    nh = rr.get('not_held', '-') if rr else '-'
    say(f'   Q3    {"holds" if not why else "FAILS: " + "; ".join(why)}' +
        (f' (view-order raw {rr["raw"]} = by silent re-listing {rr["bysilent"]}; releases of a mutex not held {nh}, reported)' if rr else ''))
    if why:
        fails.append('Q3')

    # QG
    why = []
    rows = {}
    for stop in (50, 150):
        g = G.get((p, stop))
        if not g:
            why.append(f'{stop} M: no configuration')
            continue
        want_stops = ','.join(f'{n}:{stop * M if n in s["stops"] else 0}' for n in range(s['ncpu']))
        for cond, msg in ((g['ended'] == 'max_insts', f'{stop} M ended {g["ended"]}'), (g['ncpu'] == str(s['ncpu']), f'{stop} M: {g["ncpu"]} CPUs, want {s["ncpu"]}'),
                          (g['exe'] == s['exe'], f'{stop} M: binary {g["exe"]}'), (g['l2'] == str(L2_BYTES), f'{stop} M: L2 {g["l2"]}'),
                          (g['randomization'] == 'false', f'{stop} M: randomization {g["randomization"]}'),
                          (g['stops'] == want_stops, f'{stop} M: stops {g["stops"]} (want {want_stops})')):
            if not cond:
                why.append(msg)
        rows[stop] = g5rows.get(g['run'])
        if rows[stop] is None:
            why.append(f'{stop} M: no gem5 row')
        elif rows[stop]['ended'] != 'max_insts':
            why.append(f'{stop} M: gem5 row ended {rows[stop]["ended"]}')
    ev = None
    if rows.get(50) and rows.get(150):
        d = {k: int(rows[150][k]) - int(rows[50][k]) for k in ('insts', 'ss_getx', 'mt_getx', 'ss_upgrade', 'getx_all', 'demand_acc', 'demand_hits')}
        if min(d.values()) < 0:
            why.append('a gem5 counter went backwards between the stops')
        else:
            ev = d['ss_getx'] + d['mt_getx']
    say(f'   QG    {"holds" if not why else "FAILS: " + "; ".join(why)}: {s["ncpu"]} CPUs, {s["exe"]}, L2 2 MB, randomization false, '
        f'stop on CPUs {",".join(map(str, s["stops"]))}')
    if why:
        fails.append('QG')

    # QW
    a, b = s['run'].format(50), s['run'].format(150)
    win = None
    if a in percpu and b in percpu and set(percpu[a]) == set(percpu[b]):
        win = {c: percpu[b][c][0] - percpu[a][c][0] for c in percpu[b]}
    if win is None or any(t not in win for t in tids):
        say('   QW    FAILS: gem5 per-CPU rows missing')
        fails.append('QW')
    else:
        trd = sum(win[t] for t in tids)
        unt = {c: v for c, v in win.items() if c not in tids}
        share = sum(unt.values()) / trd if trd else float('inf')
        ok = share < QW_MAX
        say(f'   QW    {"holds" if ok else "FAILS"}: untraced CPUs {",".join(map(str, sorted(unt))) or "none"} commit {share * 100:.3f}% of the traced CPUs\' '
            f'{trd / M:.1f} M window instructions (under 1% needed); per CPU ' + ' '.join(f'{c}:{win[c] / M:.2f}M' for c in sorted(win)))
        if not ok:
            fails.append('QW')

    # the counter runs: three under gem5's CPUID, one host (reported)
    def run_ok(mode, k):
        r = C['runs'].get((p, mode, k))
        why = []
        if not r:
            return ['no run']
        if r['exit'] != '0' or r['summary_exit'] != '0':
            why.append(f'exit {r["exit"]}/{r["summary_exit"]}')
        if r['counter'] != COUNTER_MD5:
            why.append(f'counter {r["counter"][:8]}')
        if mode == 'gem5' and (r['cpuid'] != CPUID_MD5 or not r['knobs_cpuid'].endswith('/sync_h2/gem5.cpuid')):
            why.append(f'cpuid {r["cpuid"][:8]} {r["knobs_cpuid"]}')
        if mode == 'host' and (r['cpuid'] != 'host' or r['knobs_cpuid'] != 'host'):
            why.append(f'cpuid {r["cpuid"]} {r["knobs_cpuid"]}')
        if (r['from'], r['to']) != (str(WIN[0]), str(WIN[1])):
            why.append(f'window {r["from"]}-{r["to"]}')
        if r['threads'] != ','.join(map(str, tids)):
            why.append(f'threads {r["threads"]}')
        if p == 'facesim':
            if not (r['knobs_base0'] == '1' and r['base0'].isdigit() and r['bcast0'] == '1' and r['start'] == 'start0:broadcast'):
                why.append(f'base0 {r["knobs_base0"]}/{r["base0"]}/{r["bcast0"]}/{r["start"]}')
        elif not (r['cut0'] == '0' and r['knobs_base0'] == '0' and r['start'] == '0' and r['skip'] == '0'):
            why.append(f'cut0 {r["cut0"]} base0 {r["knobs_base0"]} start {r["start"]} skip {r["skip"]}')
        for t in tids:
            w = C['win'].get((p, mode, k, t))
            if not isinstance(w, dict):
                why.append(f't{t} {w or "MISSING"}')
        return why
    gk = ('1', '2', '3')
    bad = {k: run_ok('gem5', k) for k in gk}
    nat_ok = not any(bad.values())
    for k in gk:
        if bad[k]:
            say(f'   counter gem5 {k}: NOT USABLE: {"; ".join(bad[k])}')
    hb = run_ok('host', '1')
    if hb:
        say(f'   counter host 1 (reported only): not usable: {"; ".join(hb)}')

    def summed(mode, k):
        return {f: sum(C['win'][(p, mode, k, t)][f] for t in tids) for f in FIELDS}

    # QC
    tw = [T['trace'].get((p, t)) for t in tids]
    if not nat_ok or not all(isinstance(x, dict) and 'wrec' in x for x in tw):
        say('   QC    FAILS: not checked (the three gem5-CPUID counter runs or the trace windows are not all usable)')
        fails.append('QC')
    else:
        tr = [sum(int(x[f]) for x in tw) for f in ('wrec', 'wld', 'wst', 'wrmw')]
        sums = [summed('gem5', k) for k in gk]
        cells, qbad = [], []
        for i, (name, f) in enumerate((('loads', 'ld'), ('stores', 'st'), ('RMWs', 'rmw')), start=1):
            x = 1000 * tr[i] / tr[0]
            rs = [1000 * q[f] / q['rec'] for q in sums]
            ok = in_range(x, min(rs), max(rs), QC_WIDEN, QC_RMW_ABS if f == 'rmw' else None)
            if not ok:
                qbad.append(name)
            cells.append(f'{name} {x:.3f} in {fmt_range(min(rs), max(rs))}{"" if ok else " <-- outside"}')
        hs = ''
        if not hb:
            h = summed('host', '1')
            hs = '; host run ' + ', '.join(f'{1000 * h[f] / h["rec"]:.3f}' for f in ('ld', 'st', 'rmw'))
        say(f'   QC    {"holds" if not qbad else "FAILS: " + ", ".join(qbad)}: per 1,000 records, the trace in the three gem5-CPUID runs\' range '
            f'(widened 1%; RMWs or 0.01): ' + '; '.join(cells) + hs)
        if qbad:
            fails.append('QC')

    # v2
    gw = None
    if a in gmix and b in gmix:
        gw = {key: gmix[b][key] - gmix[a][key] for key in gmix[b]}
    if not nat_ok or win is None or gw is None or any(t not in percpu[b] for t in tids):
        say('   v2    FAILS: not checked (counter runs, gem5 per-CPU rows or gem5_mix rows missing)')
        fails.append('v2')
    else:
        gpc = {t: tuple(y - x for x, y in zip(percpu[a][t], percpu[b][t])) for t in tids}
        gi = sum(gpc[t][0] for t in tids)
        g = (1000 * sum(gpc[t][1] + gpc[t][2] for t in tids) / gi, 1000 * sum(gpc[t][3] + gpc[t][4] for t in tids) / gi,
             1000 * (gw['RMW_Read'] + gw['Locked_RMW_Read']) / gw['insts'])
        sums = [summed('gem5', k) for k in gk]
        cr = [(1000 * q['gld'] / q['ginst'], 1000 * q['gst'] / q['ginst'], 1000 * q['rmw'] / q['ginst']) for q in sums]
        cells, vbad, soft = [], [], []
        for i, name in enumerate(('loads', 'stores', 'RMWs')):
            rs = [c[i] for c in cr]
            lo, hi = min(rs), max(rs)
            if name == 'RMWs':
                ok, sf = in_range(g[i], lo, hi, V2_WIDEN, V2_RMW_ABS), False
            else:
                ok = in_range(g[i], lo, hi, V2_WIDEN)
                sf = not ok and in_range(g[i], lo, hi, V2_SOFT)
            if sf:
                miss = (g[i] / hi - 1) if g[i] > hi else (g[i] / lo - 1)
                soft.append(f'{name} {miss * 100:+.1f}% from the range')
            elif not ok:
                vbad.append(name)
            cells.append(f'{name} {g[i]:.3f} in {fmt_range(lo, hi)}{"" if ok else " <-- 5-8% outside: scored, the miss stated" if sf else " <-- outside"}')
        say(f'   v2    {"FAILS: " + ", ".join(vbad) if vbad else "holds by the held-out rule (" + "; ".join(soft) + ")" if soft else "holds"}: per 1,000 instructions '
            f'(gem5 units), gem5 in the three counter runs\' range (widened 5%; RMWs or 0.05): ' + '; '.join(cells))
        w1 = {t: C['win'][(p, 'gem5', '1', t)] for t in tids}
        for t in tids:
            x, gg = w1[t], gpc[t]
            say(f'          t{t} (counter gem5 1 / gem5 CPU {t}, reported): loads {1000 * x["gld"] / x["ginst"]:.3f} / {1000 * (gg[1] + gg[2]) / gg[0] if gg[0] else float("nan"):.3f}, '
                f'stores {1000 * x["gst"] / x["ginst"]:.3f} / {1000 * (gg[3] + gg[4]) / gg[0] if gg[0] else float("nan"):.3f}; '
                f'instructions {x["ginst"] / M:.2f} M / {gg[0] / M:.2f} M')
        if vbad:
            fails.append('v2')
        notes += soft

    # 500 events
    if ev is None:
        say('   500   FAILS: no gem5 window')
        fails.append('500')
    else:
        ok = ev >= MIN_EVENTS
        say(f'   500   {"holds" if ok else "FAILS"}: gem5 counts {ev} store misses that find another core in the window (SS + MT L1_GETX; at least 500)')
        if not ok:
            fails.append('500')

    if pending:
        say(f'   -> PENDING: {"; ".join(pending)} (checked again once it exists)')
        return ['PENDING: ' + '; '.join(pending)], notes
    say(f'   -> {"SCORED" if not fails else "NOT SCORED: fails " + ", ".join(fails)}' + (f' (stated with the score: {"; ".join(notes)})' if notes and not fails else ''))
    return fails, notes


def check(paths, quiet=False):
    T, C, R, G = load_rows(paths)
    percpu, gmix = read_percpu(paths[4]), read_gem5_mix(paths[5])
    g5rows = b3_score.load(paths[6], b3_score.GEM5, lambda r: r['run'])
    P = b3_score.load(paths[7], b3_score.PHASEA, lambda r: (r['tree'], r['rg']))
    B = b3_score.load(paths[8], b3_score.B3, lambda r: (r['tree'], r['rg']))
    out = ['== Held-out set 2 and streamcluster: the checks (heldout2_design_2026-11-04.md, Note 8)']
    for ln in C['log']:
        out.append('   counter ' + ln)
    out.append(f'   counter markers: {C["markers"]}')
    verdict = {}
    for p, s in PROGRAMS.items():
        out.append('')
        verdict[p] = check_program(p, s, T, C, R, G, percpu, gmix, g5rows, P, B, out)
    out.append('')
    out.append('== Verdicts')
    for p, s in PROGRAMS.items():
        f, n = verdict[p]
        out.append(f'   {p:13s} {ROLE[s["role"]]:70s} {"SCORED" if not f else "pending" + f[0][7:] if f[0].startswith("PENDING") else "not scored (" + ", ".join(f) + ")"}')
    if not quiet:
        print('\n'.join(out))
    return verdict


def score(paths):
    verdict = check(paths)
    passing = [p for p in PROGRAMS if not verdict[p][0]]
    print('\n== The score, the programs that pass every check only (b3_score.py, h2@set2)')
    if not passing:
        print('   none passes every check: nothing is scored')
    else:
        b3_score.REFS['set2'] = {f'{p}4': b3_score.REFS['set2'][f'{p}4'] for p in passing}
        b3_score.score(paths[7], paths[8], paths[6], ['h2@set2'])
        for p in passing:
            if verdict[p][1]:
                print(f'   {p}: stated with its score (v2, the held-out rule): {"; ".join(verdict[p][1])}')
    counted = [p for p in PROGRAMS if PROGRAMS[p]['role'] == 'counted']
    met = [p for p in counted if p in passing]
    pend = [p for p in counted if verdict[p][0] and verdict[p][0][0].startswith('PENDING')]
    state = 'MET' if len(met) >= 2 else f'NOT YET DECIDED ({", ".join(pend)} pending)' if len(met) + len(pend) >= 2 else 'NOT MET'
    print(f'\n== The target (two counted programs that pass every check and discriminate): {len(met)} of {len(counted)} '
          f'({", ".join(met) or "none"}) -> {state}')
    print('   Agreement on them is P15 above; a P15 miss is stated beside it. ocean non-contiguous and streamcluster do not count toward it.')
    return 0


def main():
    a = sys.argv[1:]
    if len(a) == 4 and a[0] == 'tracerows':
        tracerows(*a[1:])
    elif len(a) == 2 and a[0] == 'countrows':
        countrows(a[1])
    elif len(a) == 3 and a[0] == 'runrows':
        runrows(a[1], a[2])
    elif len(a) == 2 and a[0] == 'gem5cfg':
        gem5cfg(a[1])
    elif len(a) == 10 and a[0] == 'check':
        check(a[1:])
    elif len(a) == 10 and a[0] == 'score':
        return score(a[1:])
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
