#!/usr/bin/env python3
"""H1's checks (bench/policy_sanity/fifo_check_design_2026-11-14.md), fixed
before any run with the strict FIFO check on exists.

    fifo_check.py qf0 ORIG_DIR NEW_DIR      the same configuration?
    fifo_check.py qf1 ORIG_DIR NEW_DIR SHORT_DIR [ENDED]
                                            the run's outcome
    fifo_check.py selftest                  on the pulled ocean 4c run

QF0: NEW_DIR/config.ini equals ORIG_DIR/config.ini once ORIG_DIR's path is
read as NEW_DIR's, except `ordered=` in the L0 controllers' bufferFromL1 /
bufferToL1 sections, which must read false in the original and true in the
new run, for every L0 controller. Exit 0 = PASS, 1 = FAIL.

QF1 (only once the run's gem5 process has ended; ENDED=1 says so, as the
driver knows it):
  PANIC                 'FIFO ordering violated' in NEW_DIR/run.log; the
                        tick, buffer, delta, and whether the tick is at or
                        before SHORT_DIR's final tick (warm-up) or after
                        (window);
  COMPLETE-IDENTICAL    exited 'because a thread reached the max instruction
                        count', and NEW_DIR/stats.txt equals ORIG_DIR's line
                        for line apart from lines starting with 'host';
  COMPLETE-DIFFERENT    exited so, with other statistics (contradicts the
                        code reading: the chain stops);
  OTHER                 anything else (a time limit, another panic, no
                        stats).
Exit 0 = IDENTICAL, 2 = PANIC, 3 = DIFFERENT, 4 = OTHER, 5 = not ended.
"""
import os
import re
import shutil
import sys
import tempfile

BUF = re.compile(r'^\[system\.ruby\.l0_cntrl(\d+)\.buffer(FromL1|ToL1)\]$')
EXIT_OK = 'because a thread reached the max instruction count'
PANIC = re.compile(r'panic: FIFO ordering violated: .* name: (\S+) current time: (\d+) '
                   r'delta: (\d+) arrival_time: (\d+) last arrival_time: (\d+)')


def sections(path, orig_dir=None, new_dir=None):
    """[(section, line)] in file order; ORIG_DIR's path read as NEW_DIR's."""
    out, sec = [], None
    for ln in open(path).read().splitlines():
        if orig_dir:
            ln = ln.replace(orig_dir.rstrip('/'), new_dir.rstrip('/'))
        if ln.startswith('['):
            sec = ln
        out.append((sec, ln))
    return out


def qf0(orig_dir, new_dir, out=print):
    a = sections(os.path.join(orig_dir, 'config.ini'), orig_dir, new_dir)
    b = sections(os.path.join(new_dir, 'config.ini'))
    bad, flipped = [], set()
    if len(a) != len(b):
        bad.append(f'{len(a)} lines in the original, {len(b)} in the new run')
    for (sa, la), (sb, lb) in zip(a, b):
        if la == lb:
            if la.startswith('ordered=') and sa and BUF.match(sa):
                bad.append(f'{sa} {la}: not flipped')
            continue
        m = BUF.match(sa or '')
        if m and sa == sb and la == 'ordered=false' and lb == 'ordered=true':
            flipped.add((int(m.group(1)), m.group(2)))
            continue
        bad.append(f'{sa}: original "{la}", new "{lb}"')
    l0 = {int(BUF.match(s).group(1)) for s, _ in a if s and BUF.match(s)}
    want = {(i, k) for i in l0 for k in ('FromL1', 'ToL1')}
    if not l0:
        bad.append('no L0 controller buffers in the original')
    elif flipped != want:
        bad.append(f'flipped {len(flipped)} of {len(want)} buffers')
    for x in bad[:12]:
        out('   QF0: ' + x)
    out(f'QF0 {"PASS" if not bad else "FAIL"}: {len(flipped)} buffers false -> true over {len(l0)} L0 controllers'
        + ('' if not bad else f'; {len(bad)} other difference(s)'))
    return not bad


