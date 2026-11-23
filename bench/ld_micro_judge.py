#!/usr/bin/env python3
"""QC1 of C (bench/policy_sanity/load_side_design_2026-11-18.md): the load-side
event against the micro program's hand counts.

    python3 bench/ld_micro_judge.py cs OUT      # QC1a: the micro harness's OUT (KEEP_EVENTS=1, level 2, 4 rounds)
    python3 bench/ld_micro_judge.py g5 DIR      # QC1b: DIR/<case>_r4 and DIR/<case>_r8 gem5 runs
    python3 bench/ld_micro_judge.py selftest

Per round, a load reaching the shared cache while another core is the line's
exclusive holder: readers, upgrade, priv_S 1; every other case 0.
QC1a: on the test lines (X .. X + 64 lines, as the harness counts), the event
log's L lines of type LOAD with the 14th field 1 = 4 x that, exactly; the
control 0; every L line on the test lines has the 14th field.
QC1b: gem5's L2Cache_Controller.MT.L1_GETS in the first statistics block,
(r8 - r4) within 1 of 4 x that.
"""
import os
import re
import sys

HAND = {'pp_lock': 0, 'pp_store': 0, 'pp_rmw': 0, 'readers': 1, 'upgrade': 1, 'ctl': 0,
        'priv_E': 0, 'priv_S': 1, 'llc_out': 0, 'offchip': 0}
ROUNDS_CS = 4
MT = 'system.ruby.L2Cache_Controller.MT.L1_GETS'


def cs_count(events, runout):
    X = int(re.search(r'X (0x[0-9a-f]+)', open(runout).read()).group(1), 16) >> 6
    n = short = 0
    for line in open(events):
        p = line.split()
        if not p or p[0] != 'L' or len(p) < 12:
            continue
        if not (X <= int(p[7], 16) < X + 64):
            continue
        if len(p) < 14:
            short += 1
            continue
        if p[9] == 'LOAD' and p[13] == '1':
            n += 1
    return n, short


def roi_llc(log):
    t = open(log, errors='replace').read()
    i = t.find('Region of Interest Statistics')
    v = {}
    for k in ('LOAD', 'OTHER-READ'):
        m = re.search(rf'^LLC COHERENCE DIR {k} GEM5-RULE OWNER EVENTS:\s+(\d+)$', t[i:] if i >= 0 else '', re.M)
        v[k] = int(m.group(1)) if m else None
    return v


def judge_cs(out):
    bad = 0
    for c in ['control'] + list(HAND):
        ev, ro, lg = (os.path.join(out, f'{c}_L2.events'), os.path.join(out, f'{c}_run.out'), os.path.join(out, f'{c}_L2.log'))
        if not all(os.path.exists(f) for f in (ev, ro, lg)):
            print(f'{c:9s} MISSING its event log, run.out or log')
            bad += 1
            continue
        n, short = cs_count(ev, ro)
        want = 0 if c == 'control' else ROUNDS_CS * HAND[c]
        g = roi_llc(lg)
        ok = n == want and short == 0
        bad += not ok
        print(f'{c:9s} test lines: LOAD owner events {n} (want {want}){"" if short == 0 else f"; {short} L lines without the flag"}'
              f' -- {"ok" if ok else "FAILS"}; whole-run LLC counter LOAD {g["LOAD"]}, OTHER-READ {g["OTHER-READ"]} (reported)')
    print(f'QC1a {"holds" if bad == 0 else "FAILS"}: {len(HAND) + 1 - bad} of {len(HAND) + 1}')
    return 0 if bad == 0 else 1


def first_block(stats):
    s, blocks = {}, 0
    for line in open(stats):
        if 'Begin Simulation Statistics' in line:
            blocks += 1
            if blocks > 1:
                break
            continue
        p = line.split()
        if len(p) >= 2 and re.fullmatch(r'-?[0-9.e+]+', p[1]) and p[0] not in s:
            s[p[0]] = float(p[1])
    return s, blocks


