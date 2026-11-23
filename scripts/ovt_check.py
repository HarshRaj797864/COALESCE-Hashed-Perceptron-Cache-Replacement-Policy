#!/usr/bin/env python3
"""H1b's checks and counts (bench/policy_sanity/fifo_overtake_design_2026-11-14.md),
fixed before any run of the counter build exists.

    ovt_check.py qs OLD_DIR NEW_DIR LOG         QO-S: the micro's stats equal under the two binaries
    ovt_check.py qo0 ORIG_DIR NEW_DIR           QO0: the same configuration
    ovt_check.py qo1 ORIG_DIR NEW_DIR LOG       QO1: the run's outcome (once its gem5 has ended)
    ovt_check.py qo2 H1_RESULT LOG              QO2: the first L0 overtake = H1's panic line
    ovt_check.py report NAME ORIG_DIR SHORT_DIR NEW_DIR LOG [H1_RESULT]
                                                the counts (only if QO1 is IDENTICAL, and QO2
                                                holds where H1 panicked)
    ovt_check.py selftest

LOG: the counter's file ($COALESCE_OVERTAKE_LOG), one line an overtake:
    tick buffer delta arrival last_arrival ordered
Exit codes: 0 = holds / IDENTICAL; 1 = fails; qo1: 3 = DIFFERENT, 4 = OTHER.
"""
import os
import re
import sys
import tempfile

EXIT_OK = 'because a thread reached the max instruction count'
L0BUF = re.compile(r'^system\.ruby\.l0_cntrl(\d+)\.buffer(ToL1|FromL1)$')
H1PANIC = re.compile(r'PANIC tick (\d+) buffer (\S+) delta (\d+) arrival (\d+) last (\d+)')


def stat_lines(d):
    return [ln for ln in open(os.path.join(d, 'stats.txt')).read().splitlines() if not ln.startswith('host')]


def final_tick(d):
    p = os.path.join(d, 'stats.txt')
    if not os.path.exists(p):
        return None
    m = re.search(r'^finalTick\s+(\d+)', open(p).read(), re.M)
    return int(m.group(1)) if m else None


def first_diff(a, b):
    diff = [i for i, (x, y) in enumerate(zip(a, b)) if x != y] + list(range(min(len(a), len(b)), max(len(a), len(b))))
    return diff


def read_log(path):
    ev = []
    for ln in open(path):
        p = ln.split()
        if len(p) == 6:
            ev.append(dict(tick=int(p[0]), buf=p[1], delta=int(p[2]), arr=int(p[3]), last=int(p[4]), ordered=int(p[5])))
    return ev


def qs(old, new, log, out=print):
    if not os.path.exists(log):
        out(f'QO-S FAILS: no counter log {log} (the variable did not reach gem5)')
        return 1
    a, b = stat_lines(old), stat_lines(new)
    d = first_diff(a, b)
    if d:
        out(f'QO-S FAILS: {len(d)} statistics lines differ; first {d[0]}: "{(a[d[0]] if d[0] < len(a) else "<none>")[:100]}"')
        return 1
    out(f'QO-S HOLDS: {len(a)} statistics lines equal under the two binaries (host lines aside); counter log {len(read_log(log))} overtakes')
    return 0


def qo0(orig, new, out=print):
    a = [ln.replace(orig.rstrip('/'), new.rstrip('/')) for ln in open(os.path.join(orig, 'config.ini')).read().splitlines()]
    b = open(os.path.join(new, 'config.ini')).read().splitlines()
    d = first_diff(a, b)
    if d:
        out(f'QO0 FAILS: {len(d)} lines differ; first {d[0]}: "{(a[d[0]] if d[0] < len(a) else "<none>")[:100]}" / "{(b[d[0]] if d[0] < len(b) else "<none>")[:100]}"')
        return 1
    out(f'QO0 HOLDS: config.ini equal ({len(a)} lines) once the output path is mapped')
    return 0


