#!/usr/bin/env python3
"""Score the B3 gem5 comparison from committed rows files, on the laptop.

  scripts/b3_score.py gem5-rows [DIR]  > bench/policy_sanity/gem5_b3_rows_vN.txt
      one row per gem5 run under DIR (default simulator/results/gem5_b3):
      run ended insts ss_getx mt_getx ss_upgrade getx_all demand_acc demand_hits cpu0,cpu1,...
  scripts/b3_score.py score PHASEA_ROWS B3_ROWS GEM5_ROWS [v2|v3 ...]
      the comparison for each ChampSim tree generation, window 50-150 M.
      GEN@leaf256 scores barnes against gem5's run of the 256-body-leaf
      BARNES, the program the barnes_4t traces hold. GEN@std (x0, x1, x2)
      scores the standard-barnes traces over their three spans
  scripts/b3_score.py same PHASEA_ROWS GEN_A GEN_B
      P0 of b3v3_rmw_design: the two generations' rows agree in every timing
      and traffic column, and in load+RFO sums
  scripts/b3_score.py identical PHASEA_ROWS B3_ROWS GEN_A GEN_B [shared|private]
      Q0 and Q1 of b3v4_coherent_private_design: GEN_A's rows equal GEN_B's
      in EVERY column both files held before B3 v4, and GEN_A's new counters
      read 0 unless its level allows them
  scripts/b3_score.py gate PHASEA_ROWS B3_ROWS GEM5_ROWS
      the rule that starts the A5 rerun (same document): exit 0 only if, at
      level 2 (v5), Q0, Q1 and Q2 hold and ocean and canneal are in the band
      at both sizes. Prints why. Runs on the server, unattended.

Every number in bench/policy_sanity/b3v2_*.md and b3v3_*.md comes from this
arithmetic. It first lived in throwaway scripts (lost 2026-10-09); this file
reproduces those documents' numbers exactly (tested when written).

DEFINITIONS
  window        gem5 stats(run stopped at 150 M) - stats(run stopped at 50 M)
  gem5 rate     (SS.L1_GETX + MT.L1_GETX) per 1,000 instructions over the window
  R_b, R_a, R_v1   ChampSim protocol-view / presence / LLC-mask events per KI
                over that gem5 rate. The ChampSim counters and the instruction
                total both cover the whole measured phase.
  traffic       ChampSim LLC (total - writeback) accesses per KI over gem5 L2
                demand accesses per KI
  store misses  ChampSim LLC RFO accesses per KI over gem5 L1_GETX, all states
  SPAN          every ChampSim quantity here covers the whole measured phase,
                to the last core's finish: the instruction total sums the
                "Simulation complete" lines, and CACHE::end_phase copies the
                cache counters whole. (Checked 2026-10-11 against a raw log;
                an earlier note here claimed a 0.7% bias in the traffic
                ratios, which was wrong.)
  RMW/KI        diagnostic only. In b3_rows_v5 and earlier the RMW column is
                the per-core Region of Interest count, 0.7% low on canneal;
                from v6 it is whole-simulation like everything else.
  B3 v4 (b3v4_coherent_private_design_2026-10-11.md), trees v4 (level 1),
  v5 (level 2) and v4l0 (level 0, the control):
  U             ChampSim upgrade events (protocol view) per KI over gem5 L2
                SS.L1_UPGRADE per KI, in the same window. Scored where gem5
                has at least 10,000 upgrades in the window.
"""
import re
import sys

PHASEA = 'tree pol wl cores rg st vm tw max_cyc min_cyc ins load_acc load_hit tot_acc tot_hit wr_acc wr_hit rfo_acc rfo_hit tr_acc tr_hit aliased inval'.split()
B3 = ('tree pol wl cores rg st ins rfo_ev rfo_sh wb_ev wb_inv pres_ev pres_co prot_ev prot_co registered selfcheck rmw'
      ' level up_ev up_co up_pres inval_copies stale_fills stale_holders rfo_bounded up_bounded'
      ' rfo_g5 rfo_g5_co up_g5 up_g5_co view_order').split()   # level..stale_holders: B3 v4, absent before b3_rows_v7; rfo_bounded, up_bounded: the bounded view (b3_bounded_design_2026-10-17.md), absent before b3_rows_v11; the last five: the gem5-rule view (b3_g5rule_design_2026-10-19.md)
