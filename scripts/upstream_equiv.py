#!/usr/bin/env python3
"""Part A's comparison (bench/policy_sanity/upstream_equiv_design_2026-11-10.md):
does our ChampSim, with the extension off, print exactly what upstream prints?

    upstream_equiv.py pair UPSTREAM.log OURS.log        one pair: E1 verdict, and why
    upstream_equiv.py dir  DIR                          every <name>.up.log / <name>.ours.log pair in DIR
    upstream_equiv.py e2   DIR                          E2: every <name>.oursdefault.log against <name>.up.log
    upstream_equiv.py selftest                          made-up logs, hand-known verdicts

E2 (reported, with the design's prediction): every <name>.oursdefault.log (our
default, RMW loads as RFOs) against <name>.up.log; the prediction holds when both
completed once and, our added lines set aside, the only lines that differ are the
per-type LOAD and RFO lines of L1D, L2C and LLC (cpuN->cache TYPE ACCESS: ...).

E1 holds for a pair when, with the wall clock masked,
  - both runs completed ("ChampSim completed all CPUs", once each);
  - every line of the upstream log appears in ours, identical and in the same
    order (upstream's log is a subsequence of ours);
  - every line of ours that is not one of upstream's matches a pattern in
    scripts/upstream_equiv_allow.txt (our new statistics and settings lines),
    or is blank.
Anything else is a difference, printed with its line numbers.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOW_FILE = os.path.join(HERE, 'upstream_equiv_allow.txt')
CLOCK = re.compile(r'\(Simulation time: [^)]*\)')
DONE = 'ChampSim completed all CPUs'


def allow_patterns(path=ALLOW_FILE):
    pats = []
    for line in open(path):
        line = line.rstrip('\n')
        if line and not line.startswith('#'):
            pats.append(re.compile(line))
    return pats


def lines(path):
    with open(path, errors='replace') as f:
        return [CLOCK.sub('', l.rstrip('\n')).rstrip() for l in f]


def compare(up, ours, pats):
    """-> (ok, [problems])"""
    probs = []
    for name, L in (('upstream', up), ('ours', ours)):
        n = sum(1 for l in L if l == DONE)
        if n != 1:
            probs.append(f'{name}: "{DONE}" printed {n} times')
    i = 0
    extra = 0
    for j, l in enumerate(ours):
        if i < len(up) and l == up[i]:
            i += 1
            continue
        if l == '' or any(p.search(l) for p in pats):
            extra += 1
            continue
        probs.append(f'ours line {j + 1} is neither upstream line {i + 1} nor an allowed statistic: {l[:110]!r}'
                     + (f'  (upstream line {i + 1}: {up[i][:110]!r})' if i < len(up) else ''))
        if len(probs) > 12:
            probs.append('... (stopped after 12)')
            break
    if i < len(up) and len(probs) <= 12:
        probs.append(f'upstream lines {i + 1}..{len(up)} never appear in ours (first: {up[i][:110]!r})')
    return (not probs), probs, extra


def pair(a, b, pats, quiet=False):
    ok, probs, extra = compare(lines(a), lines(b), pats)
    if not quiet:
        print(f'{"E1 holds" if ok else "E1 FAILS"}: {os.path.basename(a)} vs {os.path.basename(b)}'
              f' ({len(lines(a))} upstream lines, {extra} added lines allowed)')
        for p in probs:
            print('   ' + p)
    return ok


def run_dir(d, pats):
    names = sorted(f[:-len('.up.log')] for f in os.listdir(d) if f.endswith('.up.log'))
    held = 0
    missing = []
    for n in names:
        o = os.path.join(d, n + '.ours.log')
        if not os.path.exists(o):
            missing.append(n)
            continue
        held += pair(os.path.join(d, n + '.up.log'), o, pats)
    for f in sorted(os.listdir(d)):
        if f.endswith('.ours.log') and f[:-len('.ours.log')] not in names:
            missing.append(f[:-len('.ours.log')] + ' (no upstream log)')
    total = len(names) - len([m for m in missing if '(' not in m])
    print(f'== E1: {held} of {total} pairs hold; {len(missing)} without a partner{": " + ", ".join(missing) if missing else ""} ==')
    return held == total and not missing and total > 0


# the per-type lines as ChampSim prints them: <requester>-><cache> TYPE ACCESS: ... (plain_printer.cc)
TYPED = re.compile(r'^cpu\d+->(cpu\d+_(L1D|L2C)|LLC) +(LOAD|RFO) +ACCESS:')


def e2_compare(up, ours, pats):
    """E2's prediction: with the RMW change on, the same lines as upstream
    except per-type LOAD and RFO counts of L1D, L2C and LLC (TOTAL unchanged).
    -> (holds, [differing upstream lines, as (kind, upstream, ours)], [problems])"""
    done = [f'{name}: "{DONE}" printed {n} times' for name, L in (('upstream', up), ('ours', ours))
            for n in [sum(1 for l in L if l == DONE)] if n != 1]
    if done:
        return False, [], done
    keep = [l for l in ours if not (l and any(p.search(l) for p in pats))]
    a, b = list(up), keep
    while a and a[-1] == '':
        a.pop()
    while b and b[-1] == '':
        b.pop()
    if len(a) != len(b):
        return False, [], [f'{len(a)} upstream lines against {len(b)} of ours once our statistics are set aside']
    diffs = [(('typed' if TYPED.search(x) and TYPED.search(y) and x.split()[:2] == y.split()[:2] else 'OTHER'), x, y)
             for x, y in zip(a, b) if x != y]
    return all(k == 'typed' for k, _, _ in diffs), diffs, []


def run_e2(d, pats):
    names = sorted(f[:-len('.oursdefault.log')] for f in os.listdir(d) if f.endswith('.oursdefault.log'))
    held = 0
    for n in names:
        u = os.path.join(d, n + '.up.log')
        if not os.path.exists(u):
            print(f'   {n}: no upstream log'); continue
        ok, diffs, probs = e2_compare(lines(u), lines(os.path.join(d, n + '.oursdefault.log')), pats)
        held += ok
        typed = sum(1 for k, _, _ in diffs if k == 'typed')
        print(f'{"E2 prediction holds" if ok else "E2 prediction FAILS"}: {n} ({typed} per-type LOAD/RFO lines differ, '
              f'{len(diffs) - typed} other lines differ)')
        for p in probs:
            print('   ' + p)
        for k, x, y in [t for t in diffs if t[0] == 'OTHER'][:8]:
            print(f'   upstream: {x[:100]!r}\n   ours:     {y[:100]!r}')
    print(f'== E2: the prediction holds on {held} of {len(names)} ==')
    return held == len(names) and names


def selftest():
    pats = allow_patterns()
    up = ['*** ChampSim ***', 'Number of CPUs: 1', 'Simulation complete CPU 0 instructions: 10 (Simulation time: 00 hr 00 min 01 sec)',
          DONE, 'CPU 0 cumulative IPC: 0.5', 'LLC TOTAL ACCESS: 10 HIT: 5', 'cpu0_L1D TOTAL ACCESS: 9']
    ours = ['*** ChampSim ***', 'Number of CPUs: 1', 'Simulation complete CPU 0 instructions: 10 (Simulation time: 00 hr 00 min 09 sec)',
            DONE, 'CPU 0 cumulative IPC: 0.5', 'CPU 0 RMW LOADS ISSUED AS RFO: 0', 'LLC TOTAL ACCESS: 10 HIT: 5',
            'LLC COHERENCE INVALIDATIONS:          0', 'LLC SHARER HIST TOTAL:          5', 'cpu0_L1D TOTAL ACCESS: 9', '',
            'VMEM ALIASED FILLS (cross-CPU shared-page hits): 0', 'PRIVATE-CACHE COHERENCE LEVEL: 0', 'RMW LOADS AS RFO: off']
    up = [CLOCK.sub('', l).rstrip() for l in up]
    ours = [CLOCK.sub('', l).rstrip() for l in ours]
    cases = [
        ('identical apart from the clock and allowed additions', up, ours, True),
        ('a changed number', up, [l.replace('HIT: 5', 'HIT: 6') if l.startswith('LLC TOTAL') else l for l in ours], False),
        ('an upstream line missing from ours', up, [l for l in ours if not l.startswith('cpu0_L1D')], False),
        ('two upstream lines swapped', up, ours[:4] + [ours[6], ours[5], ours[4]] + ours[7:], False),
        ('an added line not on the list', up, ours + ['SOMETHING NEW: 3'], False),
        ('ours did not complete', up, [l for l in ours if l != DONE], False),
        ('upstream completed twice', up + [DONE], ours, False),
        ('an allowed name with a changed upstream line beside it', up,
         [l.replace('IPC: 0.5', 'IPC: 0.6') for l in ours], False),
    ]
    bad = 0
    for name, a, b, want in cases:
        ok, probs, _ = compare(a, b, pats)
        good = ok == want
        bad += not good
        print(f'   {"ok  " if good else "FAIL"} {name}: {"holds" if ok else "fails"} ({probs[0][:70] if probs else "-"})')
    # E2
    load = 'cpu0->LLC LOAD         ACCESS:      10 HIT:      5 MISS:      5'
    rfo = 'cpu0->LLC RFO          ACCESS:       0 HIT:      0 MISS:      0'
    upe = up[:6] + [load, rfo] + up[6:]
    oe = ours[:7] + [load.replace('10', ' 8').replace('MISS:      5', 'MISS:      3'), rfo.replace('ACCESS:       0', 'ACCESS:       2').replace('MISS:      0', 'MISS:      2')] + ours[7:]
    for name, a, b, want in [
        ('E2: only the LOAD/RFO split moves', upe, oe, True),
        ('E2: and a cycle count moves too', upe, [l.replace('IPC: 0.5', 'IPC: 0.4') for l in oe], False),
        ('E2: an upstream line lost', upe, [l for l in oe if not l.startswith('cpu0_L1D')], False),
        ('E2: a WRITE line moves (not LOAD/RFO)', [l.replace('RFO   ', 'WRITE ') for l in upe], [l.replace('RFO   ', 'WRITE ') for l in oe], False),
        ('E2: both runs stopped at the same point', [l for l in upe if l != DONE], [l for l in oe if l != DONE], False),
        ('E2: an L1I LOAD line moves (not L1D/L2C/LLC)', [l.replace('->LLC', '->cpu0_L1I') for l in upe], [l.replace('->LLC', '->cpu0_L1I') for l in oe], False),
    ]:
        ok, diffs, probs = e2_compare(a, b, pats)
        good = ok == want
        bad += not good
        print(f'   {"ok  " if good else "FAIL"} {name}: {"holds" if ok else "fails"} ({len(diffs)} differing, {probs[0][:50] if probs else "-"})')
    print(f'== selftest {"PASSES" if not bad else f"FAILS ({bad})"} ==')
    return bad


def main(argv):
    if len(argv) == 2 and argv[1] == 'selftest':
        return 1 if selftest() else 0
    pats = allow_patterns()
    if len(argv) == 4 and argv[1] == 'pair':
        return 0 if pair(argv[2], argv[3], pats) else 1
    if len(argv) == 3 and argv[1] == 'dir':
        return 0 if run_dir(argv[2], pats) else 1
    if len(argv) == 3 and argv[1] == 'e2':
        return 0 if run_e2(argv[2], pats) else 1
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
