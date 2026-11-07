#!/usr/bin/env python3
"""Round 1 of bench/policy_sanity/disagree_diagnosis_design_2026-11-06.md
(and its amendment 1): T1 (untraced CPUs), T2 (contended locks), T3 (drift).

    python3 scripts/disagree_diag.py

Reads only pulled files: gem5's stats.txt / rows / mix, ChampSim's run logs
and rows, the replayed traces' .mix files, the set 2 counter rows. Prints
every number with its inputs.

  D    gem5 events that would have to go for R_g5 to reach 0.5:
       G - 2 * C * I_g / I_c   (D <= 0: already in the band)
  M_u  messages the untraced CPUs' L1s received from the L2 in the window
       (system.ruby.l1_cntrl<c>.requestFromL2.m_msg_count): an upper bound on
       the gem5 events in which an untraced CPU holds the line
  E    gem5's RMWs (RMW_Read + Locked_RMW_Read) in the window minus the
       native rate at gem5's window instructions
  S    gem5's system calls in the window (system.cpu0.workload.numSyscalls)
  W    ChampSim's cycles with dispatch held for a mutex / all cycles
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import b3_score as B  # noqa: E402

ROOT = os.path.dirname(HERE)
RES = os.path.join(ROOT, 'simulator/results')
G5 = os.path.join(RES, 'gem5_b3')
BP = os.path.join(ROOT, 'bench/policy_sanity')
PHASEA, B3ROWS = os.path.join(BP, 'phasea_rows_v27.txt'), os.path.join(BP, 'b3_rows_v18.txt')
G5ROWS, G5MIX = os.path.join(BP, 'gem5_b3_rows_v6.txt'), os.path.join(BP, 'gem5_mix_v6.txt')
COUNT, TMIX = os.path.join(BP, 'h2_count_rows_v1.txt'), os.path.join(BP, 'trace_mix_v5.txt')
MX = os.path.join(RES, 'sync_mx/traces')
H2LOG = os.path.join(RES, 'heldout2/logs')
G6LOG = os.path.join(RES, 'sync_g6/logs')
NBLOG = os.path.join(RES, 'newbench/logs')
M = 1_000_000

# (label, role, tree, gem5 pair, log root, native source, gem5 CPUs traced or None = by count)
#   native: ('counter', prog) | ('mix', dir, [files]) | ('tmix', prefix) | None (stream not established)
SPANS = [
    ('fluidanimate', 'fail', 'phaseA_b3_h2_fluidanimate4', B.REFS['set2']['fluidanimate4'], H2LOG, ('counter', 'fluidanimate'), (1, 2, 3, 4)),
    ('vips', 'fail', 'phaseA_b3_h2_vips4', B.REFS['set2']['vips4'], H2LOG, ('counter', 'vips'), (3, 4, 5, 6)),
    ('barnes std window', 'fail', 'phaseA_b3_g3_barnesstd4', B.REFS['std']['barnesstd4'], G6LOG,
     ('mix', 'barnesstd', ['raw0_aligned', 'raw1', 'raw2', 'raw3']), None),
    ('barnes-256', 'fail', 'phaseA_b3_g3_barnes4', B.REFS['leaf256']['barnes4'], G6LOG, ('mix', 'barnes256', ['raw0', 'raw1', 'raw2', 'raw3']), None),
    ('barnes std start', 'fail-noE', 'phaseA_b3_g3_barnesstd4_start', B.REFS['std']['barnesstd4_start'], G6LOG, None, None),
    ('bodytrack', 'reported', 'phaseA_b3_h2_bodytrack4', B.REFS['set2']['bodytrack4'], H2LOG, ('counter', 'bodytrack'), (1, 2, 3, 4)),
    ('barnes std force', 'agree', 'phaseA_b3_g3_barnesstd4_force', B.REFS['std']['barnesstd4_force'], G6LOG,
     ('mix', 'barnesstd', ['raw0_aligned', 'raw1', 'raw2', 'raw3']), None),
    ('ocean 2 MB', 'agree', 'phaseA_b3_g3_ocean4', B.REFS['']['ocean4'], G6LOG, ('mix', 'ocean4', ['raw0', 'raw1', 'raw2', 'raw3']), None),
    ('canneal 4c 2 MB', 'agree-ctl', 'phaseA_b3_g3_canneal4', B.REFS['']['canneal4'], G6LOG, ('mix', 'canneal4', ['raw1', 'raw2', 'raw3', 'raw4']), None),
    ('canneal 8c', 'agree-ctl', 'phaseA_b3_g3_canneal8', B.REFS['e8']['canneal8'], G6LOG,
     ('mix', 'canneal8', [f'raw{i}' for i in range(1, 9)]), None),
    ('radix', 'agree-ctl', 'phaseA_b3_g3_radix4', B.REFS['held']['radix4'], G6LOG, ('mix', 'radix', ['raw0', 'raw1', 'raw2', 'raw3']), None),
    ('lunc', 'agree', 'phaseA_b3_n2_lunc4', B.REFS['new']['lunc4'], NBLOG, ('tmix', 'lunc_4t_window_t'), None),
    ('ocean non-contiguous', 'agree', 'phaseA_b3_h2_oceannc4', B.REFS['set2']['oceannc4'], H2LOG, ('counter', 'oceannc'), (0, 1, 2, 3)),
]


def stats(run):
    """first value of every stat in the run's single dump"""
    s = {}
    for line in open(os.path.join(G5, run, 'stats.txt')):
        p = line.split()
        if len(p) >= 2 and p[0] not in s and re.fullmatch(r'-?[0-9.e+]+', p[1]):
            s[p[0]] = float(p[1])
    return s


