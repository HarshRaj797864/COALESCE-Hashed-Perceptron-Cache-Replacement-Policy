#!/usr/bin/env python3
"""H8 (bench/policy_sanity/h8_speed_design_2026-11-14.md): wall-clock time to
result, from logs that already exist. Reported only; no prediction, no claim.

  scripts/h8_speed.py champsim TOP [TOP ...]   one row a ChampSim run.log under each TOP
  scripts/h8_speed.py gem5 TOP [TOP ...]       one row a gem5 stats.txt under each TOP
  scripts/h8_speed.py summary ROWS             medians and ranges by simulator and core count
  scripts/h8_speed.py selftest

ChampSim row: CS <tree> <cores> <warmup> <sim> <wall s> <K instr / wall s>.
  The wall time is the largest "(Simulation time: ...)" on a "Simulation
  complete" line: ChampSim's elapsed_time() runs from program start
  (src/champsim.cc:35-37), so it covers warm-up and the measured phase.
  fmt prints a duration's %H as hours mod 24, so every time in the log, in
  file order (heartbeats included), is unwrapped: each drop adds 24 h
  (amendment 1). The
  instructions are cores x (warmup + sim), the configured counts.
gem5 row: G5 <dir> <cpus> <simInsts> <hostSeconds> <K instr / wall s>.
  The last dump's simInsts and hostSeconds (wall, "Real time elapsed on the
  host"); CPUs from config.ini beside it (the number of BaseCPU objects named
  system.cpu<k>).
Both are WALL time on a shared server at nice 19 (load 60-110 on 48 cores),
not CPU time: the controlled measurement remains speed_results_2026-10-19.md.
"""
import os
import re
import statistics
import sys
import tempfile

HMS = re.compile(r'\(Simulation time: (\d+) hr (\d+) min (\d+) sec\)')


def champsim_row(path):
    cores = wu = si = None
    wall = None
    complete = False
    last, wraps = None, 0        # amendment 1: fmt's %H on a duration is hours mod 24
    with open(path, errors='replace') as f:
        for ln in f:
            if ln.startswith('Warmup Instructions:'):
                wu = int(ln.split()[-1])
            elif ln.startswith('Simulation Instructions:'):
                si = int(ln.split()[-1])
            elif ln.startswith('Number of CPUs:'):
                cores = int(ln.split()[-1])
            elif 'ChampSim completed all CPUs' in ln:
                complete = True
            m = HMS.search(ln)
            if m:
                s = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
                if last is not None and s < last:
                    wraps += 1
                last = s
                if ln.startswith('Simulation complete CPU'):
                    s += wraps * 86400
                    wall = s if wall is None else max(wall, s)
    if not (complete and cores and wu is not None and si and wall):
        return None
    return cores, wu, si, wall, cores * (wu + si) / wall / 1000


def gem5_row(stats):
    last = {}
    with open(stats, errors='replace') as f:
        for ln in f:
            if ln.startswith('---------- Begin Simulation Statistics'):
                last = {}
            p = ln.split()
            if len(p) >= 2 and p[0] in ('simInsts', 'hostSeconds'):
                last[p[0]] = float(p[1])
    ini = os.path.join(os.path.dirname(stats), 'config.ini')
    cpus = None
    if os.path.exists(ini):
        with open(ini, errors='replace') as f:
            cpus = len({m.group(1) for m in (re.match(r'\[system\.cpu(\d+)\]$', ln.strip()) for ln in f) if m}) or None
    if not cpus or 'simInsts' not in last or not last.get('hostSeconds'):
        return None
    return cpus, int(last['simInsts']), last['hostSeconds'], last['simInsts'] / last['hostSeconds'] / 1000


def champsim(tops):
    for top in tops:
        for root, _, files in sorted(os.walk(top)):
            if 'run.log' in files:
                r = champsim_row(os.path.join(root, 'run.log'))
                rel = os.path.relpath(root, top)
                print(f'CS {rel} INCOMPLETE' if r is None else f'CS {rel} {r[0]} {r[1]} {r[2]} {r[3]} {r[4]:.1f}')


def gem5(tops):
    for top in tops:
        for root, _, files in sorted(os.walk(top)):
            if '.prev_' in root:
                continue
            if 'stats.txt' in files:
                r = gem5_row(os.path.join(root, 'stats.txt'))
                rel = os.path.relpath(root, top)
                print(f'G5 {rel} UNREAD' if r is None else f'G5 {rel} {r[0]} {r[1]} {r[2]:.0f} {r[3]:.1f}')