def final_tick(d):
    p = os.path.join(d, 'stats.txt')
    if not os.path.exists(p):
        return None
    m = re.search(r'^finalTick\s+(\d+)', open(p).read(), re.M)
    return int(m.group(1)) if m else None


def stat_lines(d):
    return [ln for ln in open(os.path.join(d, 'stats.txt')).read().splitlines() if not ln.startswith('host')]


def qf1(orig_dir, new_dir, short_dir, ended=True, out=print):
    if not ended:
        out('QF1 RUNNING')
        return 5
    log = open(os.path.join(new_dir, 'run.log'), errors='replace').read() if os.path.exists(os.path.join(new_dir, 'run.log')) else ''
    m = PANIC.search(log)
    if m:
        name, cur, delta, arr, last = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))
        st = final_tick(short_dir)
        phase = 'unknown (no short-stop finalTick)' if st is None else ('warm-up' if cur <= st else 'window')
        out(f'QF1 PANIC tick {cur} buffer {name} delta {delta} arrival {arr} last {last} '
            f'phase {phase} (short stop ends at {st})')
        return 2
    if EXIT_OK in log and os.path.exists(os.path.join(new_dir, 'stats.txt')):
        a, b = stat_lines(orig_dir), stat_lines(new_dir)
        diff = [i for i, (x, y) in enumerate(zip(a, b)) if x != y] + list(range(min(len(a), len(b)), max(len(a), len(b))))
        if not diff:
            out(f'QF1 COMPLETE-IDENTICAL: {len(a)} statistics lines equal (host lines aside); finalTick {final_tick(new_dir)}')
            return 0
        first = diff[0]
        show = (a[first] if first < len(a) else '<none>')[:120], (b[first] if first < len(b) else '<none>')[:120]
        out(f'QF1 COMPLETE-DIFFERENT: {len(diff)} of {max(len(a), len(b))} lines differ; first: "{show[0]}" / "{show[1]}"')
        return 3
    tail = [ln for ln in log.splitlines() if ln.strip()][-1:] or ['<empty run.log>']
    out(f'QF1 OTHER: no FIFO panic and no normal exit; last line: {tail[0][:160]}')
    return 4


