#!/usr/bin/env python3
"""Judge Q16's ChampSim half against the hand counts fixed beforehand
(breadth_bc_design_2026-11-10.md, amendments 5, 8 and 9).

    q16_judge.py FORM_DIR [FORM_DIR ...]     each a bench/micro_champsim.sh OUT directory
    q16_judge.py --selftest

For every case and level found: the counts on the X lines (the harness's
.xline: P, A, U, and for s16 the cores its upgrades find in both views and the
private copies invalidated), the case's run minus the control's, against the
hand count x ROUNDS; no trace wrapped (the log's 'Reached end of trace', the
control's too). B (the bounded view) is not in the event log, so the harness
reads it over the whole run only: it is printed beside, never judged
(amendment 9).

Q16 holds only when every form given has the control and all eleven cases at
levels 0, 1 and 2, and every count is met exactly.

One hand count depends on the form (q16_results_2026-11-13.md, H-Q16a, made
after the barrier form's 120 was seen): s16's private copies invalidated at
level 2 are 15 a round in the timed form (the ring chased after the loads
leaves each reader's X_j in its L2C only) and 30 in the barrier form (no ring:
L1D and L2C). The form is read from the control's log: a run whose traces
carry sync records prints 'SYNC REPLAY: on'. The 4-thread self-test logs are
of the barrier form too; they hold no s16.
"""
import os
import re
import sys

ROUNDS = 4
CASES = ['pp_lock', 'pp_store', 'pp_rmw', 'readers', 'upgrade', 'ctl',
         'priv_E', 'priv_S', 'llc_out', 'offchip', 's16']
# the micro test's table at level 2, per round: P, A, U (micro_design_2026-10-17.md; amendment 5 for s16)
L2 = {'pp_lock': (3, 3, 0), 'pp_store': (3, 3, 0), 'pp_rmw': (3, 3, 0), 'readers': (1, 1, 0),
      'upgrade': (0, 0, 1), 'ctl': (1, 1, 0), 'priv_E': (1, 0, 0), 'priv_S': (1, 0, 0),
      'llc_out': (1, 1, 0), 'offchip': (1, 0, 0), 's16': (0, 0, 1)}


def expected(case, level, form='timed'):
    """{field: count} for a case at a level, ROUNDS rounds. form: 'timed' or 'barrier'
    (q16_results_2026-11-13.md: in the barrier form no ring is chased after s16's loads,
    so every reader keeps X_j in its L1D and its L2C -- 30 copies a round, not 15;
    diagnosed from the event log, H-Q16a)."""
    p, a, u = L2[case]
    if level == 0 and case in ('pp_lock', 'pp_store', 'pp_rmw'):
        p, a = 1, 1
    if level in (0, 1) and case in ('upgrade', 's16'):
        u = 0
    e = {'P': p * ROUNDS, 'A': a * ROUNDS, 'U': u * ROUNDS}
    if case == 's16':
        k = 15 if level == 2 else 0
        copies = 2 * k if form == 'barrier' else k
        e.update({'U_cores': k * ROUNDS, 'G5U_cores': k * ROUNDS, 'invalidated': copies * ROUNDS})
    return e


def read_xline(path):
    t = open(path).read().split()
    if not t or t[0] != 'xline':
        raise ValueError(f'{path}: not an xline')
    d = {}
    i = 1
    while i + 1 < len(t):
        d[t[i]] = int(t[i + 1])
        i += 2
    return d


def whole_run(path):
    """P A B U over the whole run, read as the harness's summary reads them (ROI block)."""
    txt = open(path).read()
    roi = txt[txt.find('Region of Interest'):] if 'Region of Interest' in txt else ''
    def last(pat):
        m = re.findall(r'^' + re.escape(pat) + r'\s*(\d+)\s*$', roi, re.M)
        return int(m[-1]) if m else 0
    u = sum(int(x) for x in re.findall(r'^\S+_(?:L1D|L2C|L1I) COHERENCE DIR UPGRADE EVENTS:\s*(\d+)\s*$', roi, re.M))
    return (last('LLC COHERENCE DIR RFO PROTOCOL-OTHER EVENTS:'), last('LLC COHERENCE DIR RFO PRESENCE-OTHER EVENTS:'),
            last('LLC COHERENCE DIR RFO BOUNDED-PROTOCOL EVENTS:'), u)