def summary(path):
    by = {}
    for ln in open(path):
        p = ln.split()
        if not p or p[0] not in ('CS', 'G5') or len(p) < (7 if p[0] == 'CS' else 6):
            continue
        by.setdefault((p[0], int(p[2])), []).append((float(p[-1]), float(p[-2])))
    print('sim   cores  runs  K instr / wall s: median [min, max]   wall hours: median [min, max]')
    for (sim, c), v in sorted(by.items()):
        r = [x[0] for x in v]
        h = [x[1] / 3600 for x in v]
        print(f'{"ChampSim" if sim == "CS" else "gem5":8} {c:>3}  {len(v):>4}  {statistics.median(r):8.1f} [{min(r):.1f}, {max(r):.1f}]'
              f'      {statistics.median(h):6.1f} [{min(h):.1f}, {max(h):.1f}]')


def selftest():
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, 'cs', 't', 'lru'))
    open(os.path.join(d, 'cs', 't', 'lru', 'run.log'), 'w').write(
        'Warmup Instructions: 50000000\nSimulation Instructions: 100000000\nNumber of CPUs: 4\n'
        'Heartbeat CPU 0 instructions: 1 cycles: 1 heartbeat IPC: 1 cumulative IPC: 1 (Simulation time: 00 hr 30 min 00 sec)\n'
        'Simulation complete CPU 0 instructions: 100000000 cycles: 1 cumulative IPC: 1 (Simulation time: 01 hr 00 min 00 sec)\n'
        'Simulation complete CPU 1 instructions: 100000000 cycles: 1 cumulative IPC: 1 (Simulation time: 02 hr 30 min 00 sec)\n'
        'ChampSim completed all CPUs\n')
    os.makedirs(os.path.join(d, 'g5', 'x'))
    open(os.path.join(d, 'g5', 'x', 'stats.txt'), 'w').write(
        '---------- Begin Simulation Statistics ----------\nsimInsts 1 #\nhostSeconds 9 #\n'
        '---------- Begin Simulation Statistics ----------\nsimInsts 720000000 #\nhostSeconds 3600 #\n')
    open(os.path.join(d, 'g5', 'x', 'config.ini'), 'w').write('[system.cpu0]\n[system.cpu0.dcache]\n[system.cpu1]\n[system.cpu2]\n')
    ok = True
    r = champsim_row(os.path.join(d, 'cs', 't', 'lru', 'run.log'))
    if r != (4, 50000000, 100000000, 9000, 4 * 150_000_000 / 9000 / 1000):   # the largest complete line
        ok = False
        print('selftest: champsim row', r)
    g = gem5_row(os.path.join(d, 'g5', 'x', 'stats.txt'))
    if g != (3, 720000000, 3600.0, 200.0):   # the last dump; system.cpu<k> sections only
        ok = False
        print('selftest: gem5 row', g)
    os.makedirs(os.path.join(d, 'cs', 'w', 'lru'))
    open(os.path.join(d, 'cs', 'w', 'lru', 'run.log'), 'w').write(
        'Warmup Instructions: 0\nSimulation Instructions: 100\nNumber of CPUs: 2\n'
        'Heartbeat CPU 0 instructions: 1 cycles: 1 heartbeat IPC: 1 cumulative IPC: 1 (Simulation time: 23 hr 00 min 00 sec)\n'
        'Heartbeat CPU 1 instructions: 1 cycles: 1 heartbeat IPC: 1 cumulative IPC: 1 (Simulation time: 00 hr 10 min 00 sec)\n'
        'Heartbeat CPU 0 instructions: 1 cycles: 1 heartbeat IPC: 1 cumulative IPC: 1 (Simulation time: 22 hr 00 min 00 sec)\n'
        'Simulation complete CPU 0 instructions: 100 cycles: 1 cumulative IPC: 1 (Simulation time: 01 hr 00 min 00 sec)\n'
        'ChampSim completed all CPUs\n')
    r = champsim_row(os.path.join(d, 'cs', 'w', 'lru', 'run.log'))
    if r is None or r[3] != 2 * 86400 + 3600:   # two drops: 23 h -> 0:10, 22 h -> 1 h
        ok = False
        print('selftest: wrapped row', r)
    open(os.path.join(d, 'cs', 't', 'lru', 'run.log'), 'a').write('')
    with open(os.path.join(d, 'cs', 't', 'lru', 'run.log')) as f:
        txt = f.read().replace('ChampSim completed all CPUs\n', '')
    open(os.path.join(d, 'cs', 't', 'lru', 'run.log'), 'w').write(txt)
    if champsim_row(os.path.join(d, 'cs', 't', 'lru', 'run.log')) is not None:
        ok = False
        print('selftest: an incomplete run gave a row')
    print('selftest PASS' if ok else 'selftest FAIL')
    return 0 if ok else 1


def main(a):
    if a[:1] == ['champsim'] and len(a) > 1:
        return champsim(a[1:])
    if a[:1] == ['gem5'] and len(a) > 1:
        return gem5(a[1:])
    if a[:1] == ['summary'] and len(a) == 2:
        return summary(a[1])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]) or 0)