def selftest():
    here = os.path.dirname(os.path.abspath(__file__))
    od = os.path.join(here, '..', 'simulator', 'results', 'gem5_b3', 'l2_2MB_mi150M', 'ocean_4c')
    sd = os.path.join(here, '..', 'simulator', 'results', 'gem5_b3', 'l2_2MB_mi50M', 'ocean_4c')
    if not os.path.exists(os.path.join(od, 'config.ini')):
        sys.exit(f'self-test: no {od}')
    # the original as the server holds it: its own directory written into the paths
    tmp = tempfile.mkdtemp(prefix='fifo_selftest_')
    srv_orig = '/home/harshraj/gem5_b3/l2_2MB_mi150M/ocean_4c'
    o = os.path.join(tmp, 'orig')
    os.makedirs(o)
    for f in ('config.ini', 'stats.txt', 'run.log'):
        shutil.copy(os.path.join(od, f), o)
    txt = open(os.path.join(o, 'config.ini')).read()
    txt += f'\n[system.fake.paths]\ninput={srv_orig}/barnes.in\n'      # a path holding the original directory
    open(os.path.join(o, 'config.ini'), 'w').write(txt)
    res = []

    def newrun(name, edit_ini=None, edit_stats=None, log=None):
        n = os.path.join(tmp, name)
        os.makedirs(n)
        t = txt.replace(srv_orig, n)
        sec, lines = None, []
        for ln in t.splitlines():
            if ln.startswith('['):
                sec = ln
            if ln == 'ordered=false' and BUF.match(sec or ''):
                ln = 'ordered=true'
            lines.append(ln)
        t = '\n'.join(lines) + '\n'
        if edit_ini:
            t = edit_ini(t)
        open(os.path.join(n, 'config.ini'), 'w').write(t)
        s = open(os.path.join(od, 'stats.txt')).read()
        s = re.sub(r'^(hostSeconds\s+)\S+', r'\g<1>99999.99', s, flags=re.M)
        if edit_stats:
            s = edit_stats(s)
        open(os.path.join(n, 'stats.txt'), 'w').write(s)
        open(os.path.join(n, 'run.log'), 'w').write(log if log is not None else open(os.path.join(od, 'run.log')).read())
        return n

    q = lambda *a: None

    def run_qf0(n):
        # the original's text names its server directory; it sits in o here
        return qf0_mapped(srv_orig, o, n)

    ok_same = run_qf0(newrun('same'))
    bad_extra = run_qf0(newrun('extra', edit_ini=lambda t: t.replace('size=2097152', 'size=4194304', 1)))
    bad_one = run_qf0(newrun('oneflip', edit_ini=lambda t: t.replace('ordered=true', 'ordered=false', 1)))
    res.append(('QF0 same configuration passes', ok_same is True))
    res.append(('QF0 an L2 size changed fails', bad_extra is False))
    res.append(('QF0 one buffer left unflipped fails', bad_one is False))
    # QF1
    r = qf1(o, newrun('ident'), sd, True, q)
    res.append(('QF1 identical (hostSeconds differs)', r == 0))
    r = qf1(o, newrun('diff', edit_stats=lambda s: re.sub(r'^(simInsts\s+)(\d+)', lambda m: m.group(1) + str(int(m.group(2)) + 1), s, count=1, flags=re.M)), sd, True, q)
    res.append(('QF1 one statistic differs -> DIFFERENT', r == 3))
    st = final_tick(sd)
    pan = ('src/mem/ruby/network/MessageBuffer.cc:261: panic: FIFO ordering violated: [MessageBuffer: consumer-yes [ 0x1, ]] '
           'system.ruby.l0_cntrl0.bufferFromL1 name: system.ruby.l0_cntrl0.bufferFromL1 current time: {t} delta: 500 '
           'arrival_time: {a} last arrival_time: {b}\nMemory Usage: 5000000 KBytes\n')
    lines = []
    r = qf1(o, newrun('panicw', log=pan.format(t=st + 1000, a=st + 1500, b=st + 2000)), sd, True, lines.append)
    res.append(('QF1 panic after the short stop -> PANIC, window', r == 2 and 'phase window' in lines[-1]))
    lines = []
    r = qf1(o, newrun('panicu', log=pan.format(t=1000, a=1500, b=2000)), sd, True, lines.append)
    res.append(('QF1 panic in the warm-up -> PANIC, warm-up', r == 2 and 'phase warm-up' in lines[-1]))
    r = qf1(o, newrun('other', log='src/sim/x.cc: panic: something else\n'), sd, True, q)
    res.append(('QF1 another end -> OTHER', r == 4))
    r = qf1(o, newrun('running'), sd, False, q)
    res.append(('QF1 not ended -> RUNNING', r == 5))
    shutil.rmtree(tmp)
    for name, ok in res:
        print(f'{"ok  " if ok else "FAIL"} {name}')
    good = all(ok for _, ok in res)
    print('SELF-TEST ' + ('PASSES' if good else 'FAILS') + f' ({sum(ok for _, ok in res)} of {len(res)})')
    return 0 if good else 1


def qf0_mapped(orig_text_dir, orig_dir, new_dir, out=lambda *a: None):
    """qf0 where the original's config.ini names ORIG_TEXT_DIR (its server path) but sits in ORIG_DIR."""
    a = sections(os.path.join(orig_dir, 'config.ini'), orig_text_dir, new_dir)
    tmpd = tempfile.mkdtemp(prefix='fifo_q0_')
    with open(os.path.join(tmpd, 'config.ini'), 'w') as f:
        f.write('\n'.join(ln for _, ln in a) + '\n')
    try:
        return qf0(tmpd, new_dir, out)
    finally:
        shutil.rmtree(tmpd)


def main():
    a = sys.argv[1:]
    if a == ['selftest']:
        return selftest()
    if len(a) == 3 and a[0] == 'qf0':
        return 0 if qf0(a[1], a[2]) else 1
    if len(a) in (4, 5) and a[0] == 'qf1':
        return qf1(a[1], a[2], a[3], (a[4] if len(a) == 5 else '1') == '1')
    sys.exit(__doc__)


if __name__ == '__main__':
    sys.exit(main())