def qo1(orig, new, log, out=print):
    rl = os.path.join(new, 'run.log')
    txt = open(rl, errors='replace').read() if os.path.exists(rl) else ''
    if EXIT_OK in txt and os.path.exists(os.path.join(new, 'stats.txt')):
        if not os.path.exists(log):
            out('QO1 OTHER: the run completed but wrote no counter log (void)')
            return 4
        a, b = stat_lines(orig), stat_lines(new)
        d = first_diff(a, b)
        if not d:
            out(f'QO1 COMPLETE-IDENTICAL: {len(a)} statistics lines equal (host lines aside); finalTick {final_tick(new)}')
            return 0
        out(f'QO1 COMPLETE-DIFFERENT: {len(d)} lines differ; first "{(a[d[0]] if d[0] < len(a) else "<none>")[:100]}" / "{(b[d[0]] if d[0] < len(b) else "<none>")[:100]}"')
        return 3
    tail = [ln for ln in txt.splitlines() if ln.strip()][-1:] or ['<empty run.log>']
    out(f'QO1 OTHER: no normal exit; last line: {tail[0][:160]}')
    return 4


def h1_panic(result_file):
    if not result_file or not os.path.exists(result_file):
        return None
    m = H1PANIC.search(open(result_file).read())
    return tuple(int(x) if x.isdigit() else x for x in m.groups()) if m else None


def qo2(result_file, log, out=print):
    want = h1_panic(result_file)
    if want is None:
        out('QO2 NOT APPLICABLE: H1 did not panic here')
        return 0
    first = next((e for e in read_log(log) if L0BUF.match(e['buf'])), None)
    got = None if first is None else (first['tick'], first['buf'], first['delta'], first['arr'], first['last'])
    if got == want:
        out(f'QO2 HOLDS: the first L0 overtake is H1\'s panic line exactly (tick {want[0]}, {want[1]})')
        return 0
    out(f'QO2 FAILS: first L0 overtake {got}; H1\'s panic {want}')
    return 1


def msgs(d):
    n = 0
    for ln in open(os.path.join(d, 'stats.txt')):
        p = ln.split()
        if len(p) >= 2 and p[0].endswith('.m_msg_count') and L0BUF.match(p[0][:-len('.m_msg_count')]):
            n += int(p[1])
    return n


def report(name, orig, short, new, log, result_file=None, out=print):
    if qo1(orig, new, log, out=lambda *a: None) != 0:
        out(f'{name}: NOT READ (QO1 is not COMPLETE-IDENTICAL)')
        return 1
    if qo2(result_file, log, out=lambda *a: None) != 0:
        out(f'{name}: NOT READ (QO2 fails)')
        return 1
    ev = read_log(log)
    t0 = final_tick(short)
    l0 = [e for e in ev if L0BUF.match(e['buf'])]
    other = [e for e in ev if not L0BUF.match(e['buf'])]
    win = [e for e in l0 if e['tick'] > t0]
    m = msgs(new) - msgs(short)
    by = {}
    for e in win:
        k = L0BUF.match(e['buf']).group(2)
        by[k] = by.get(k, 0) + 1
    margins = sorted(e['last'] - e['arr'] for e in l0)
    pm = 1e6 * len(win) / m if m else float('nan')
    out(f'{name}: L0 overtakes {len(l0)} in the run, {len(win)} in the window ({", ".join(f"{k} {v}" for k, v in sorted(by.items())) or "-"}); '
        f'window L0 messages {m:,}; {pm:.3f} per million; other buffers {len(other)} (unordered {sum(1 for e in other if not e["ordered"])}, ordered {sum(1 for e in other if e["ordered"])}); '
        f'margin (ticks) min {margins[0] if margins else "-"} max {margins[-1] if margins else "-"}; H1 {"PANIC" if h1_panic(result_file) else "no panic"}')
    return 0