def mixrows():
    out = {}
    for line in open(G5MIX):
        p = line.split()
        if p and not p[0].startswith('#'):
            out[p[0]] = dict(zip(('insts', 'LD', 'ST', 'RMW_Read', 'Locked_RMW_Read', 'Locked_RMW_Write', 'IFETCH'), map(int, p[1:8])))
    return out


def runlog(root, tree):
    for dp, _, fs in os.walk(os.path.join(root, tree)):
        if 'run.log' in fs and '/regime_shared/' in dp + '/':
            return os.path.join(dp, 'run.log')
    sys.exit(f'no shared-regime run log for {tree} under {root}')


def champsim_log(path):
    txt = open(path).read()
    warm = int(re.search(r'^Warmup Instructions: (\d+)', txt, re.M).group(1))
    sim = int(re.search(r'^Simulation Instructions: (\d+)', txt, re.M).group(1))
    stall = {int(c): (int(a), int(w)) for c, a, w in re.findall(r'^CPU (\d+) MUTEX ACQUIRES: (\d+) CYCLES WAITING FOR A MUTEX: (\d+)', txt, re.M)}
    wc = {int(c): int(y) for c, y in re.findall(r'^Warmup finished CPU (\d+) instructions: \d+ cycles: (\d+)', txt, re.M)}
    sc = {int(c): int(y) for c, y in re.findall(r'^Simulation finished CPU (\d+) instructions: \d+ cycles: (\d+)', txt, re.M)}
    cyc = sum(wc.get(c, 0) + sc.get(c, 0) for c in sc)
    return warm, sim, stall, cyc


def mix_window(path, a, b):
    at = {}
    for line in open(path):
        q = line.split()
        if q and q[0] == 'C':
            at[int(q[1])] = (int(q[2]), int(q[3]), int(q[4]))
    if a not in at or b not in at:
        sys.exit(f'{path}: no count at {a} or {b}')
    return b - a, at[b][2] - at[a][2]