def judge_form(d, need_levels=(0, 1, 2), need_cases=CASES, out=print):
    """-> (met, missed, missing). Prints a row per case and level."""
    met = missed = missing = 0
    name = os.path.basename(os.path.normpath(d))
    for L in need_levels:
        cx, cl = os.path.join(d, f'control_L{L}.xline'), os.path.join(d, f'control_L{L}.log')
        if not (os.path.exists(cx) and os.path.exists(cl)):
            out(f'{name} L{L}: MISSING the control')
            missing += 1
            continue
        ctl = read_xline(cx)
        form = 'barrier' if 'SYNC REPLAY: on' in open(cl).read() else 'timed'   # sync records only in the barrier form
        if open(cl).read().count('Reached end of trace'):
            out(f'{name} L{L}: the control WRAPPED')
            missed += 1
        for c in need_cases:
            fx, fl = os.path.join(d, f'{c}_L{L}.xline'), os.path.join(d, f'{c}_L{L}.log')
            if not (os.path.exists(fx) and os.path.exists(fl)):
                out(f'{name} L{L} {c}: MISSING')
                missing += 1
                continue
            x = read_xline(fx)
            want = expected(c, L, form)
            got = {k: x.get(k, 0) - ctl.get(k, 0) for k in want}
            wrapped = open(fl).read().count('Reached end of trace')
            ok = got == want and wrapped == 0
            met += ok
            missed += not ok
            bad = [f'{k} {got[k]} want {want[k]}' for k in want if got[k] != want[k]]
            if wrapped:
                bad.append(f'wrapped {wrapped}')
            wp = whole_run(fl)
            out(f'{"ok  " if ok else "MISS"} {name} L{L} {c:9s} ' + ' '.join(f'{k} {got[k]}' for k in want)
                + f'   | whole run P A B U {wp[0]} {wp[1]} {wp[2]} {wp[3]}' + ('' if ok else '   <- ' + '; '.join(bad)))
    return met, missed, missing


def selftest():
    """The judge on the 4-thread harness output of 2026-10-19 (levels 0 and 2, the ten cases): every count met."""
    d = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'simulator', 'results', 'micro_champsim_g5')
    if not os.path.isdir(d):
        sys.exit(f'self-test: no {d}')
    lines = []
    met, missed, missing = judge_form(d, (0, 2), CASES[:-1], lines.append)
    print('\n'.join(lines))
    print(f'self-test (4 threads, levels 0 and 2, ten cases): {met} met, {missed} missed, {missing} missing')
    # a fault the judge must see: the hand count of one case off by one
    L2['ctl'] = (2, 1, 0)
    m2, x2, _ = judge_form(d, (0, 2), CASES[:-1], lambda s: None)
    L2['ctl'] = (1, 1, 0)
    print(f'self-test, injected (ctl P per round 2): {m2} met, {x2} missed (want 18, 2)')
    forms = (expected('s16', 2, 'timed')['invalidated'], expected('s16', 2, 'barrier')['invalidated'],
             expected('s16', 1, 'barrier')['invalidated'], expected('s16', 2, 'barrier')['U_cores'])
    print(f's16 invalidated (timed L2, barrier L2, barrier L1) and barrier U_cores: {forms} (want (60, 120, 0, 60))')
    ok = (met, missed, missing) == (20, 0, 0) and (m2, x2) == (18, 2) and forms == (60, 120, 0, 60)
    print('SELF-TEST ' + ('PASSES' if ok else 'FAILS'))
    return 0 if ok else 1


def main():
    if sys.argv[1:] == ['--selftest']:
        return selftest()
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    tot = [0, 0, 0]
    for d in sys.argv[1:]:
        r = judge_form(d)
        tot = [a + b for a, b in zip(tot, r)]
        print()
    met, missed, missing = tot
    want = len(sys.argv[1:]) * 3 * len(CASES)
    holds = missed == 0 and missing == 0 and met == want
    print(f'Q16 (ChampSim half): {met} of {want} met, {missed} missed, {missing} missing -> '
          + ('HOLDS' if holds else 'DOES NOT HOLD'))
    return 0 if holds else 1


if __name__ == '__main__':
    sys.exit(main())
