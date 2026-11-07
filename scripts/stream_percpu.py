#!/usr/bin/env python3
"""Per-thread stream comparison, gem5 side and trace side only (no ChampSim
result is read). For each gem5 CPU: the window between the 50 M and 150 M
stops; for the trace thread on that CPU, the same instructions (worker
threads start at record 0 when their CPU starts; thread 0 by its cut).

    scripts/stream_percpu.py fft lu raytrace streamcluster volrend

Reads simulator/results/gem5_b3/newbench/<prog>/... (stats.txt) and
simulator/results/newbench/traces/<prog>/ (anchor.txt, raw<i>[_aligned].mix).
Written 2026-11-01 for the step 4 diagnosis; its numbers are quoted in
bench/policy_sanity/stream_fix_design_2026-11-02.md ("What is known")."""
import re, sys, os
G = 'simulator/results/gem5_b3/newbench'
T = 'simulator/results/newbench/traces'
KEYS = ('numInsts', 'numOps', 'MemRead', 'FloatMemRead', 'MemWrite', 'FloatMemWrite')

def cpu_stats(path):
    out = {}
    for ln in open(path):
        m = re.match(r'system\.cpu(\d+)\.commitStats0\.(numInsts|numOps)\s+(\d+)', ln) or \
            re.match(r'system\.cpu(\d+)\.commitStats0\.committedInstType::(MemRead|FloatMemRead|MemWrite|FloatMemWrite)\s+(\d+)', ln)
        if m:
            out.setdefault(int(m.group(1)), {})[m.group(2)] = int(m.group(3))
    return out

def mix_at(path):
    at = {}
    for ln in open(path):
        p = ln.split()
        if p and p[0] == 'C':
            at[int(p[1])] = tuple(int(x) for x in p[2:5])
    return at

def near(at, x):   # the running count at the 100 K step nearest x
    k = int(round(x / 100000.0)) * 100000
    return at.get(k), k

for prog in sys.argv[1:]:
    a = cpu_stats(f'{G}/{prog}/l2_2MB_mi50M/{prog}_4c/stats.txt')
    b = cpu_stats(f'{G}/{prog}/l2_2MB_mi150M/{prog}_4c/stats.txt')
    cut = 0
    anc = f'{T}/{prog}/anchor.txt'
    if os.path.exists(anc):
        m = re.search(r'CUT (\d+)', open(anc).read()); cut = int(m.group(1)) if m else 0
    print(f'== {prog}   (per 1,000 instructions over each CPU\'s own window; trace = the same thread\'s records)')
    print(f'   cpu  gem5 window insts   trace records         loads: trace | gem5 Int+Float  Int+Float/2 | stores: trace | gem5 Int+Float  Int+Float/2   ops/inst')
    for c in sorted(b):
        d = {k: b[c].get(k, 0) - a.get(c, {}).get(k, 0) for k in KEYS}
        if d['numInsts'] < 1_000_000:
            print(f'   {c}    {d["numInsts"]:>12,}   (idle in the window)'); continue
        ki = d['numInsts'] / 1000.0
        mixes = sorted(f for f in os.listdir(f'{T}/{prog}') if f.endswith('.mix') and re.match(rf'raw{c}(_aligned)?\.mix$', f))
        tr = '   (no trace for this CPU)'
        if mixes:
            at = mix_at(f'{T}/{prog}/{mixes[0]}')
            off = cut if mixes[0].endswith('_aligned.mix') else 0
            lo, klo = near(at, a[c]['numInsts'] - off); hi, khi = near(at, b[c]['numInsts'] - off)
            if lo and hi:
                n = (khi - klo) / 1000.0
                tl, ts = (hi[0] - lo[0]) / n, (hi[1] - lo[1]) / n
                tr = f'{klo/1e6:7.1f}-{khi/1e6:7.1f} M   {tl:8.2f} |'
                tr2 = f'{ts:8.2f} |'
            else:
                tr = f'   (window {(a[c]["numInsts"]-off)/1e6:.1f}-{(b[c]["numInsts"]-off)/1e6:.1f} M outside the trace)'
        gl, gl2 = (d['MemRead'] + d['FloatMemRead']) / ki, (d['MemRead'] + d['FloatMemRead'] / 2) / ki
        gs, gs2 = (d['MemWrite'] + d['FloatMemWrite']) / ki, (d['MemWrite'] + d['FloatMemWrite'] / 2) / ki
        if tr.startswith('   ('):
            print(f'   {c}    {d["numInsts"]:>12,} {tr}   gem5 loads {gl:.2f} ({gl2:.2f})  stores {gs:.2f} ({gs2:.2f})')
        else:
            print(f'   {c}    {d["numInsts"]:>12,}   {tr}      {gl:8.2f}     {gl2:8.2f} | {tr2}      {gs:8.2f}     {gs2:8.2f}    {d["numOps"]/d["numInsts"]:.2f}')
