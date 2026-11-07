#!/usr/bin/env python3
"""Validation round, 2026-10-17, layers 1-2: did every run get the inputs and
settings its tree name says it got?

    scripts/verify_inputs.py COLLECT_DIR       (an unpacked audit: simulator/results/audit/collect_<time>/)

For every ChampSim run.log in COLLECT_DIR/logs/<tree>/regime_<rg>/<wl>_<n>core/<policy>/:
  - it completed, no trace wrapped, the page pool was never exhausted
  - core count, warm-up and simulation lengths, LLC sets, coherence level,
    invalidation latency: as the tree name implies (rules below)
  - the binary's fingerprint: the diagnosis counters only in d2 trees, the
    latency line only in c0 trees
  - the regime: shared runs alias pages; private runs alias nothing and count
    no sharing at all
  - the self-checks the coherence build prints: 0 mismatches, 3 x cores
    private caches registered, 0 stale holders
  - each CPU ran a different trace file (by real path), of the workload and
    thread count the tree name says, and every trace file is older than the
    run that read it
  - no two policies in one tree print identical results
Prints one line per problem, and a summary per tree.
"""
import collections
import datetime as dt
import os
import re
import sys

MB = 1024 * 1024


def tree_rules(tree, n):
    """-> dict of expectations for a run of `n` cores in `tree` (None = not checked)."""
    r = {'warmup': 50_000_000, 'sim': 100_000_000, 'sets': None, 'level': None, 'latency': 0, 'bounded': False}
    m = re.match(r'phaseA_b3_([a-z]+)(\d)?_?(.*)$', tree)
    if tree in ('phaseA', 'phaseA_armA', 'phaseA_armB', 'phaseA_v7arm', 'phaseA_v7equiv', 'phaseA_ocean4', 'phaseA_ocean4_armA',
                'phaseA_ocean4_armB'):
        r.update(sets=2048, level='absent-or-0')
    elif tree.startswith('phaseA_scaled') or tree.startswith('phaseA_ocean4_scaled'):
        r.update(sets=2048 * n, level='absent-or-0')
    elif tree == 'phaseA_l2_fixed':
        r.update(sets=2048, level=2)
    elif tree == 'phaseA_l2_scaled':
        r.update(sets=2048 * n, level=2)
    elif tree.startswith('phaseA_l2_a6_'):
        mb = int(re.match(r'phaseA_l2_a6_(\d+)mb', tree).group(1))
        r.update(sets=mb * MB // 1024, level=2)
    elif tree.startswith('phaseA_l2_c0_'):
        lat = int(re.match(r'phaseA_l2_c0_(\d+)c', tree).group(1))
        r.update(sets=2048, level=2, latency=lat)
    elif tree.startswith('phaseA_quick'):
        r.update(warmup=None, sim=None)
    elif m:
        kind, lv, rest = m.group(1), m.group(2), m.group(3)
        scaled = rest == 'scaled' or rest.endswith('_scaled')
        r['sets'] = 8192 if scaled else 2048
        if kind in ('v', 'ocean'):            # v2..v5, v4l0; phaseA_b3_ocean4 (v1)
            vm = re.match(r'phaseA_b3_v(\d)(l0)?_', tree)
            if vm:
                v, l0 = int(vm.group(1)), vm.group(2)
                r['level'] = 'absent-or-0' if v <= 3 or l0 else (1 if v == 4 else 2)
            else:
                r['level'] = 'absent-or-0'
        elif kind in ('x', 'h', 'e', 'd'):
            r['level'] = int(lv)
            r['bounded'] = kind == 'd'
        if 'barnesstd4' in tree:
            span = 'window' if rest.endswith('barnesstd4') else rest.split('_')[-1]
            r['warmup'], r['sim'] = {'start': (0, 37_900_000), 'force': (37_900_000, 50_000_000),
                                     'window': (37_900_000, 100_000_000)}[span]
    return r


def parse(path):
    d = {'complete': False, 'wrap': False, 'vmem': False, 'cpus': None, 'warmup': None, 'sim': None, 'sets': None,
         'level': None, 'latency': 0, 'bounded': False, 'traces': {}, 'aliased': None, 'roi': {}, 'priv': collections.Counter(),
         'cycles': [], 'simtime': None}
    roi = False
    with open(path, errors='replace') as fh:
        for line in fh:
            if line.startswith('Region of Interest Statistics'):
                roi = True
            if 'ChampSim completed all CPUs' in line:
                d['complete'] = True
            elif line.startswith('Reached end of trace'):
                d['wrap'] = True
            elif 'Out of physical memory' in line:
                d['vmem'] = True
            elif line.startswith('Number of CPUs:'):
                d['cpus'] = int(line.split()[-1])
            elif line.startswith('Warmup Instructions:'):
                d['warmup'] = int(line.split()[-1])
            elif line.startswith('Simulation Instructions:'):
                d['sim'] = int(line.split()[-1])
            elif line.startswith('PRIVATE-CACHE COHERENCE LEVEL:'):
                d['level'] = int(line.split()[-1])
            elif line.startswith('COHERENCE INVALIDATION LATENCY (CYCLES):'):
                d['latency'] = int(line.split()[-1])
            elif 'BOUNDED-PROTOCOL' in line:
                d['bounded'] = True
            elif line.startswith('VMEM ALIASED FILLS') and d['aliased'] is None:
                d['aliased'] = int(line.split()[-1])
            m = re.match(r'\[DEFAULT\] LLC: max_tag_bandwidth=\d+ \(derived from sets=(\d+)\)', line)
            if m:
                d['sets'] = int(m.group(1))
            m = re.match(r'CPU (\d+) runs (\S+)', line)
            if m:
                d['traces'][int(m.group(1))] = m.group(2)
            m = re.match(r'Simulation complete CPU (\d+) instructions: (\d+) cycles: (\d+).*?(?:Simulation time: (\d+) hr (\d+) min (\d+) sec)?', line)
            if m:
                d['cycles'].append(int(m.group(3)))
                if m.group(4):
                    d['simtime'] = int(m.group(4)) * 3600 + int(m.group(5)) * 60 + int(m.group(6))
            if roi:
                m = re.match(r'LLC COHERENCE ([A-Z0-9 \-]+?):\s+(\d+)\s*$', line)
                if m:
                    d['roi'][m.group(1)] = int(m.group(2))
                m = re.match(r'cpu\d+_(?:L1I|L1D|L2C) COHERENCE ([A-Z0-9 \-]+?):\s+(\d+)\s*$', line)
                if m:
                    d['priv'][m.group(1)] += int(m.group(2))
    return d


def trace_ok(wl, n, cpu, name):
    """Does trace `name` fit workload `wl` at `n` cores, for CPU `cpu`? (None = no rule)"""
    b = os.path.basename(name)
    if wl == 'canneal':
        return f'canneal_{n}t/' in name and re.match(rf'canneal{cpu + 1}\.champsimtrace', b) is not None
    if wl == 'barnes':
        return re.search(rf'(barnes_{n}t{cpu}|_t{cpu}|barnes{cpu}(_aligned)?)\.champsimtrace|t{cpu}[._]', b) is not None
    if wl in ('ocean', 'water'):
        return re.search(rf'{cpu}\.champsimtrace', b) is not None
    return None


def main():
    root = sys.argv[1]
    traces = {}
    for line in open(os.path.join(root, 'traces.txt')):
        p = line.split()
        traces[p[0]] = (p[1], p[3])
    problems = collections.Counter()
    per_tree = collections.defaultdict(lambda: [0, 0])
    results = collections.defaultdict(dict)
    logs = os.path.join(root, 'logs')
    for dirpath, _, files in sorted(os.walk(logs)):
        if 'run.log' not in files:
            continue
        rel = os.path.relpath(dirpath, logs)
        parts = rel.split(os.sep)
        if len(parts) != 4:
            print(f'ODD PATH {rel}')
            continue
        tree, rgd, wld, pol = parts
        rg = rgd.replace('regime_', '')
        m = re.match(r'(.+)_(\d+)core$', wld)
        wl, n = m.group(1), int(m.group(2))
        path = os.path.join(dirpath, 'run.log')
        d = parse(path)
        r = tree_rules(tree, n)
        bad = []
        if not d['complete']:
            bad.append('INCOMPLETE')
        if d['wrap']:
            bad.append('trace WRAPPED')
        if d['vmem']:
            bad.append('page pool EXHAUSTED')
        if d['cpus'] != n or len(d['traces']) != n:
            bad.append(f'cores: log {d["cpus"]}, traces {len(d["traces"])}, dir {n}')
        for k in ('warmup', 'sim'):
            if r[k] is not None and d[k] is not None and d[k] != r[k]:
                bad.append(f'{k} {d[k]:,} (expected {r[k]:,})')
        if r['sets'] and d['sets'] and d['sets'] != r['sets']:
            bad.append(f'LLC sets {d["sets"]} (expected {r["sets"]})')
        if r['level'] == 'absent-or-0':
            if d['level'] not in (None, 0):
                bad.append(f'level {d["level"]} (expected none or 0)')
        elif r['level'] is not None and d['level'] != r['level']:
            bad.append(f'level {d["level"]} (expected {r["level"]})')
        if d['latency'] != r['latency']:
            bad.append(f'latency {d["latency"]} (expected {r["latency"]})')
        if d['bounded'] != r['bounded']:
            bad.append(f'diagnosis counters {"present" if d["bounded"] else "absent"} (expected the other)')
        if d['complete']:
            if rg == 'shared' and not d['aliased']:
                bad.append('shared regime, but no aliased fills')
            if rg == 'private':
                if d['aliased']:
                    bad.append(f'private regime, but {d["aliased"]} aliased fills')
                shared_counts = {k: v for k, v in d['roi'].items() if v and ('OTHER' in k or 'BOUNDED' in k or k == 'INVALIDATIONS')}
                if shared_counts:
                    bad.append(f'private regime, but sharing counted: {shared_counts}')
            if d['level'] is not None:
                if d['roi'].get('DIR SELF-CHECK MISMATCHES', 0) or d['priv'].get('DIR SELF-CHECK MISMATCHES', 0):
                    bad.append('self-check mismatches')
                if d['roi'].get('DIR PRIVATE CACHES REGISTERED') not in (None, 3 * n):
                    bad.append(f'registered {d["roi"].get("DIR PRIVATE CACHES REGISTERED")} (expected {3 * n})')
                if d['roi'].get('DIR STALE-HOLDER VIOLATIONS', 0):
                    bad.append('stale-holder violations')
        reals = []
        start = None
        if d['simtime'] is not None:
            start = os.path.getmtime(path) - d['simtime']
        for cpu, t in sorted(d['traces'].items()):
            real, mtime = traces.get(t, ('MISSING', '-'))
            reals.append(real)
            if real == 'MISSING':
                bad.append(f'cpu{cpu} trace {t} not on disk now')
                continue
            ok = trace_ok(wl, n, cpu, t)
            if ok is False:
                bad.append(f'cpu{cpu} runs {t}')
            if start is not None and mtime != '-':
                tm = dt.datetime.strptime(mtime, '%Y-%m-%d_%H:%M:%S').timestamp()
                if tm > start + 60:
                    bad.append(f'cpu{cpu} trace {os.path.basename(t)} is NEWER than the run ({mtime})')
        present = [x for x in reals if x != 'MISSING']
        if len(set(present)) != len(present):
            bad.append('two CPUs ran the same trace file')
        if d['complete'] and d['cycles']:
            results[(tree, rg, wl, n)][pol] = tuple(d['cycles'])
        per_tree[tree][0] += 1
        if bad:
            per_tree[tree][1] += 1
            for b in bad:
                problems[(tree, re.sub(r'\d[\d,]*', '#', b))] += 1
            print(f'{rel}: ' + '; '.join(bad))
    for key, pols in results.items():
        seen = collections.defaultdict(list)
        for p, c in pols.items():
            seen[c].append(p)
        for c, ps in seen.items():
            if len(ps) > 1:
                print(f'{"/".join(map(str, key))}: IDENTICAL results for {", ".join(sorted(ps))}')
    print()
    print('tree                                   logs  with problems')
    for t, (a, b) in sorted(per_tree.items()):
        print(f'{t:38s} {a:5d}  {b:5d}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