def judge_g5(d):
    bad = 0
    for c, h in HAND.items():
        v = {}
        for r in (4, 8):
            run = os.path.join(d, f'{c}_r{r}')
            log = os.path.join(run, 'run.log')
            st = os.path.join(run, 'stats.txt')
            if not (os.path.exists(log) and 'Exiting @ tick' in open(log, errors='replace').read() and os.path.exists(st)):
                v[r] = None
                continue
            s, blocks = first_block(st)
            v[r] = (s, blocks)
        if v[4] is None or v[8] is None or v[4][1] < 1 or v[8][1] < 1:
            print(f'{c:9s} MISSING a completed run with statistics (r4 {v[4] is not None}, r8 {v[8] is not None})')
            bad += 1
            continue
        a, b = int(v[4][0].get(MT, 0)), int(v[8][0].get(MT, 0))
        want = 4 * h
        ok = abs((b - a) - want) <= 1
        bad += not ok
        fw = {k: int(v[8][0].get(f'system.ruby.L1Cache_Controller.{k}.Fwd_GETS::total', 0)) - int(v[4][0].get(f'system.ruby.L1Cache_Controller.{k}.Fwd_GETS::total', 0)) for k in ('EE', 'MM')}
        print(f'{c:9s} MT.L1_GETS r4 {a}, r8 {b}, r8 - r4 {b - a} (want {want} +- 1) -- {"ok" if ok else "FAILS"};'
              f' owner side r8 - r4: EE.Fwd_GETS {fw["EE"]}, MM.Fwd_GETS {fw["MM"]} (reported)')
    print(f'QC1b {"holds" if bad == 0 else "FAILS"}: {len(HAND) - bad} of {len(HAND)}')
    return 0 if bad == 0 else 1


def selftest():
    import tempfile
    ok = bad = 0

    def check(name, got, want):
        nonlocal ok, bad
        g = got == want
        ok, bad = ok + g, bad + (not g)
        print(f'   {"ok  " if g else "FAIL"}  {name}: {got} (want {want})')

    with tempfile.TemporaryDirectory() as t:
        X = 0x7f0000001000
        open(f'{t}/run.out', 'w').write(f'X {hex(X)}\n')
        xl = X >> 6
        lines = [
            f'L LLC 10 0 1 5 400000 {xl:x} 99 LOAD 1 1 1 1',          # counts
            f'L LLC 11 0 2 6 400000 {xl + 1:x} 98 LOAD 3 3 3 0',      # flag 0
            f'L LLC 12 0 2 7 400000 {xl + 64:x} 97 LOAD 1 1 1 1',     # outside the test lines
            f'L LLC 13 0 2 8 400000 {xl + 2:x} 96 TRANSLATION 1 1 1 1',  # not a LOAD
            f'G LLC 14 0 3 9 400000 {xl:x} 99 RFO 1 1 1',              # not L
            f'L LLC 15 0 0 10 400000 {xl + 63:x} 95 LOAD 2 2 2 1',    # counts (last test line)
        ]
        open(f'{t}/ev', 'w').write('\n'.join(lines) + '\n')
        check('cs count on the test lines', cs_count(f'{t}/ev', f'{t}/run.out'), (2, 0))
        open(f'{t}/ev2', 'w').write(f'L LLC 10 0 1 5 400000 {xl:x} 99 LOAD 1 1 1\n')
        check('an L line without the flag is caught', cs_count(f'{t}/ev2', f'{t}/run.out'), (0, 1))
        open(f'{t}/stats', 'w').write('---------- Begin Simulation Statistics ----------\n'
                                      f'{MT}  7  0.0%\nsimInsts 100\n'
                                      '---------- End Simulation Statistics   ----------\n'
                                      '---------- Begin Simulation Statistics ----------\n'
                                      f'{MT}  99  0.0%\n')
        s, blocks = first_block(f'{t}/stats')
        check('first block only', (int(s[MT]), blocks), (7, 2))
        log = ('Region of Interest Statistics\nLLC COHERENCE DIR LOAD GEM5-RULE OWNER EVENTS:         12\n'
               'LLC COHERENCE DIR OTHER-READ GEM5-RULE OWNER EVENTS:          0\n')
        open(f'{t}/log', 'w').write('LLC COHERENCE DIR LOAD GEM5-RULE OWNER EVENTS:        999\n' + log)
        check('the ROI block is read', roi_llc(f'{t}/log'), {'LOAD': 12, 'OTHER-READ': 0})
    print(f'== selftest: {ok} hold, {bad} fail ==')
    return 1 if bad else 0


def main(a):
    if len(a) == 2 and a[0] == 'cs':
        return judge_cs(a[1])
    if len(a) == 2 and a[0] == 'g5':
        return judge_g5(a[1])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
