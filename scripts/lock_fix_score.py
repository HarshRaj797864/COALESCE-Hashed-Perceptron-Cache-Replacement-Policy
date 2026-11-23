#!/usr/bin/env python3
"""Score F-C (bench/policy_sanity/lock_fix_design_2026-11-12.md): a contended
mutex waiter issues one ownership request for the lock word.

    python3 scripts/lock_fix_score.py            # the reruns pulled by scripts/lockfix_all.sh pull
    python3 scripts/lock_fix_score.py parser     # only the parser check against the committed rows
    python3 scripts/lock_fix_score.py selftest   # the hand cases (no data read)

For each span of the lock-wait set (lock_wait_score.py's 14):
  C, I_c   the F-C rerun's gem5-rule RFO events (the first "LLC COHERENCE DIR
           RFO GEM5-RULE EVENTS" line) and instructions (the sum of the
           "Simulation complete CPU n instructions" values), read from its log
           exactly as scripts/b3_rows.sh reads them
  G, I_g   gem5's SS + MT L1 GETX and instructions in its window, from the gem5
           rows used for every earlier score (unchanged)
  R_g5   = (C / I_c) / (G / I_g)
  traffic  ChampSim's LLC (TOTAL - WRITE) accesses per KI in the Region of
           Interest (as run_phase_a.sh's rows) over gem5's L2 demand accesses
           per KI (as b3_score.py)

Before any rerun is read, the parser is run on the 14 SCORED logs and must
reproduce the committed rows (b3 rows rfo_g5, ins; phasea rows tot_acc,
wr_acc, ins) exactly; otherwise nothing is scored.

A rerun is scored only if it qualifies: complete; "SYNC LOCK WORD: request"
once; one LOCK-WORD REQUESTS line per MUTEX WAITED ACQUIRES line; the scored
log's warm-up, length and traces (the "CPU n runs" lines); level 2; no trace
wrap; self-check mismatches 0, stale-holder violations 0, every private cache
registered; Q3: every "VIEW-ORDER VIOLATIONS UNEXPLAINED" line 0.

The rules (the note, "Predictions" and "How the outcome is read"):
  P-F1  barnes std window, barnes std start, barnes-256: R_g5 in [0.5, 2]
  P-F2  barnes std force, ocean 2 MB, canneal 4c 2 MB, canneal 8c, radix,
        lunc, ocean non-contiguous: R_g5 in [0.5, 2]
  P-F3  traffic in [0.5, 2] on every span where the scored run had it there
  ADOPTED if P-F2 holds on 7 of 7 and P-F1 on at least 2 of 3 (K0-K4 held
  locally; recorded in the note); otherwise NOT ADOPTED. R_g5 > 2 on a
  failing span is reported as an over-count. Reported, deciding nothing:
  fluidanimate, vips, bodytrack, fmm; requests against contended acquires;
  upgrades (U_g5); cycles against the lock-wait reruns.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

ROOT = os.path.dirname(HERE)
NEW = os.path.join(ROOT, 'simulator/results/lockfix/logs')
LC = os.path.join(ROOT, 'simulator/results/lockwait/logs')
BAND = (0.5, 2.0)
FAILING = ['barnes std window', 'barnes std start', 'barnes-256']
AGREEING = ['barnes std force', 'ocean 2 MB', 'canneal 4c 2 MB', 'canneal 8c', 'radix', 'lunc', 'ocean non-contiguous']
REPORTED = ['fluidanimate', 'vips', 'bodytrack', 'fmm']
DONE = 'ChampSim completed all CPUs'
U_MIN_GEM5 = 10000   # as b3_score.py: gem5 upgrades in the window below which U is not scored
REQ = re.compile(r'^CPU (\d+) LOCK-WORD REQUESTS: measured (\d+) warmup (\d+)$', re.M)
WAITED = re.compile(r'^CPU (\d+) MUTEX WAITED ACQUIRES: measured contended (\d+) own (\d+) cycles (\d+); warmup contended (\d+) own (\d+)$', re.M)


def in_band(x):
    return BAND[0] <= x <= BAND[1]


def counts(txt):
    """the numbers the rows read from a log, read the same way"""
    lines = txt.splitlines()
    m = re.search(r'^LLC COHERENCE DIR RFO GEM5-RULE EVENTS.*?(\d+)$', txt, re.M)   # b3_rows.sh val(): the first line, its last number
    C = int(m.group(1)) if m else None
    ins = 0
    for ln in lines:                                   # b3_rows.sh / run_phase_a.sh: every line naming it, the value after "instructions:"
        if re.search(r'Simulation complete CPU [0-9]+ instructions:', ln):
            p = ln.split()
            ins += sum(int(p[i + 1]) for i in range(len(p) - 1) if p[i] == 'instructions:')
    tot = wr = 0
    roi = False
    for ln in lines:                                   # run_phase_a.sh: after "Region of Interest", every cpuN->LLC TOTAL / WRITE line
        if 'Region of Interest' in ln:
            roi = True
        if not roi:
            continue
        p = ln.split()
        acc = sum(int(p[i + 1]) for i in range(len(p) - 1) if p[i] == 'ACCESS:')
        if re.match(r'cpu[0-9]+->LLC TOTAL', ln):
            tot += acc
        elif re.match(r'cpu[0-9]+->LLC WRITE', ln):
            wr += acc
    seen, up = set(), 0                                # b3_rows.sh privsum(): each private cache's first line
    for c, v in re.findall(r'^(cpu[0-9]+_(?:L1I|L1D|L2C)) COHERENCE DIR UPGRADE GEM5-RULE EVENTS:.*?(\d+)$', txt, re.M):
        if c not in seen:
            seen.add(c)
            up += int(v)
    cyc = [int(y) for y in re.findall(r'^Simulation complete CPU \d+ instructions: \d+ cycles: (\d+)', txt, re.M)]
    return {'C': C, 'ins': ins, 'tot': tot, 'wr': wr, 'up': up if seen else None, 'maxcyc': max(cyc) if cyc else None}


def setting_lines(txt):
    """what makes two runs the same run: lengths, CPU count, traces"""
    keep = r'^(Warmup Instructions:|Simulation Instructions:|Number of CPUs:|CPU \d+ runs )'
    return [ln for ln in txt.splitlines() if re.match(keep, ln)]


def qualify(old_txt, new_txt):
    """'' if the F-C rerun qualifies, else why not"""
    if DONE not in new_txt:
        return 'the rerun did not complete'
    if len(re.findall(r'^SYNC LOCK WORD: request$', new_txt, re.M)) != 1:
        return 'no single "SYNC LOCK WORD: request" line: not run with sync_lock_word request'
    r, w = REQ.findall(new_txt), WAITED.findall(new_txt)
    if not w or len(r) != len(w):
        return f'{len(r)} lock-word request lines for {len(w)} waited-acquire lines'
    if setting_lines(old_txt) != setting_lines(new_txt) or not setting_lines(new_txt):
        return 'its lengths, CPU count or traces differ from the scored run'
    lv = re.findall(r'^PRIVATE-CACHE COHERENCE LEVEL: (\d+)', new_txt, re.M)
    if lv != ['2']:
        return f'coherence level {lv}, not 2'
    if 'Reached end of trace' in new_txt:
        return 'a trace wrapped'
    for name in ('COHERENCE DIR SELF-CHECK MISMATCHES', 'STALE-HOLDER VIOLATIONS'):
        v = [int(x) for x in re.findall(r'^\S*' + re.escape(' ' if name.startswith('C') else 'LLC COHERENCE DIR ') + name + r':.*?(\d+)$', new_txt, re.M)]
        if not v or any(v):
            return f'{name}: {v[:6]}{"..." if len(v) > 6 else ""}'
    n = int(re.search(r'^Number of CPUs: (\d+)', new_txt, re.M).group(1))
    reg = [int(x) for x in re.findall(r'^LLC COHERENCE DIR PRIVATE CACHES REGISTERED:.*?(\d+)$', new_txt, re.M)]
    if not reg or any(x != 3 * n for x in reg):
        return f'private caches registered {reg}, not {3 * n}'
    u = [int(x) for x in re.findall(r'^LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED:.*?(\d+)$', new_txt, re.M)]
    if not u or any(u):
        return f'Q3: unexplained view-order violations {u}'
    return ''


def ratios(c, w):
    """(R_g5, traffic, U_g5 or None) from a log's counts and gem5's window"""
    G, Ig = w['ss_getx'] + w['mt_getx'], w['insts']
    r = (c['C'] / c['ins']) / (G / Ig)
    tr = (1000.0 * (c['tot'] - c['wr']) / c['ins']) / (1000.0 * w['demand_acc'] / Ig)
    u = (1000.0 * c['up'] / c['ins']) / (1000.0 * w['ss_upgrade'] / Ig) if c['up'] is not None and w['ss_upgrade'] >= U_MIN_GEM5 else None
    return r, tr, u


def verdict(res):
    """res: {label: (R_g5, traffic, old traffic)} -> (verdict, lines)"""
    lines, f1, f2, over = [], 0, 0, []
    for k in FAILING:
        r = res[k][0]
        f1 += in_band(r)
        if r > BAND[1]:
            over.append(k)
        lines.append(f'   P-F1 {k}: R_g5 {r:.3f} {"in" if in_band(r) else "NOT in"} the band' + (' (over-count)' if r > BAND[1] else ''))
    for k in AGREEING:
        r = res[k][0]
        f2 += in_band(r)
        lines.append(f'   P-F2 {k}: R_g5 {r:.3f} {"stays in" if in_band(r) else "LEAVES"} the band')
    f3, n3 = 0, 0
    for k, (_, tr, otr) in res.items():
        if in_band(otr):
            n3 += 1
            f3 += in_band(tr)
            if not in_band(tr):
                lines.append(f'   P-F3 {k}: traffic {tr:.3f} LEAVES the band (was {otr:.3f})')
    lines.append(f'   P-F1 holds on {f1} of {len(FAILING)}; P-F2 on {f2} of {len(AGREEING)}; P-F3 on {f3} of {n3} spans whose traffic was in the band')
    if over:
        lines.append(f'   OVER-COUNT (R_g5 > 2) on: {", ".join(over)} -- reported; nothing is tuned')
    if f2 == len(AGREEING) and f1 >= 2:
        v = 'F-C ADOPTED (K0-K4 held locally): every Part B ChampSim run is rerun on the F-C binary under an amendment written first'
    else:
        v = 'F-C NOT ADOPTED: the paper reports the g6 binary and states lock-heavy programs as its limit, with this result'
    return v, lines


def spans():
    import disagree_diag as D
    B = D.B
    return D, B, list(D.SPANS) + [('fmm', 'reported', 'phaseA_b3_g3_fmm4', B.REFS['held']['fmm4'], D.G6LOG, None, None)]


def parser_check(verbose=True):
    """the parser on the 14 scored logs against the committed rows; True if every number equals"""
    D, B, sp = spans()
    P = B.load(D.PHASEA, B.PHASEA, lambda r: (r['tree'], r['rg']))
    Cr = B.load(D.B3ROWS, B.B3, lambda r: (r['tree'], r['rg']))
    bad = 0
    for label, _, tree, _, logroot, _, _ in sp:
        c, p = Cr[(tree, 'shared')], P[(tree, 'shared')]
        got = counts(open(D.runlog(logroot, tree)).read())
        want = {'C': int(c['rfo_g5']), 'ins': int(c['ins']), 'tot': int(p['tot_acc']), 'wr': int(p['wr_acc'])}
        diff = {k: (got[k], v) for k, v in want.items() if got[k] != v} | ({'ins (phasea)': (got['ins'], int(p['ins']))} if got['ins'] != int(p['ins']) else {})
        bad += bool(diff)
        if verbose or diff:
            print(f'   parser {label}: ' + ('equals the rows (C, I_c, LLC total, write)' if not diff else f'DIFFERS {diff}'))
    print(f'   parser check: {len(sp) - bad} of {len(sp)} scored logs reproduce the committed rows' + ('' if not bad else ' -- NOTHING IS SCORED'))
    return bad == 0


def main():
    D, B, sp = spans()
    have = {s[0] for s in sp}
    missing = [k for k in FAILING + AGREEING + REPORTED if k not in have]
    if missing:
        sys.exit(f'spans not defined: {missing}')
    print('== F-C (lock_fix_design_2026-11-12.md): R_g5 = (C / I_c) / (G / I_g) on the sync_lock_word request reruns')
    print('== the parser, on the scored logs')
    if not parser_check(verbose=False):
        sys.exit(1)
    P = B.load(D.PHASEA, B.PHASEA, lambda r: (r['tree'], r['rg']))
    Cr = B.load(D.B3ROWS, B.B3, lambda r: (r['tree'], r['rg']))
    Gr = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    res = {}
    for label, role, tree, (_, ga, gb), logroot, _, _ in sp:
        w = B.window(Gr, ga, gb)
        old = D.runlog(logroot, tree)
        ot = open(old).read()
        oc = counts(ot)
        r0, tr0, u0 = ratios(oc, w)
        sub = tree[len('phaseA_b3_'):]
        newroot = os.path.join(NEW, 'phaseA_b3_fc_' + sub)
        if not os.path.isdir(newroot):
            print(f'\n== {label}: NO RERUN pulled ({os.path.relpath(newroot, ROOT)})')
            continue
        nt = open(D.runlog(NEW, os.path.basename(newroot))).read()
        why = qualify(ot, nt)
        if why:
            print(f'\n== {label}: NOT SCORED -- {why}')
            continue
        nc = counts(nt)
        r, tr, u = ratios(nc, w)
        res[label] = (r, tr, tr0)
        req = {int(a): (int(b), int(c)) for a, b, c in REQ.findall(nt)}
        wt = {int(m[0]): tuple(map(int, m[1:])) for m in WAITED.findall(nt)}
        rq, rqw = sum(v[0] for v in req.values()), sum(v[1] for v in req.values())
        con, conw = sum(v[0] for v in wt.values()), sum(v[3] for v in wt.values())
        lcroot = os.path.join(LC, 'phaseA_b3_lc_' + sub)
        lct = open(D.runlog(LC, os.path.basename(lcroot))).read() if os.path.isdir(lcroot) else ''
        lcon = sum(int(m[1]) for m in WAITED.findall(lct)) if lct else None
        lcc = counts(lct)['maxcyc'] if lct else None
        role_s = 'failing (P-F1)' if label in FAILING else 'agreeing (P-F2)' if label in AGREEING else 'reported, decides nothing'
        print(f'\n== {label}: {role_s}; qualifies (Q3 unexplained 0)')
        print(f'   C {nc["C"]} in I_c {nc["ins"]} (scored run: {oc["C"]} in {oc["ins"]}); R_g5 {r:.3f} (was {r0:.3f})')
        print(f'   traffic {tr:.3f} (was {tr0:.3f}); U_g5 ' + (f'{u:.3f} (was {u0:.3f})' if u is not None else 'not scored (gem5 upgrades below 10,000)'))
        print(f'   lock-word requests: measured {rq}, warm-up {rqw}; contended waited acquires in this run: measured {con}, warm-up {conw}'
              + (f'; in the lock-wait rerun: measured {lcon}' if lcon is not None else ''))
        print(f'   max cycles {nc["maxcyc"]}' + (f' against the lock-wait rerun\'s {lcc} ({(nc["maxcyc"] - lcc) / lcc:+.2%})' if lcc else ''))
    print('\n== The rules (the note, "Predictions")')
    need = [k for k in FAILING + AGREEING if k not in res]
    if need:
        print(f'   NOT SCORED: no verdict while these spans are missing or do not qualify: {", ".join(need)}')
        sys.exit(1)
    # P-F3 reads every scored span, the reported ones included
    v, lines = verdict(res)
    print('\n'.join(lines))
    print(f'   VERDICT: {v}')


def selftest():
    ok = True

    def check(name, got, want):
        nonlocal ok
        good = (abs(got - want) < 1e-12) if isinstance(want, float) else got == want
        ok &= good
        print(f'   {"ok  " if good else "FAIL"} {name}: {got!r}' + ('' if good else f' (want {want!r})'))

    w = {'ss_getx': 300, 'mt_getx': 100, 'insts': 1_000_000, 'demand_acc': 20_000, 'ss_upgrade': 20_000}
    # C 100 in 1 M against G 400 in 1 M -> 0.25; LLC 25,000 - 5,000 = 20,000 a M against 20,000 -> 1.0;
    # upgrades 10,000 against 20,000 -> 0.5
    c = {'C': 100, 'ins': 1_000_000, 'tot': 25_000, 'wr': 5_000, 'up': 10_000, 'maxcyc': 1}
    r, tr, u = ratios(c, w)
    check('R_g5', r, 0.25); check('traffic', tr, 1.0); check('U_g5', u, 0.5)
    # different instruction counts: C 300 in 2 M, G 400 in 1 M -> 150 / 400 = 0.375; traffic (20,000 / 2 M) / (20,000 / 1 M) = 0.5
    r, tr, u = ratios(dict(c, C=300, ins=2_000_000), w)
    check('R_g5 scaled', r, 0.375); check('traffic scaled', tr, 0.5)
    check('U_g5 not scored below 10,000', ratios(c, dict(w, ss_upgrade=9_999))[2], None)
    # the parser, on a log written as ChampSim writes it (two stats blocks; the ROI block last)
    log = '\n'.join([
        'Number of CPUs: 2', 'CPU 0 runs a.xz', 'CPU 1 runs b.xz', 'Warmup Instructions: 10', 'Simulation Instructions: 20',
        'PRIVATE-CACHE COHERENCE LEVEL: 2',
        'LLC COHERENCE DIR RFO GEM5-RULE EVENTS: 7',
        'cpu0->LLC TOTAL        ACCESS:        999  HIT:  1', 'cpu0_L1D COHERENCE DIR UPGRADE GEM5-RULE EVENTS: 5',
        'Simulation complete CPU 0 instructions: 20 cycles: 300 cumulative IPC: 0.1 (Simulation time: 00 hr 00 min 01 sec)',
        'Simulation complete CPU 1 instructions: 21 cycles: 400 cumulative IPC: 0.1 (Simulation time: 00 hr 00 min 01 sec)',
        'Region of Interest Statistics',
        'LLC COHERENCE DIR RFO GEM5-RULE EVENTS: 7',
        'cpu0->LLC TOTAL        ACCESS:        100  HIT:  1', 'cpu1->LLC TOTAL        ACCESS:         50  HIT:  1',
        'cpu0->LLC WRITE        ACCESS:         30  HIT:  1', 'cpu1->LLC WRITE        ACCESS:         20  HIT:  1',
        'cpu0_L1D COHERENCE DIR UPGRADE GEM5-RULE EVENTS: 5', 'cpu0_L2C COHERENCE DIR UPGRADE GEM5-RULE EVENTS: 2',
        'cpu0_L1D COHERENCE DIR SELF-CHECK MISMATCHES: 0', 'cpu1_L2C COHERENCE DIR SELF-CHECK MISMATCHES: 0',
        'LLC COHERENCE DIR STALE-HOLDER VIOLATIONS: 0', 'LLC COHERENCE DIR PRIVATE CACHES REGISTERED: 6',
        'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS: 2', 'LLC COHERENCE DIR VIEW-ORDER VIOLATIONS UNEXPLAINED: 0',
        'CPU 0 MUTEX WAITED ACQUIRES: measured contended 3 own 1 cycles 60; warmup contended 1 own 0',
        'CPU 1 MUTEX WAITED ACQUIRES: measured contended 0 own 2 cycles 9; warmup contended 0 own 0',
        'SYNC LOCK WORD: request', 'CPU 0 LOCK-WORD REQUESTS: measured 3 warmup 1', 'CPU 1 LOCK-WORD REQUESTS: measured 0 warmup 0',
        DONE, ''])
    check('counts', counts(log), {'C': 7, 'ins': 41, 'tot': 150, 'wr': 50, 'up': 7, 'maxcyc': 400})
    old = '\n'.join(ln for ln in log.splitlines() if 'LOCK WORD' not in ln and 'LOCK-WORD' not in ln)
    check('qualifies', qualify(old, log), '')
    check('not request', qualify(old, old)[:9], 'no single')
    check('incomplete', qualify(old, log.replace(DONE, '')), 'the rerun did not complete')
    check('a request line missing', qualify(old, log.replace('CPU 1 LOCK-WORD', 'CPU 1 LOCK-WORX'))[:2], '1 ')
    check('another trace', qualify(old, log.replace('CPU 1 runs b.xz', 'CPU 1 runs c.xz'))[:9], 'its lengt')
    check('another length', qualify(old, log.replace('Simulation Instructions: 20', 'Simulation Instructions: 21'))[:9], 'its lengt')
    check('level 1', qualify(old, log.replace('LEVEL: 2', 'LEVEL: 1'))[:14], 'coherence leve')
    check('a wrap', qualify(old, log.replace(DONE, 'Reached end of trace x\n' + DONE)), 'a trace wrapped')
    check('self-check', qualify(old, log.replace('cpu1_L2C COHERENCE DIR SELF-CHECK MISMATCHES: 0', 'cpu1_L2C COHERENCE DIR SELF-CHECK MISMATCHES: 4'))[:21], 'COHERENCE DIR SELF-CH')
    check('stale holder', qualify(old, log.replace('STALE-HOLDER VIOLATIONS: 0', 'STALE-HOLDER VIOLATIONS: 1'))[:12], 'STALE-HOLDER')
    check('registered', qualify(old, log.replace('REGISTERED: 6', 'REGISTERED: 5'))[:17], 'private caches re')
    check('Q3', qualify(old, log.replace('UNEXPLAINED: 0', 'UNEXPLAINED: 1'))[:2], 'Q3')
    check('Q3 line missing', qualify(old, log.replace('VIEW-ORDER VIOLATIONS UNEXPLAINED: 0', 'X'))[:2], 'Q3')
    # the verdicts
    inb, out_lo, out_hi = (1.0, 1.0, 1.0), (0.3, 1.0, 1.0), (2.4, 1.0, 1.0)
    base = {k: inb for k in AGREEING + REPORTED}
    check('ADOPTED, 3 of 3', verdict({**base, **{k: inb for k in FAILING}})[0][:11], 'F-C ADOPTED')
    check('ADOPTED, 2 of 3', verdict({**base, **{k: inb for k in FAILING[:2]}, FAILING[2]: out_lo})[0][:11], 'F-C ADOPTED')
    check('NOT, 1 of 3', verdict({**base, FAILING[0]: inb, **{k: out_lo for k in FAILING[1:]}})[0][:15], 'F-C NOT ADOPTED')
    check('NOT, an agreeing span leaves', verdict({**base, 'radix': out_hi, **{k: inb for k in FAILING}})[0][:15], 'F-C NOT ADOPTED')
    check('NOT, an agreeing span falls', verdict({**base, 'lunc': out_lo, **{k: inb for k in FAILING}})[0][:15], 'F-C NOT ADOPTED')
    v, lines = verdict({**base, **{k: inb for k in FAILING[:2]}, FAILING[2]: out_hi})
    check('over-count reported, 2 of 3 still adopts', (v[:11], any('OVER-COUNT' in x for x in lines)), ('F-C ADOPTED', True))
    check('edges count as in the band', verdict({**base, 'radix': (2.0, 1.0, 1.0), **{k: (0.5, 1.0, 1.0) for k in FAILING}})[0][:11], 'F-C ADOPTED')
    check('just past the edge', verdict({**base, **{k: (0.4999, 1.0, 1.0) for k in FAILING}})[0][:15], 'F-C NOT ADOPTED')
    v, lines = verdict({**base, **{k: inb for k in FAILING}, 'vips': (0.3, 2.5, 1.0), 'fmm': (0.7, 2.5, 2.5)})
    # 14 spans; fmm's traffic was out (not counted): 13; vips's leaves the band: 12 of 13
    check('P-F3 counts only spans whose traffic was in the band', [x for x in lines if 'P-F3 on' in x][0].split('P-F3 on ')[1][:8], '12 of 13')
    print('selftest:', 'PASS' if ok else 'FAILED')
    return ok


if __name__ == '__main__':
    if sys.argv[1:] == ['selftest']:
        sys.exit(0 if selftest() else 1)
    if sys.argv[1:] == ['parser']:
        sys.exit(0 if parser_check() else 1)
    main()
