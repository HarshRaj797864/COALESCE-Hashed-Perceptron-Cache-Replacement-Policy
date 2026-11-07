#!/usr/bin/env python3
"""Validation round, 2026-10-17: every B3 number recomputed from the raw files.

    scripts/verify_numbers.py LOGS_ROOT [GEM5_ROOT]

LOGS_ROOT  the ChampSim run logs as the server keeps them (the audit's logs/:
           <tree>/regime_<rg>/<wl>_<n>core/<policy>/run.log)
GEM5_ROOT  the gem5 runs (default simulator/results/gem5_b3)

Written for this round, from the definitions in the design documents, without
reusing b3_score.py, b3_rows.sh or run_phase_a.sh rows, so that an error in
those shows up here as a disagreement. For each comparison it prints the
recomputed value and the value the results documents state, and flags any
difference beyond rounding.

Definitions (b3v2_canneal_design_2026-10-06.md, b3_barnes_std_design_2026-10-13.md):
  ChampSim  counters from the Region of Interest block; instructions from the
            "Simulation complete CPU n instructions:" lines, summed over the
            cores (the counters cover the same whole phase)
  gem5      stats(stop B) - stats(stop A); instructions = committed
            instructions of the CPUs that run the traced threads
  R_b       protocol-view store misses that find another core, per 1,000
            instructions, over gem5's (SS + MT).L1_GETX per 1,000 instructions
  R_a       the same with the presence view
  U         upgrade events (summed over the private caches) over gem5's
            SS.L1_UPGRADE, per 1,000 instructions
  traffic   shared-cache LOAD + RFO accesses per KI over gem5's L2
            L1_GETS + L1_GETX per KI
  "count"   comparisons (barnes's start span) use counts, not rates
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_log(path):
    """Everything this script needs from one ChampSim run.log."""
    d = {'instr': 0, 'cycles': 0, 'cpus': 0, 'roi': {}, 'complete': False, 'level': None,
         'llc_acc': {}, 'priv': {}, 'wrapped': False, 'warmup': None, 'sim': None, 'traces': {}}
    roi = False
    with open(path, errors='replace') as fh:
        for line in fh:
            if line.startswith('Region of Interest Statistics'):
                roi = True
                continue
            m = re.match(r'Simulation complete CPU (\d+) instructions: (\d+) cycles: (\d+)', line)
            if m:
                d['instr'] += int(m.group(2))
                d['cycles'] = max(d['cycles'], int(m.group(3)))
                d['cpus'] += 1
                continue
            if line.startswith('ChampSim completed all CPUs'):
                d['complete'] = True
            elif line.startswith('Reached end of trace'):
                d['wrapped'] = True
            elif line.startswith('PRIVATE-CACHE COHERENCE LEVEL:'):
                d['level'] = int(line.split()[-1])
            elif line.startswith('Warmup Instructions:'):
                d['warmup'] = int(line.split()[-1])
            elif line.startswith('Simulation Instructions:'):
                d['sim'] = int(line.split()[-1])
            m = re.match(r'CPU (\d+) runs (\S+)', line)
            if m:
                d['traces'][int(m.group(1))] = m.group(2)
            if not roi:
                continue
            m = re.match(r'LLC COHERENCE ([A-Z0-9 \-]+?):\s+(\d+)\s*$', line)
            if m:
                d['roi'][m.group(1)] = int(m.group(2))
                continue
            m = re.match(r'(cpu\d+_(?:L1I|L1D|L2C)) COHERENCE ([A-Z0-9 \-]+?):\s+(\d+)\s*$', line)
            if m:
                d['priv'].setdefault(m.group(2), 0)
                d['priv'][m.group(2)] += int(m.group(3))
                continue
            m = re.match(r'cpu\d+->LLC (LOAD|RFO|WRITE|TRANSLATION|PREFETCH|TOTAL)\s+ACCESS:\s+(\d+)\s+HIT:\s+(\d+)', line)
            if m:
                a = d['llc_acc'].setdefault(m.group(1), [0, 0])
                a[0] += int(m.group(2))
                a[1] += int(m.group(3))
    return d


def parse_stats(path):
    s = {}
    with open(path, errors='replace') as fh:
        for line in fh:
            p = line.split()
            if len(p) >= 2 and p[0].startswith('system.') or (len(p) >= 2 and p[0] in ('simInsts',)):
                try:
                    s[p[0]] = float(p[1])
                except ValueError:
                    pass
    return s


def g5(stats, key):
    return stats.get('system.ruby.L2Cache_Controller.' + key, 0.0)


def g5_window(root, a, b, cpus):
    """gem5 counts between stop a (None = the program's start) and stop b."""
    sb = parse_stats(os.path.join(root, b, 'stats.txt'))
    sa = parse_stats(os.path.join(root, a, 'stats.txt')) if a else {}
    def diff(f):
        return f(sb) - (f(sa) if a else 0.0)
    def ins(s):
        return sum(s.get(f'system.cpu{c}.commitStats0.numInsts', 0.0) for c in cpus)
    return {
        'getx_others': diff(lambda s: g5(s, 'SS.L1_GETX') + g5(s, 'MT.L1_GETX')),
        'upgrade': diff(lambda s: g5(s, 'SS.L1_UPGRADE')),
        'demand': diff(lambda s: g5(s, 'L1_GETS') + g5(s, 'L1_GETX')),
        'instr': diff(ins),
        'cpu_instr': [diff(lambda s, c=c: s.get(f'system.cpu{c}.commitStats0.numInsts', 0.0)) for c in cpus],
    }


def ratio(c_n, c_i, g_n, g_i, by_count=False):
    if by_count:
        return c_n / g_n if g_n else float('nan')
    if not (c_i and g_i and g_n):
        return float('nan')
    return (c_n / c_i) / (g_n / g_i)


# name, ChampSim log (relative to LOGS_ROOT), gem5 dir A (None = start), gem5 dir B,
# gem5 CPUs that run the traced threads, by_count, and the values the documents state.
W4 = [0, 1, 2, 3]          # SPLASH programs: thread 0 works; gem5 runs one CPU per thread
C4 = [1, 2, 3, 4]          # canneal 4: cpu0 is the loader
C8 = list(range(1, 9))     # canneal 8
COMPARISONS = [
    # (b3v4_steps23_2026-10-12.md, level 2 = v5)
    ('ocean 4c 2MB L2', 'phaseA_b3_v5_ocean4/regime_shared/ocean_4core/lru/run.log',
     'l2_2MB_mi50M/ocean_4c', 'l2_2MB_mi150M/ocean_4c', W4, False, {'R_b': 0.986, 'U': 0.532, 'traffic': 0.89}),
    ('ocean 4c 8MB L2', 'phaseA_b3_v5_ocean4_scaled/regime_shared/ocean_4core/lru/run.log',
     'l2_8MB_mi50M/ocean_4c', 'l2_8MB_mi150M/ocean_4c', W4, False, {'R_b': 1.125, 'U': 0.213, 'traffic': 0.99}),
    ('canneal 4c 2MB L2', 'phaseA_b3_v5_canneal4/regime_shared/canneal_4core/lru/run.log',
     'canneal/l2_2MB_mi50M/canneal_4c', 'canneal/l2_2MB_mi150M/canneal_4c', C4, False, {'R_b': 1.263, 'traffic': 1.04}),
    ('canneal 4c 8MB L2', 'phaseA_b3_v5_canneal4_scaled/regime_shared/canneal_4core/lru/run.log',
     'canneal/l2_8MB_mi50M/canneal_4c', 'canneal/l2_8MB_mi150M/canneal_4c', C4, False, {'R_b': 1.142, 'traffic': 1.06}),
    ('ocean 4c 2MB L1', 'phaseA_b3_v4_ocean4/regime_shared/ocean_4core/lru/run.log',
     'l2_2MB_mi50M/ocean_4c', 'l2_2MB_mi150M/ocean_4c', W4, False, {'R_b': 1.263}),
    ('ocean 4c 8MB L1', 'phaseA_b3_v4_ocean4_scaled/regime_shared/ocean_4core/lru/run.log',
     'l2_8MB_mi50M/ocean_4c', 'l2_8MB_mi150M/ocean_4c', W4, False, {'R_b': 1.343}),
    ('canneal 4c 2MB L1', 'phaseA_b3_v4_canneal4/regime_shared/canneal_4core/lru/run.log',
     'canneal/l2_2MB_mi50M/canneal_4c', 'canneal/l2_2MB_mi150M/canneal_4c', C4, False, {'R_b': 1.269}),
    ('canneal 4c 8MB L1', 'phaseA_b3_v4_canneal4_scaled/regime_shared/canneal_4core/lru/run.log',
     'canneal/l2_8MB_mi50M/canneal_4c', 'canneal/l2_8MB_mi150M/canneal_4c', C4, False, {'R_b': 1.144}),
    # step 1 (v3) and v2, as the earlier documents state them
    ('ocean 4c 2MB step1', 'phaseA_b3_v3_ocean4/regime_shared/ocean_4core/lru/run.log',
     'l2_2MB_mi50M/ocean_4c', 'l2_2MB_mi150M/ocean_4c', W4, False, {'R_b': 1.263}),
    ('canneal 4c 2MB step1', 'phaseA_b3_v3_canneal4/regime_shared/canneal_4core/lru/run.log',
     'canneal/l2_2MB_mi50M/canneal_4c', 'canneal/l2_2MB_mi150M/canneal_4c', C4, False, {'R_b': 1.230}),
    ('canneal 4c 8MB step1', 'phaseA_b3_v3_canneal4_scaled/regime_shared/canneal_4core/lru/run.log',
     'canneal/l2_8MB_mi50M/canneal_4c', 'canneal/l2_8MB_mi150M/canneal_4c', C4, False, {'R_b': 1.109}),
    # (b3_barnes_results_2026-10-14.md)
    ('barnes std force L2', 'phaseA_b3_x2_barnesstd4_force/regime_shared/barnes_4core/lru/run.log',
     'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi100M/barnes_4c', W4, False, {'R_b': 0.689, 'traffic': 0.81}),
    ('barnes std start L2 (count)', 'phaseA_b3_x2_barnesstd4_start/regime_shared/barnes_4core/lru/run.log',
     None, 'barnes/l2_2MB_mi50M/barnes_4c', W4, True, {'R_b': 0.761, 'U': 0.713}),
    ('barnes std window L2', 'phaseA_b3_x2_barnesstd4/regime_shared/barnes_4core/lru/run.log',
     'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi150M/barnes_4c', W4, False, {'R_b': 0.492, 'U': 0.818, 'traffic': 0.70}),
    ('barnes std force L1', 'phaseA_b3_x1_barnesstd4_force/regime_shared/barnes_4core/lru/run.log',
     'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi100M/barnes_4c', W4, False, {'R_b': 0.551}),
    ('barnes std force L0', 'phaseA_b3_x0_barnesstd4_force/regime_shared/barnes_4core/lru/run.log',
     'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi100M/barnes_4c', W4, False, {'R_b': 0.401}),
    ('barnes256 L2', 'phaseA_b3_v5_barnes4/regime_shared/barnes_4core/lru/run.log',
     'barnes_leaf256/l2_2MB_mi50M/barnes_4c', 'barnes_leaf256/l2_2MB_mi150M/barnes_4c', W4, False,
     {'R_b': 0.634, 'U': 0.478, 'traffic': 0.44}),
    # (b3_heldout_results_2026-10-17.md)
    ('canneal 8c 2MB L2', 'phaseA_b3_e2_canneal8/regime_shared/canneal_8core/lru/run.log',
     'canneal8/l2_2MB_mi50M/canneal_8c', 'canneal8/l2_2MB_mi150M/canneal_8c', C8, False, {'R_b': 1.721, 'R_a': 1.54, 'traffic': 1.01}),
    ('radix 4c 2MB L2', 'phaseA_b3_h2_radix4/regime_shared/radix_4core/lru/run.log',
     'heldout/radix/l2_2MB_mi830M/radix_4c', 'heldout/radix/l2_2MB_mi930M/radix_4c', W4, False,
     {'R_b': 42.96, 'R_a': 0.876, 'traffic': 0.99}),
    ('waternsq 4c 2MB L2', 'phaseA_b3_h2_waternsq4/regime_shared/waternsq_4core/lru/run.log',
     'heldout/waternsq/l2_2MB_mi50M/waternsq_4c', 'heldout/waternsq/l2_2MB_mi150M/waternsq_4c', W4, False,
     {'R_b': 1.924, 'U': 0.953, 'traffic': 0.60}),
    ('fmm 4c 2MB L2 (not scored)', 'phaseA_b3_h2_fmm4/regime_shared/fmm_4core/lru/run.log',
     'heldout/fmm/l2_2MB_mi50M/fmm_4c', 'heldout/fmm/l2_2MB_mi150M/fmm_4c', W4, False, {'R_b': 1.409, 'U': 1.16}),
]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    logs = sys.argv[1]
    gem5 = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'simulator/results/gem5_b3')
    bad = 0
    print(f'{"comparison":30s} {"measure":8s} {"recomputed":>11s} {"stated":>8s}  ChampSim n / instr ; gem5 n / instr')
    for name, log, a, b, cpus, by_count, stated in COMPARISONS:
        lp = os.path.join(logs, log)
        if not os.path.exists(lp):
            print(f'{name:30s} NO LOG {log}')
            continue
        c = parse_log(lp)
        try:
            g = g5_window(gem5, a, b, cpus)
        except FileNotFoundError as e:
            print(f'{name:30s} NO GEM5 RUN ({e.filename})')
            continue
        flags = []
        if not c['complete']:
            flags.append('INCOMPLETE')
        if c['wrapped']:
            flags.append('WRAPPED')
        prot = c['roi'].get('DIR RFO PROTOCOL-OTHER EVENTS', 0)
        pres = c['roi'].get('DIR RFO PRESENCE-OTHER EVENTS', 0)
        upg = c['priv'].get('DIR UPGRADE EVENTS', 0)
        dem = sum(c['llc_acc'].get(k, [0, 0])[0] for k in ('LOAD', 'RFO'))
        vals = {
            'R_b': (ratio(prot, c['instr'], g['getx_others'], g['instr'], by_count), prot, g['getx_others']),
            'R_a': (ratio(pres, c['instr'], g['getx_others'], g['instr'], by_count), pres, g['getx_others']),
            'U': (ratio(upg, c['instr'], g['upgrade'], g['instr'], by_count), upg, g['upgrade']),
            'traffic': (ratio(dem, c['instr'], g['demand'], g['instr'], False), dem, g['demand']),
        }
        for k, (v, cn, gn) in vals.items():
            st = stated.get(k)
            mark = ''
            if st is not None:
                # documents round to 3 decimals (2 for some); allow half a unit in the last place, relative 0.6%
                tol = max(0.0006 * abs(st), 0.0051 if len(str(st).split('.')[-1]) <= 2 else 0.00051)
                if not (abs(v - st) <= tol):
                    mark = '  <-- DIFFERS'
                    bad += 1
            print(f'{name:30s} {k:8s} {v:11.4f} {("%.3f" % st) if st is not None else "-":>8s}  '
                  f'{cn:,} / {c["instr"]:,} ; {gn:,.0f} / {g["instr"]:,.0f}{mark}')
        print(f'{"":30s} level {c["level"]}  warmup {c["warmup"]} sim {c["sim"]}  cpus {c["cpus"]}  '
              f'gem5 per-CPU window instr {[round(x / 1e6, 2) for x in g["cpu_instr"]]} M  {" ".join(flags)}')
    print()
    print(f'{bad} stated value(s) differ from the recomputation')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
