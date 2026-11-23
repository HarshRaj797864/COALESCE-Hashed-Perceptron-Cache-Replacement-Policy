#!/usr/bin/env python3
"""KL1 of K2 step 3 (bench/policy_sanity/k2_sharing_gap_design_2026-11-17.md,
amendment 2): the lead limit on two synthetic threads with no sync records.

  lead_micro.py run BIN WORK
      BIN   a ChampSim binary with sync_lead_limit
      WORK  a scratch directory (two ~160 MB traces are written there)
  lead_micro.py judge WORK
      judges the three logs a 'run' left in WORK, without running anything

Thread 0 never touches memory (no registers, no operands): it runs at the
core's width. Thread 1 does one load every 50 records, each load's address
register written by the previous load (a dependent chain of misses over
1 GiB): it runs far slower. No sync records, so the replay is not active.

Three runs, warm-up 0, 1,500,000 instructions a core:
  KL1a  sync_lead_limit 100,000: core 0's max lead <= 100,000 + 358 (ROB 352 +
        dispatch width 6); core 0's lead-held cycles > 0; core 1's 0; both
        complete
  KL1b  sync_lead_limit 10^12 (on, never reached): core 0's max lead > 1,000,000
        (the case discriminates); no lead-held cycle
  KL1c  off: every line of KL1b's log but the LEAD lines and the
        simulation-time stamps is identical (a limit never reached changes
        nothing)
"""
import os
import random
import re
import struct
import subprocess
import sys

N = 2_500_000            # records a trace (no wrap at 1.5 M)
SIM = 1_500_000
REC = struct.Struct('<QBB2B4B2Q4Q')   # ChampSim's input_instr, 64 bytes
assert REC.size == 64