def native_rate(src, warm, sim):
    """(RMWs per 1,000, how it was got)"""
    if src is None:
        return None, 'not computed (stream not established)'
    if src[0] == 'counter':
        runs = {}
        for line in open(COUNT):
            p = line.split()
            if len(p) > 10 and p[0] == 'WIN' and p[1] == src[1] and p[2] == 'gem5' and p[5] == 'lo':
                f = dict(zip(p[5::2], map(int, p[6::2])))   # lo X hi Y rec N ld N ...
                r = runs.setdefault(p[3], [0, 0])
                r[0] += f['rmw']
                r[1] += f['ginst']
        rates = {k: 1000.0 * v[0] / v[1] for k, v in runs.items()}
        if len(rates) != 3:
            sys.exit(f'{src[1]}: {len(rates)} gem5-CPUID counter runs, expected 3')
        hi = max(rates.values())
        return hi, 'counter, gem5-CPUID runs ' + ' / '.join(f'{rates[k]:.4f}' for k in sorted(rates)) + ' (the highest)'
    if src[0] == 'mix':
        n = r = 0
        for f in src[2]:
            dn, dr = mix_window(os.path.join(MX, src[1], f + '.mix'), warm, warm + sim)
            n, r = n + dn, r + dr
        return 1000.0 * r / n, f'replayed traces sync_mx/{src[1]}, records [{warm / M:g} M, {(warm + sim) / M:g} M), {r} RMWs in {n} records'
    if src[0] == 'tmix':
        n = r = 0
        for line in open(TMIX):
            m = re.match(rf'{src[1]}\d+ records (\d+) loads \d+ stores \d+ rmw (\d+)', line)
            if m:
                n, r = n + int(m.group(1)), r + int(m.group(2))
        return 1000.0 * r / n, f'trace_mix_v5 {src[1]}*, {r} RMWs in {n} records'


def drift(path):
    out = subprocess.run([sys.executable, os.path.join(HERE, 'heartbeat_drift.py'), path], capture_output=True, text=True).stdout
    m = re.search(r'median ([0-9.]+) M, max ([0-9.]+) M', out)
    return (float(m.group(1)), float(m.group(2))) if m else None