def selftest():
    ok = True
    d = tempfile.mkdtemp(prefix='ovt_selftest_')
    o, s, n = (os.path.join(d, x) for x in ('orig', 'short', 'new'))
    for x in (o, s, n):
        os.makedirs(x)
    st = ('---------- Begin Simulation Statistics ----------\nfinalTick {t}\nhostSeconds {h}\n'
          'system.ruby.l0_cntrl0.bufferFromL1.m_msg_count {a}\nsystem.ruby.l0_cntrl0.bufferToL1.m_msg_count {b}\n'
          'system.ruby.l1_cntrl0.requestToL2.m_msg_count 77\n')
    open(os.path.join(o, 'stats.txt'), 'w').write(st.format(t=3000, h=10, a=1500000, b=1000000))
    open(os.path.join(n, 'stats.txt'), 'w').write(st.format(t=3000, h=99, a=1500000, b=1000000))
    open(os.path.join(s, 'stats.txt'), 'w').write(st.format(t=1000, h=5, a=500000, b=500000))
    for x in (o, n):
        open(os.path.join(x, 'run.log'), 'w').write('...\nExiting @ tick 3000 because a thread reached the max instruction count\n')
    open(os.path.join(o, 'config.ini'), 'w').write(f'[root]\ninput={o}/x.in\ncwd=/home/h/gem5\n')
    open(os.path.join(n, 'config.ini'), 'w').write(f'[root]\ninput={n}/x.in\ncwd=/home/h/gem5\n')
    lg = os.path.join(n, 'ovt.txt')
    open(lg, 'w').write('900 system.ruby.l0_cntrl1.bufferToL1 500 950 1000 0\n'          # warm-up
                        '1500 system.ruby.l0_cntrl0.bufferFromL1 500 2000 2500 0\n'      # window
                        '2600 system.ruby.l0_cntrl2.bufferFromL1 500 3100 3600 0\n')
    h1 = os.path.join(d, 'RESULT')
    open(h1, 'w').write('PANIC tick 900 buffer system.ruby.l0_cntrl1.bufferToL1 delta 500 arrival 950 last 1000 phase warm-up\n')
    q = lambda f, *a: f(*a, out=lambda *x: None)
    res = [('qs holds', q(qs, o, n, lg) == 0), ('qs: no log fails', q(qs, o, n, lg + 'x') == 1),
           ('qo0 holds', q(qo0, o, n) == 0), ('qo1 identical', q(qo1, o, n, lg) == 0), ('qo2 holds', q(qo2, h1, lg) == 0)]
    buf = []
    report('t', o, s, n, lg, h1, out=buf.append)
    res.append(('report', buf == ['t: L0 overtakes 3 in the run, 2 in the window (FromL1 2); window L0 messages 1,500,000; 1.333 per million; '
                                  'other buffers 0 (unordered 0, ordered 0); margin (ticks) min 50 max 500; H1 PANIC']))
    lg2 = os.path.join(n, 'ovt2.txt')
    open(lg2, 'w').write(open(lg).read() + '1600 system.ruby.l2_cntrl0.responseFromL2Cache 500 2100 2200 0\n'
                         '1700 system.ruby.l1_cntrl0.requestToL2 500 2200 2300 1\n'
                         '1800 system.ruby.l2_cntrl0.responseFromL2Cache 500 2300 2400 0\n')
    buf = []
    report('t', o, s, n, lg2, h1, out=buf.append)
    res.append(('report: other buffers by flag', 'other buffers 3 (unordered 2, ordered 1);' in buf[0]))
    # faults
    open(h1 + '2', 'w').write('PANIC tick 901 buffer system.ruby.l0_cntrl1.bufferToL1 delta 500 arrival 950 last 1000 phase warm-up\n')
    res.append(('qo2: another tick fails', q(qo2, h1 + '2', lg) == 1))
    open(h1 + '3', 'w').write('COMPLETE-IDENTICAL: 10 statistics lines equal\n')
    res.append(('qo2: not applicable without a panic', q(qo2, h1 + '3', lg) == 0))
    open(os.path.join(n, 'config.ini'), 'a').write('extra=1\n')
    res.append(('qo0: an extra line fails', q(qo0, o, n) == 1))
    open(os.path.join(n, 'stats.txt'), 'a').write('system.x 1\n')
    res.append(('qo1: different', q(qo1, o, n, lg) == 3))
    buf = []
    res.append(('report refuses a different run', report('t', o, s, n, lg, h1, out=buf.append) == 1 and 'NOT READ' in buf[0]))
    open(os.path.join(n, 'run.log'), 'w').write('panic: something\n')
    res.append(('qo1: other', q(qo1, o, n, lg) == 4))
    for k, v in res:
        if not v:
            ok = False
            print(f'selftest: {k} FAILS')
    print('selftest PASS' if ok else 'selftest FAIL')
    return 0 if ok else 1


def main(a):
    if a == ['selftest']:
        return selftest()
    if a[:1] == ['qs'] and len(a) == 4:
        return qs(*a[1:])
    if a[:1] == ['qo0'] and len(a) == 3:
        return qo0(*a[1:])
    if a[:1] == ['qo1'] and len(a) == 4:
        return qo1(*a[1:])
    if a[:1] == ['qo2'] and len(a) == 3:
        return qo2(*a[1:])
    if a[:1] == ['report'] and len(a) in (6, 7):
        return report(*a[1:])
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