def write_traces(work):
    rng = random.Random(20261117)
    t0, t1 = os.path.join(work, 'fast.champsimtrace'), os.path.join(work, 'slow.champsimtrace')
    if not os.path.exists(t0):
        with open(t0 + '.part', 'wb') as f:
            buf = bytearray()
            for i in range(N):
                buf += REC.pack(0x400000 + 4 * (i % 1024), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                if len(buf) > 1 << 22:
                    f.write(buf)
                    buf.clear()
            f.write(buf)
        os.rename(t0 + '.part', t0)
    if not os.path.exists(t1):
        with open(t1 + '.part', 'wb') as f:
            buf = bytearray()
            for i in range(N):
                ip = 0x500000 + 4 * (i % 1024)
                if i % 50 == 0:   # load r5 <- [r5]: a dependent miss
                    addr = 0x10000000 + 64 * rng.randrange(1 << 24)
                    buf += REC.pack(ip, 0, 0, 5, 0, 5, 0, 0, 0, 0, 0, addr, 0, 0, 0)
                else:
                    buf += REC.pack(ip, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                if len(buf) > 1 << 22:
                    f.write(buf)
                    buf.clear()
            f.write(buf)
        os.rename(t1 + '.part', t1)
    return t0, t1


def config(work, lead):
    here = os.path.dirname(os.path.abspath(__file__))
    mk = os.path.join(here, '..', 'simulator', 'scripts', 'make_config.py')
    path = os.path.join(work, f'cfg_{lead}.json')
    cmd = [sys.executable, mk, '--policy', 'lru', '--cores', '2', '--regime', 'shared', '--private-coherence', '2',
           '--sync-lock-word', 'request', '-o', path]
    if lead:
        cmd[-2:-2] = ['--sync-lead-limit', str(lead)]
    subprocess.run(cmd, check=True)
    return path


def run_one(binary, work, lead, traces):
    log = os.path.join(work, f'run_{lead}.log')
    with open(log, 'w') as f:
        rc = subprocess.run([binary, '--config', config(work, lead), '--warmup-instructions', '0',
                             '--simulation-instructions', str(SIM), *traces], stdout=f, stderr=subprocess.STDOUT).returncode
    with open(log + '.rc', 'w') as f:
        f.write(f'{rc}\n')
    return rc, open(log).read()


def old_log(work, lead):
    log = os.path.join(work, f'run_{lead}.log')
    rcf = log + '.rc'
    rc = int(open(rcf).read()) if os.path.exists(rcf) else (0 if 'ChampSim completed all CPUs' in open(log).read() else 1)
    return rc, open(log).read()


def completed(txt):
    """both cores finished their simulation phase (the 'Warmup complete CPU' lines are not counted;
    2026-11-17: the first checker counted 'complete CPU' and so read 4 for 2)"""
    return len(re.findall(r'^Simulation complete CPU \d+ ', txt, re.M)) == 2 and 'ChampSim completed all CPUs' in txt


def leads(txt):
    return {int(m.group(1)): (int(m.group(2)), int(m.group(3)), int(m.group(4)))
            for m in re.finditer(r'^CPU (\d+) LEAD HOLDS: cycles measured (\d+) warmup (\d+); max lead (\d+)$', txt, re.M)}


def strip(txt):
    out = []
    for ln in txt.splitlines():
        if ln.startswith('SYNC LEAD LIMIT') or ' LEAD HOLDS:' in ln:
            continue
        out.append(re.sub(r'\(Simulation time: [^)]*\)', '(time)', ln))
    return out


def run(binary, work, judge_only=False):
    os.makedirs(work, exist_ok=True)
    if judge_only:
        get = lambda lead: old_log(work, lead)
    else:
        traces = write_traces(work)
        get = lambda lead: run_one(binary, work, lead, traces)
    ok = True

    def say(name, cond, detail):
        nonlocal ok
        ok &= bool(cond)
        print(f'{name} {"holds" if cond else "FAILS"}: {detail}')

    rc_a, a = get(100_000)
    la = leads(a)
    say('KL1a', rc_a == 0 and 'SYNC LEAD LIMIT: 100000 instructions' in a and set(la) == {0, 1}
        and la[0][2] <= 100_000 + 358 and la[0][0] + la[0][1] > 0 and la[1][0] + la[1][1] == 0
        and completed(a),
        f'rc {rc_a}; core 0 held {la.get(0, ("-",) * 3)[0]} cycles, max lead {la.get(0, ("-",) * 3)[2]} (bound {100_000 + 358}); '
        f'core 1 held {la.get(1, ("-",) * 3)[0]}')
    rc_b, b = get(10 ** 12)
    lb = leads(b)
    say('KL1b', rc_b == 0 and completed(b) and set(lb) == {0, 1} and lb[0][2] > 1_000_000 and all(v[0] + v[1] == 0 for v in lb.values()),
        f'rc {rc_b}; core 0 max lead {lb.get(0, ("-",) * 3)[2]} (over 1,000,000 needed); held cycles {[v[0] + v[1] for v in lb.values()]}')
    rc_c, c = get(0)
    sb, sc = strip(b), strip(c)
    diff = [(x, y) for x, y in zip(sb, sc) if x != y]
    say('KL1c', rc_c == 0 and completed(c) and 'LEAD' not in c and len(sb) == len(sc) and not diff,
        f'rc {rc_c}; {len(sc)} lines, {len(diff)} differ (time stamps aside)' + (f'; first: {diff[0]}' if diff else ''))
    for name, txt in (('KL1a', a), ('KL1c', c)):
        cyc = re.findall(r'^Simulation complete CPU (\d+) instructions: (\d+) cycles: (\d+)', txt, re.M)
        print(f'   {name} reported: ' + '; '.join(f'CPU {x} {int(y):,} instructions in {int(z):,} cycles' for x, y, z in cyc))
    print('KL1 PASS' if ok else 'KL1 FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == 'run':
        sys.exit(run(sys.argv[2], sys.argv[3]))
    if len(sys.argv) == 3 and sys.argv[1] == 'judge':
        sys.exit(run(None, sys.argv[2], judge_only=True))
    print(__doc__)
    sys.exit(1)