def main():
    P = B.load(PHASEA, B.PHASEA, lambda r: (r['tree'], r['rg']))
    C = B.load(B3ROWS, B.B3, lambda r: (r['tree'], r['rg']))
    G = B.load(G5ROWS, B.GEM5, lambda r: r['run'])
    MIXR = mixrows()
    res = {}
    print('== Round 1 (disagree_diagnosis_design_2026-11-06.md + amendment 1); pulled files only')
    for label, role, tree, (_, ga, gb), logroot, nsrc, traced in SPANS:
        c, p = C[(tree, 'shared')], P[(tree, 'shared')]
        if p['ins'] != c['ins'] or c['st'] != 'complete':
            sys.exit(f'{tree}: rows disagree or incomplete')
        w = B.window(G, ga, gb)
        Gev, Ig = w['ss_getx'] + w['mt_getx'], w['insts']
        Cev, Ic = int(c['rfo_g5']), int(c['ins'])
        rg5 = (Cev / Ic) / (Gev / Ig)
        D = Gev - 2.0 * Cev * Ig / Ic
        sb, sa = stats(gb), (stats(ga) if ga else None)
        ncpu = len(w['cpus'])
        log = runlog(logroot, tree)
        warm, sim, stall, cyc = champsim_log(log)
        ntr = len(stall) if stall else 4
        tr = traced if traced else (tuple(range(ncpu)) if ncpu == ntr else tuple(range(1, ncpu)) if ncpu == ntr + 1 else None)
        if tr is None:
            sys.exit(f'{label}: {ncpu} gem5 CPUs against {ntr} traces')
        untr = [x for x in range(ncpu) if x not in tr]
        msg = lambda s, x: s.get(f'system.ruby.l1_cntrl{x}.requestFromL2.m_msg_count', 0.0)
        Mu = sum(msg(sb, x) - (msg(sa, x) if sa else 0) for x in untr)
        Mcpu = {x: int(msg(sb, x) - (msg(sa, x) if sa else 0)) for x in range(ncpu)}
        sysc = sb.get('system.cpu0.workload.numSyscalls', float('nan')) - (sa.get('system.cpu0.workload.numSyscalls', 0) if sa else 0)
        mb, ma = MIXR[gb], (MIXR[ga] if ga else None)
        g_rmw = (mb['RMW_Read'] + mb['Locked_RMW_Read']) - ((ma['RMW_Read'] + ma['Locked_RMW_Read']) if ma else 0)
        g_ins = mb['insts'] - (ma['insts'] if ma else 0)
        g_rate = 1000.0 * g_rmw / g_ins
        nat, how = native_rate(nsrc, warm, sim)
        E = (g_rate - nat) * Ig / 1000.0 if nat is not None else None
        st_tot = sum(v[1] for v in stall.values())
        acq = sum(v[0] for v in stall.values())
        Wsh = st_tot / cyc if cyc else float('nan')
        dr = drift(log)
        cpb = [int(x) for x in G[gb]['cpus'].split(',')]
        g_spread = (max(cpb[x] for x in tr) - min(cpb[x] for x in tr)) / M
        res[label] = dict(role=role, D=D, G=Gev, Mu=Mu, E=E, S=sysc, W=st_tot, Wsh=Wsh, rg5=rg5)
        print(f'\n== {label} ({role}); ChampSim {tree} ({os.path.relpath(log, ROOT)}); gem5 {ga} -> {gb}')
        print(f'   G {Gev} events in I_g {Ig} instr; C {Cev} in I_c {Ic}; R_g5 {rg5:.3f}; D = {Gev} - 2*{Cev}*{Ig}/{Ic} = {D:.0f}')
        print(f'   T1  gem5 CPUs {ncpu}, traced {",".join(map(str, tr))}, untraced {",".join(map(str, untr)) or "none"}; '
              f'L2->L1 messages in the window by CPU {Mcpu}; M_u {Mu:.0f}' + (f' = {Mu / D:.2f} D' if D > 0 and untr else ''))
        print(f'   T2  gem5 RMWs {g_rmw} in {g_ins} instr = {g_rate:.4f}/KI; native {"-" if nat is None else f"{nat:.4f}/KI"} ({how})')
        print(f'       E {"-" if E is None else f"{E:.0f}"}' + (f' = {E / D:.2f} D' if E is not None and D > 0 else '') +
              (f' = {E / Gev:.3f} G' if E is not None else '') + f'; S (gem5 syscalls) {sysc:.0f}; '
              f'W {st_tot} cycles held for a mutex over {acq} acquires = {Wsh:.4%} of {cyc} cycles; per CPU {stall}')
        print(f'   T3  ChampSim cores apart (heartbeats): {"too few heartbeats" if dr is None else f"median {dr[0]:.2f} M, max {dr[1]:.2f} M"}; '
              f'gem5 traced CPUs at the {gb.split("/")[-2]} stop: {[round(cpb[x] / M, 2) for x in tr]} M, spread {g_spread:.2f} M')

    print('\n== The rules (design § 4)')
    fa = ['fluidanimate', 'barnes std window', 'barnes-256']
    a = all(res[k]['E'] is not None and res[k]['E'] >= res[k]['D'] for k in fa)
    b = all(res[k]['S'] > 0 and res[k]['W'] > 0 for k in fa)
    ctl = [k for k, v in res.items() if v['role'] == 'agree-ctl']
    cc = all(res[k]['E'] is not None and res[k]['E'] < 0.1 * res[k]['G'] for k in ctl)
    v = res['vips']
    d = v['E'] is not None and (v['E'] >= v['D'] or v['E'] + v['Mu'] >= v['D'])
    rej = sum(1 for k in fa if res[k]['E'] is not None and res[k]['E'] < 0.1 * res[k]['D']) >= 2
    for k in fa:
        print(f"   (a) {k}: E {res[k]['E']:.0f} {'>=' if res[k]['E'] >= res[k]['D'] else '<'} D {res[k]['D']:.0f}")
    print(f'   (a) E >= D on all three: {"yes" if a else "NO"}')
    print(f'   (b) S > 0 and W > 0 on all three: {"yes" if b else "NO"} ' + str({k: (round(res[k]['S']), res[k]['W']) for k in fa}))
    print(f'   (c) E < 0.1 G on {", ".join(ctl)}: {"yes" if cc else "NO"} ' + str({k: round(res[k]['E'] / res[k]['G'], 3) for k in ctl}))
    print(f"   (d) vips: E {v['E']:.0f}, M_u {v['Mu']:.0f}, D {v['D']:.0f}: {'yes' if d else 'NO'}")
    for k in ('fluidanimate', 'vips'):
        r = res[k]
        print(f"   T1 {k}: M_u {r['Mu']:.0f} against D {r['D']:.0f}: H-A " +
              ('can explain it' if r['Mu'] >= r['D'] else 'rejected (M_u < 0.1 D)' if r['Mu'] < 0.1 * r['D'] else 'cannot explain it alone'))
    verdict = 'SUPPORTED as the main cause' if (a and b and cc and d) else 'REJECTED as the main cause' if rej else 'PARTIAL'
    print(f'   H-C: {verdict}')


if __name__ == '__main__':
    main()