B3_OLD = 18            # columns every b3_rows file has
B3_NEW = B3[B3_OLD + 1:]   # the B3 v4 counters, without the level
LEVEL_OF = {'v4': '1', 'v5': '2', 'v4l0': '0', 'x0': '0', 'x1': '1', 'x2': '2', 'h0': '0', 'h1': '1', 'h2': '2', 'e0': '0', 'e1': '1', 'e2': '2', 'd2': '2', 's2': '2', 'm2': '2', 'g2': '2', 'n2': '2'}   # the level each generation must have run at
BAND = (0.5, 2.0)
U_MIN_GEM5 = 10000     # gem5 upgrades in the window below which U is not scored
GEM5 = 'run ended insts ss_getx mt_getx ss_upgrade getx_all demand_acc demand_hits cpus'.split()

# ChampSim tree suffix -> (workload label, gem5 run stopped at 50 M, at 150 M)
PAIRS = {
    'ocean4': ('ocean 2 MB', 'l2_2MB_mi50M/ocean_4c', 'l2_2MB_mi150M/ocean_4c'),
    'ocean4_scaled': ('ocean 8 MB', 'l2_8MB_mi50M/ocean_4c', 'l2_8MB_mi150M/ocean_4c'),
    'canneal4': ('canneal 2 MB', 'canneal/l2_2MB_mi50M/canneal_4c', 'canneal/l2_2MB_mi150M/canneal_4c'),
    'canneal4_scaled': ('canneal 8 MB', 'canneal/l2_8MB_mi50M/canneal_4c', 'canneal/l2_8MB_mi150M/canneal_4c'),
    'barnes4': ('barnes 2 MB', 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi150M/barnes_4c'),
}
# The barnes_4t traces are of a BARNES built with 256-body leaves; the gem5
# runs above are the standard program (b3_barnes_stream_2026-10-12.md). A
# generation written GEN@leaf256 is scored against gem5's run of the traced
# program instead (b3_barnes256_design_2026-10-12.md).
# GEN@std: the standard barnes, traced on 2026-10-13 and aligned at the start
# of its parallel section (b3_barnes_std_design_2026-10-13.md), against the
# standard gem5 runs, over three spans. None as the first run = from the
# program's start. Trees phaseA_b3_x<level>_barnesstd4[_force|_start].
REFS = {
    '': PAIRS,
    'leaf256': {'barnes4': ('barnes-256 2MB', 'barnes_leaf256/l2_2MB_mi50M/barnes_4c', 'barnes_leaf256/l2_2MB_mi150M/barnes_4c')},
    'std': {
        'barnesstd4_start': ('bstd start', None, 'barnes/l2_2MB_mi50M/barnes_4c'),
        'barnesstd4_force': ('bstd force', 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi100M/barnes_4c'),
        'barnesstd4': ('bstd window', 'barnes/l2_2MB_mi50M/barnes_4c', 'barnes/l2_2MB_mi150M/barnes_4c'),
    },
}
# GEN@held: the held-out programs (b3_heldout_design_2026-10-14.md), traced
# and aligned like the standard barnes, against gem5 stopped when a WORKER
# reaches 50 M and 150 M. Trees phaseA_b3_h<level>_<prog>4.
REFS['held'] = {
    'radix4': ('radix 2 MB', 'heldout/radix/l2_2MB_mi830M/radix_4c', 'heldout/radix/l2_2MB_mi930M/radix_4c'),   # traces skip 780 M
    'waternsq4': ('waternsq 2 MB', 'heldout/waternsq/l2_2MB_mi50M/waternsq_4c', 'heldout/waternsq/l2_2MB_mi150M/waternsq_4c'),
    'fmm4': ('fmm 2 MB', 'heldout/fmm/l2_2MB_mi50M/fmm_4c', 'heldout/fmm/l2_2MB_mi150M/fmm_4c'),
}
# GEN@e8: canneal at 8 cores (b3_canneal8_design_2026-10-14.md), the
# canneal_8t traces (threads 1-8) against gem5 with 8 workers, stopped when a
# worker reaches 50 M and 150 M. Trees phaseA_b3_e<level>_canneal8.
REFS['e8'] = {'canneal8': ('canneal 8c 2MB', 'canneal8/l2_2MB_mi50M/canneal_8c', 'canneal8/l2_2MB_mi150M/canneal_8c')}
# GEN@new: step 4's new benchmarks (newbench_design_2026-10-19.md), traced
# with sync records and aligned at thread 0's last pthread_create, against
# gem5 stopped when a worker reaches 50 M and 150 M. Trees phaseA_b3_n2_<prog>4.
REFS['new'] = {f'{p}4': (f'{p} 2 MB', f'newbench/{p}/l2_2MB_mi50M/{p}_4c', f'newbench/{p}/l2_2MB_mi150M/{p}_4c')
               for p in ('fft', 'lu', 'raytrace', 'streamcluster', 'volrend', 'radiosity', 'lunc')}   # cholesky, waterspatial replaced (amendment 2026-10-20)
# GEN@set2: held-out set 2 (heldout2_design_2026-11-04.md, Note 8), traced
# under gem5's CPUID, against gem5 stopped when a traced worker reaches 50 M and
# 150 M (Note 3); and streamcluster scored by its procedure against step 4's
# gem5 runs (newbench_design_2026-10-19.md, amendment 3). Trees
# phaseA_b3_h2_<prog>4 (set 1's h2 trees are radix4, waternsq4, fmm4).
# scripts/heldout2_score.py score prints only the programs that pass every check.
REFS['set2'] = {f'{p}4': (f'{p} 2 MB', f'heldout2/{p}/l2_2MB_mi50M/{p}_4c', f'heldout2/{p}/l2_2MB_mi150M/{p}_4c')
                for p in ('fluidanimate', 'bodytrack', 'facesim', 'vips', 'oceannc')}
REFS['set2']['streamcluster4'] = ('streamcluster 2MB', 'newbench/streamcluster/l2_2MB_mi50M/streamcluster_4c', 'newbench/streamcluster/l2_2MB_mi150M/streamcluster_4c')
SET2_ROLE = {'oceannc4': 'ocean non-contiguous (reported apart, never counted)', 'streamcluster4': 'streamcluster (newbench amendment 3: a step 4 program)'}
HELD_MIN_EVENTS = 500   # below this many gem5 store misses that find another core, a held-out program does not discriminate
NOT_ONE_PROGRAM = {('', 'barnes4'): 'NOT ONE PROGRAM: these traces are of a 256-body-leaf build and this gem5 run is the standard one. Void. Score GEN@leaf256.'}


def gem5_rows(root):
    import glob
    import os
    for stats in sorted(glob.glob(f'{root}/**/stats.txt', recursive=True)):
        d = os.path.dirname(stats)
        if '.prev_' in os.path.relpath(d, root):
            continue   # a stopped run kept as <dir>.prev_<time> (heldout2_design Note 3): never read
        s = {}
        dumps = 0
        for line in open(stats):
            if 'Begin Simulation Statistics' in line:
                dumps += 1
            p = line.split()
            if len(p) >= 2 and re.fullmatch(r'-?[0-9.e+]+', p[1]) and p[0] not in s:
                s[p[0]] = float(p[1])
        if dumps != 1:
            sys.exit(f'{stats}: {dumps} statistics dumps, expected 1')
        log = open(f'{d}/run.log').read() if os.path.exists(f'{d}/run.log') else ''
        m = re.search(r'Exiting @ tick \d+ because (.*)', log)
        ended = 'max_insts' if m and 'max instruction count' in m.group(1) else ('program_end' if m else 'NOT_ENDED')
        cpus = sorted((k for k in s if re.fullmatch(r'system\.cpu\d+\.commitStats0\.numInsts', k)), key=lambda k: int(re.search(r'cpu(\d+)', k).group(1)))
        if sum(s[k] for k in cpus) != s['simInsts']:
            sys.exit(f'{stats}: per-cpu instructions do not sum to simInsts')
        getx_all = sum(v for k, v in s.items() if re.fullmatch(r'system\.ruby\.L2Cache_Controller\.[A-Za-z_]+\.L1_GETX', k))
        c = 'system.ruby.L2Cache_Controller.'
        print(os.path.relpath(d, root), ended, int(s['simInsts']), int(s.get(c + 'SS.L1_GETX', 0)), int(s.get(c + 'MT.L1_GETX', 0)),
              int(s.get(c + 'SS.L1_UPGRADE', 0)), int(getx_all), int(s['system.ruby.l2_cntrl0.L2cache.m_demand_accesses']),
              int(s['system.ruby.l2_cntrl0.L2cache.m_demand_hits']), ','.join(str(int(s[k])) for k in cpus))


def load(path, cols, key):
    out = {}
    for line in open(path):
        p = line.split()
        if not p or p[0].startswith('#'):
            continue
        row = dict(zip(cols, p))
        out[key(row)] = row
    return out


def window(g, a, b):
    if (a is not None and a not in g) or b not in g:
        return None
    B = g[b]
    A = g[a] if a is not None else dict({k: '0' for k in GEM5[2:9]}, ended='max_insts', run='(start)', cpus=','.join('0' for _ in B['cpus'].split(',')))
    for r in (A, B):
        if r['ended'] != 'max_insts':
            sys.exit(f"gem5 run {r['run']} ended as {r['ended']}, not at its instruction stop")
    d = {k: int(B[k]) - int(A[k]) for k in GEM5[2:9]}
    if min(d.values()) < 0:
        sys.exit(f'a gem5 counter went backwards between {a} and {b}: the runs diverged')
    d['cpus'] = [int(y) - int(x) for x, y in zip(A['cpus'].split(','), B['cpus'].split(','))]
    return d


def score(phasea, b3, gem5, gens):
    P = load(phasea, PHASEA, lambda r: (r['tree'], r['rg']))
    C = load(b3, B3, lambda r: (r['tree'], r['rg']))
    G = load(gem5, GEM5, lambda r: r['run'])
    for spec in gens:
        gen, _, ref = spec.partition('@')
        if ref not in REFS:
            sys.exit(f'unknown reference @{ref}')
        print(f'== ChampSim trees phaseA_b3_{gen}_*  vs gem5{" (" + ref + ")" if ref else ""}, {"three spans" if ref == "std" else "window 50-150 M"}, per 1,000 instructions')
        print(f"   {'':13s} {'gem5':>8s} {'protocol':>9s} {'R_b':>6s} {'R_a':>6s} {'R_v1':>6s} | {'traffic':>7s} {'store-miss':>10s} {'RMW/KI':>7s} | checks")
        for suf, (label, ga, gb) in REFS[ref].items():
            tree = f'phaseA_b3_{gen}_{suf}'
            if (tree, 'shared') not in P or (tree, 'shared') not in C:
                continue
            w = window(G, ga, gb)
            if w is None:
                print(f'   {label:13s} no gem5 pair')
                continue
            p, c, cp = P[(tree, 'shared')], C[(tree, 'shared')], C.get((tree, 'private'))
            ins = float(c['ins'])
            if p['ins'] != c['ins'] or p['st'] != 'complete' or c['st'] != 'complete':
                sys.exit(f'{tree}: the two rows files disagree, or a run is incomplete')
            ki = lambda x: 1000.0 * float(x) / ins
            g = 1000.0 * (w['ss_getx'] + w['mt_getx']) / w['insts']
            traffic = ki(float(p['tot_acc']) - float(p['wr_acc'])) / (1000.0 * w['demand_acc'] / w['insts'])
            smiss = ki(p['rfo_acc']) / (1000.0 * w['getx_all'] / w['insts'])
            checks = []
            ncores = int(p['cores'])   # 3 private caches a core (12 at 4 cores, 24 at 8)
            checks.append('self-check ' + ('0' if c['selfcheck'] == '0' and c['registered'] == str(3 * ncores) else f"FAIL({c['selfcheck']},{c['registered']})"))
            if cp:
                checks.append('private ' + ('0' if cp['pres_ev'] == '0' and cp['prot_ev'] == '0' and cp['rfo_ev'] == '0' else 'NONZERO'))
            rmw = f"{ki(c['rmw']):7.2f}" if c.get('rmw', '-') != '-' else '      -'
            # a ratio over gem5's rate; "-" when gem5 counts none (2026-11-01:
            # a step 4 program with 0 such events crashed the whole score)
            over_g = lambda x: f'{ki(x) / g:6.3f}' if g else '     -'
            print(f"   {label:13s} {g:8.4f} {ki(c['prot_ev']):9.4f} {over_g(c['prot_ev'])} {over_g(c['pres_ev'])} {over_g(c['rfo_ev'])} |"
                  f" {traffic:7.2f} {smiss:10.4f} {rmw} | {'; '.join(checks)}")
            print(f"   {'':13s} gem5 events {w['ss_getx'] + w['mt_getx']} (MT {w['mt_getx']}, upgrades {w['ss_upgrade']}), GETX all {w['getx_all']}, window {w['insts']} instr, per cpu {w['cpus']};"
                  f" ChampSim protocol {c['prot_ev']}, LLC RFO {p['rfo_acc']}, {int(ins)} instr")
            if c.get('level', '-') != '-':
                gu = 1000.0 * w['ss_upgrade'] / w['insts']
                u = f"U = {ki(c['up_ev']) / gu:.3f}" if w['ss_upgrade'] >= U_MIN_GEM5 else f"U not scored (gem5 has {w['ss_upgrade']})"
                lv = c['level'] + ('' if LEVEL_OF.get(gen, c['level']) == c['level'] else f" -- EXPECTED {LEVEL_OF[gen]}")
                print(f"   {'':13s} level {lv}; upgrades {c['up_ev']} ({ki(c['up_ev']):.4f}/KI; gem5 {gu:.4f}/KI; {u}), by presence {c['up_pres']};"
                      f" copies invalidated {c['inval_copies']} ({ki(c['inval_copies']):.4f}/KI); stale fills {c['stale_fills']}; stale-holders {c['stale_holders']}")
                if ref == 'std':
                    # Counts over the same stretch of the program. For the
                    # start span this is the measure: gem5's instructions
                    # there include thread 0's serial start, which the aligned
                    # traces leave out, so its rates per instruction read low.
                    ge = w['ss_getx'] + w['mt_getx']
                    print(f"   {'':13s} by count: protocol events {c['prot_ev']} / gem5 {ge} = {int(c['prot_ev']) / ge if ge else float('nan'):.3f};"
                          f" upgrades {c['up_ev']} / gem5 {w['ss_upgrade']} = {int(c['up_ev']) / w['ss_upgrade'] if w['ss_upgrade'] else float('nan'):.3f};"
                          f" instructions {int(ins)} / gem5 {w['insts']} = {ins / w['insts']:.3f}")
                if ref:
                    gh = w['ss_getx'] + w['mt_getx'] + w['ss_upgrade']
                    ch = int(c['prot_ev']) + int(c['up_ev'])
                    gd = 1000.0 * w['demand_acc'] / w['insts']
                    cd = ki(float(p['tot_acc']) - float(p['wr_acc']))
                    print(f"   {'':13s} hand-overs: ChampSim {ch} ({ki(ch):.4f}/KI), gem5 {gh} ({1000.0 * gh / w['insts']:.4f}/KI), ratio {ki(ch) / (1000.0 * gh / w['insts']) if gh else float('nan'):.3f};"
                          f" demand accesses {cd:.4f} against {gd:.4f}/KI; with ChampSim's upgrades added {cd + ki(c['up_ev']):.4f}, ratio {(cd + ki(c['up_ev'])) / gd:.3f}")
            if c.get('rfo_bounded', '-') not in ('-', None):
                # the bounded view (b3_bounded_design_2026-10-17.md): it forgets
                # a line's cores once the line is held nowhere on chip
                gu = 1000.0 * w['ss_upgrade'] / w['insts']
                ub = f"U_bounded = {ki(c['up_bounded']) / gu:.3f}" if w['ss_upgrade'] >= U_MIN_GEM5 else f"U_bounded not scored (gem5 has {w['ss_upgrade']})"
                rbd = ki(c['rfo_bounded']) / g if g else float('nan')
                print(f"   {'':13s} bounded view: R_bounded {rbd:.3f} ({c['rfo_bounded']} events, protocol {c['prot_ev']}; subset {'yes' if int(c['rfo_bounded']) <= int(c['prot_ev']) else 'NO'}); bounded upgrades {c['up_bounded']} ({ub})"
                      f" -- {'in the band' if BAND[0] <= rbd <= BAND[1] else 'OUT OF THE BAND'}")
            if c.get('rfo_g5', '-') not in ('-', None):
                # the gem5-rule view (b3_g5rule_design_2026-10-19.md): an exclusive
                # holder forgotten when its private caches drop the line, shared
                # readers when the line leaves the chip
                gu = 1000.0 * w['ss_upgrade'] / w['insts']
                ug = f"U_g5 = {ki(c['up_g5']) / gu:.3f}" if w['ss_upgrade'] >= U_MIN_GEM5 else f"U_g5 not scored (gem5 has {w['ss_upgrade']})"
                rg5 = ki(c['rfo_g5']) / g if g else float('nan')
                sub = int(c['rfo_g5']) <= int(c['rfo_bounded']) if c.get('rfo_bounded', '-') not in ('-', None) else True
                print(f"   {'':13s} gem5-rule view: R_g5 {rg5:.3f} ({c['rfo_g5']} events, {c['rfo_g5_co']} cores; at most the bounded view's: {'yes' if sub else 'NO'};"
                      f" view-order violations {c['view_order']}); its upgrades {c['up_g5']} ({ug})"
                      f" -- {'in the band' if BAND[0] <= rg5 <= BAND[1] else 'OUT OF THE BAND'}")
            if (ref, suf) in NOT_ONE_PROGRAM:
                print(f"   {'':13s} ^ {NOT_ONE_PROGRAM[(ref, suf)]}")
            if ref == 'held':
                ge = w['ss_getx'] + w['mt_getx']
                rb = ki(c['prot_ev']) / g if g else float('nan')
                if ge < HELD_MIN_EVENTS:
                    verdict = f'not discriminating: gem5 counts {ge} store misses that find another core (fewer than {HELD_MIN_EVENTS})'
                else:
                    verdict = f'R_b {rb:.3f} ' + ('in the band' if BAND[0] <= rb <= BAND[1] else 'OUT OF THE BAND')
                print(f"   {'':13s} held-out P1, level {c.get('level', '-')}: {verdict}")
            if ref in ('new', 'set2'):
                # newbench_design_2026-10-19.md: P8 R_g5 in the band, P9 R_b >= R_g5,
                # P10 demand traffic within the band, for each discriminating program.
                # Held-out set 2 (heldout2_design_2026-11-04.md): the same three as
                # P15-P17; streamcluster keeps P8-P10 (newbench amendment 3).
                ge = w['ss_getx'] + w['mt_getx']
                what = 'new benchmark' if ref == 'new' else SET2_ROLE.get(suf, 'held-out set 2')
                pn = ('P15', 'P16', 'P17') if ref == 'set2' and suf != 'streamcluster4' else ('P8', 'P9', 'P10')
                if ge < HELD_MIN_EVENTS:
                    print(f"   {'':13s} {what}: not discriminating: gem5 counts {ge} store misses that find another core (fewer than {HELD_MIN_EVENTS})")
                elif c.get('rfo_g5', '-') in ('-', None):
                    print(f"   {'':13s} {what}: NO GEM5-RULE COUNTERS -- not the final tool's binary")
                else:
                    rb = ki(c['prot_ev']) / g if g else float('nan')
                    rg5 = ki(c['rfo_g5']) / g if g else float('nan')
                    gd = 1000.0 * w['demand_acc'] / w['insts']
                    tr = ki(float(p['tot_acc']) - float(p['wr_acc'])) / gd if gd else float('nan')
                    inb = lambda x: BAND[0] <= x <= BAND[1]
                    print(f"   {'':13s} {what}: {pn[0]} R_g5 {rg5:.3f} {'holds' if inb(rg5) else 'FAILS'};"
                          f" {pn[1]} R_b {rb:.3f} >= R_g5: {'holds' if rb >= rg5 else 'FAILS'};"
                          f" {pn[2]} traffic {tr:.3f} {'holds' if inb(tr) else 'FAILS'}  ({ge} gem5 events)")


def same(phasea, ga, gb):
    P = load(phasea, PHASEA, lambda r: (r['tree'], r['rg']))
    cols = ['max_cyc', 'min_cyc', 'ins', 'tot_acc', 'tot_hit', 'wr_acc', 'wr_hit', 'tr_acc', 'tr_hit', 'aliased', 'inval']
    bad = n = 0
    for suf in PAIRS:
        for rg in ('shared', 'private'):
            a, b = P.get((f'phaseA_b3_{ga}_{suf}', rg)), P.get((f'phaseA_b3_{gb}_{suf}', rg))
            if not a or not b:
                continue
            n += 1
            diff = [c for c in cols if a[c] != b[c]]
            for x, y in (('load_acc', 'rfo_acc'), ('load_hit', 'rfo_hit')):
                if int(a[x]) + int(a[y]) != int(b[x]) + int(b[y]):
                    diff.append(f'{x}+{y}')
            bad += bool(diff)
            print(f"   {suf:16s} {rg:7s} {'identical' if not diff else 'DIFFERS: ' + ' '.join(diff)}   LLC RFO {a['rfo_acc']:>8s} -> {b['rfo_acc']:>8s}")
    print(f'== {n} configurations, {bad} differ ==')
    return 1 if bad or not n else 0


def identical(phasea, b3, ga, gb, regimes=('shared', 'private'), quiet=False):
    """GEN_A's rows against GEN_B's, every column the files held before B3 v4."""
    P = load(phasea, PHASEA, lambda r: (r['tree'], r['rg']))
    C = load(b3, B3, lambda r: (r['tree'], r['rg']))
    bad = n = 0
    out = []
    # every tree suffix any reference names; a suffix GEN_A has no row for is skipped
    for suf in list(PAIRS) + [x for ref in REFS.values() for x in ref if x not in PAIRS]:
        for rg in regimes:
            ka, kb = (f'phaseA_b3_{ga}_{suf}', rg), (f'phaseA_b3_{gb}_{suf}', rg)
            if ka not in P or ka not in C:
                continue
            n += 1
            if kb not in P or kb not in C:
                bad += 1
                out.append(f"   {suf:16s} {rg:7s} NO {gb} ROW to compare with")
                continue
            diff = [k for k in PHASEA[1:] if P[ka][k] != P[kb][k]] + [k for k in B3[1:B3_OLD] if C[ka].get(k) != C[kb].get(k)]
            # the new counters: all 0 where nothing may fire (level 0, or the private regime)
            if C[ka].get('level') == '0' or rg == 'private':
                diff += [f'{k}={C[ka].get(k)}' for k in B3_NEW if C[ka].get(k) not in ('0', '-', None)]   # '-': a counter that binary never printed
            bad += bool(diff)
            out.append(f"   {suf:16s} {rg:7s} {'identical' if not diff else 'DIFFERS: ' + ' '.join(diff)}")
    if not quiet:
        print('\n'.join(out))
        print(f'== {ga} against {gb}, {"/".join(regimes)}: {n} rows, {bad} differ ==')
    return n, bad, out


def gate(phasea, b3, gem5):
    """The pre-registered rule that starts the A5 rerun. Exit 0 = start it."""
    P = load(phasea, PHASEA, lambda r: (r['tree'], r['rg']))
    C = load(b3, B3, lambda r: (r['tree'], r['rg']))
    G = load(gem5, GEM5, lambda r: r['run'])
    why = []

    # Q2, and that every expected row exists, at the level it should have run at
    expect = {'v4': list(PAIRS), 'v5': list(PAIRS), 'v4l0': ['canneal4', 'barnes4']}
    for gen, sufs in expect.items():
        for suf in sufs:
            for rg in ('shared', 'private'):
                k = (f'phaseA_b3_{gen}_{suf}', rg)
                if k not in P or k not in C:
                    why.append(f'Q2: no row for {k[0]} {rg}')
                    continue
                p, c = P[k], C[k]
                t = sum(int(p[x]) for x in ('load_acc', 'wr_acc', 'rfo_acc', 'tr_acc'))
                for cond, msg in ((p['st'] == 'complete' and c['st'] == 'complete', 'incomplete'), (p['vm'] == 'ok', 'page pool exhausted'),
                                  (p['tw'] == 'ok', 'a trace wrapped'), (p['max_cyc'] == p['min_cyc'], 'min != max cycles'),
                                  (t == int(p['tot_acc']), 'TOTAL identity fails'), (c.get('selfcheck') == '0', f"self-check {c.get('selfcheck')}"),
                                  (c.get('registered') == '12', f"registered {c.get('registered')}"),
                                  (c.get('stale_holders') == '0', f"stale-holders {c.get('stale_holders')}"),
                                  (c.get('level') == LEVEL_OF[gen], f"level {c.get('level')}, expected {LEVEL_OF[gen]}"),
                                  ((p['aliased'] != '0') == (rg == 'shared'), f"aliased fills {p['aliased']} in the {rg} regime")):
                    if not cond:
                        why.append(f'Q2: {k[0]} {rg}: {msg}')
    # Q0: level 0 is the step-1 simulator.  Q1: the private regime is untouched.
    for name, ga, regs in (('Q0', 'v4l0', ('shared', 'private')), ('Q1', 'v4', ('private',)), ('Q1', 'v5', ('private',))):
        n, bad, out = identical(phasea, b3, ga, 'v3', regs, quiet=True)
        print(f'{name}: {ga} against v3, {"/".join(regs)}: {n} rows, {bad} differ')
        if bad or n != len(expect[ga]) * len(regs):
            why.append(f'{name}: {ga} against v3: {bad} of {n} rows differ (expected {len(expect[ga]) * len(regs)} rows)')
            print('\n'.join(o for o in out if 'identical' not in o))
    # ocean and canneal in the band at level 2, both sizes. barnes is reported, not gating.
    for suf, (label, ga, gb) in PAIRS.items():
        k = ('phaseA_b3_v5_' + suf, 'shared')
        w = window(G, ga, gb)
        if k not in C or w is None:
            why.append(f'R_b: nothing to score for {label}')
            continue
        r = (1000.0 * float(C[k]['prot_ev']) / float(C[k]['ins'])) / (1000.0 * (w['ss_getx'] + w['mt_getx']) / w['insts'])
        inband = BAND[0] <= r <= BAND[1]
        gating = not suf.startswith('barnes')
        print(f"R_b, level 2, {label:13s} {r:6.3f}  {'in the band' if inband else 'OUT OF THE BAND'}{'' if gating else '  (reported; does not gate)'}")
        if gating and not inband:
            why.append(f'R_b: {label} = {r:.3f}, outside [{BAND[0]}, {BAND[1]}]')
    if why:
        print('GATE: FAIL -- the A5 rerun does not start.')
        for x in why:
            print('   ' + x)
        return 1
    print('GATE: PASS -- Q0, Q1, Q2 hold and ocean and canneal are in the band at level 2.')
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == 'gem5-rows':
        gem5_rows(argv[2] if len(argv) > 2 else 'simulator/results/gem5_b3')
    elif len(argv) >= 5 and argv[1] == 'score':
        score(argv[2], argv[3], argv[4], argv[5:] or ['v2', 'v3'])
    elif len(argv) == 5 and argv[1] == 'same':
        return same(argv[2], argv[3], argv[4])
    elif len(argv) in (6, 7) and argv[1] == 'identical':
        n, bad, _ = identical(argv[2], argv[3], argv[4], argv[5], (argv[6],) if len(argv) == 7 else ('shared', 'private'))
        return 1 if bad or not n else 0
    elif len(argv) == 5 and argv[1] == 'gate':
        return gate(argv[2], argv[3], argv[4])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
