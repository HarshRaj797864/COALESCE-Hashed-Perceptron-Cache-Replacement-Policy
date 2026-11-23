#!/usr/bin/env python3
"""H6(b) (bench/policy_sanity/h6b_attribution_design_2026-11-14.md): each
store-time sharing event attributed (requester, holders, instruction kind), in
gem5 from its ProtocolTrace and in ChampSim from its coherence event log.

  h6b_attr.py gem5 TRACE [--traced 1,2,3,4] [--repl] > G5EV
      (--repl, QP only: also S / L / R tick line core for L1 store and load issues and replacements)
      TRACE: the ProtocolTrace through h6b_server.sh's awk (xz or plain). One line an event:
        E tick line requester state kind holders rmwline stale
      kind: store | rmw | - (no Seq Begin found); holders: c,c,... or -; stale: holders whose
      L1 had no copy (Inv in I, IM, IS, IS_I); and summary lines (# ...): anomalies, RMW lines
  h6b_attr.py qp CASE G5EV               the micro's hand pattern (QP)
  h6b_attr.py rmwips TRACE... --warmup W --sim S > RMWIPS
      IP <hex> for every RMW record's ip in the first (W + S) x 1.05 records;
      LINE <hex> for the lines (address >> 6) RMW records touch in [W, W + S]
  h6b_attr.py champsim EVENTLOG RMWIPS RUNLOG > CSEV
      E cycle vline cpu kind holders   (measured G events with a gem5-rule holder)
  h6b_attr.py qg1 STATS_A STATS_B        the two stats files equal, host statistics aside
  h6b_attr.py report PROGRAM G5EV CSEV STATS50 STATS150 ORIG150 QE0FILE
  h6b_attr.py selftest
"""
import collections
import os
import re
import subprocess
import sys
import tempfile

# the scored numbers (the note's table; canneal from gem5_b3_rows_v7 and lock_fix_score_v1)
PROGRAMS = {
    'fluidanimate': dict(G=43879, Ig=386005066, C=18744, Ic=412469348, traced=(1, 2, 3, 4)),
    'vips': dict(G=3242, Ig=398703787, C=1031, Ic=411142861, traced=(3, 4, 5, 6)),
    'canneal': dict(G=89307, Ig=399351235, C=91376, Ic=401531433, traced=(1, 2, 3, 4)),
}
L2 = 'system.ruby.L2Cache_Controller.'
RMW_KINDS = ('rmw',)
SYNC_MAGIC = 0x53594E4353594E43


def opener(path):
    if path.endswith('.xz'):
        p = subprocess.Popen(['xz', '-dc', path], stdout=subprocess.PIPE, text=True, errors='replace')
        return p.stdout
    return open(path, errors='replace')


# ------------------------------------------------------------------ gem5
# the L2's request transitions that pop the request (MESI_Two_Level-L2cache.sm, which MESI_Three_Level
# includes); every other state stalls the request and prints it again when it is woken
POP = {('L1_GETX', 'NP'), ('L1_GETX', 'SS'), ('L1_GETX', 'M'), ('L1_GETX', 'MT'), ('L1_UPGRADE', 'SS')}
STALL = {'SS_MB', 'MT_MB', 'MT_IIB', 'MT_IB', 'MT_SB', 'I_F', 'MT_F', 'I_FF', 'IS', 'ISS', 'IM',
         'I_I', 'S_I', 'MT_I', 'MCT_I', 'M_I'}
# L1 states in which an Inv finds no copy (a sharer the L2 still lists): the holder is "stale"
STALE = {'I', 'IM', 'IS', 'IS_I'}


def addr_of(p, i=5):
    """The byte address in field i. gem5 25.1 prints every address through printAddress
    (Address.cc:76) as "[0xADDR, line 0xLINE]", so field i is "[0xADDR,"; the pipe's normalised
    Seq lines (and older forms) hold a bare 0xADDR. Amendment 2."""
    return int(p[i].strip('[,]'), 16)


def gem5(path, traced, out=sys.stdout, repl=False):
    """One transaction a popped L2 GETX / UPGRADE. The L2 blocks the line until the requester
    unblocks, so the requester is the core whose L1 next completes IM > M or SM > M on the line.
    An event = a transaction popped as L1_GETX in SS or MT (what b3_score.py counts)."""
    lastreq = {}                                           # (core, line) -> its latest ST request {'kind'}
    prevreq = {}                                           # core -> (addr, request) of its latest ST Seq Begin
    issued = {}                                            # (core, line) -> request of its L1 issue (GETX or UPGRADE)
    fifo = collections.defaultdict(collections.deque)      # line -> cores in L1 issue order (cross-check only)
    open_tx, events = {}, []
    rmw_lines, rmw_cores = set(), collections.defaultdict(set)
    an = collections.Counter()
    raw = []                                               # repl (QP only): (tick, op, line, core, state) of L1 store / load issues and replacements
    n = 0

    for ln in opener(path):
        p = ln.split()
        if len(p) < 6 or not p[0].isdigit():
            continue
        if p[2] == 'Seq':
            # the pipe's awk keeps each ST Seq Begin and marks one whose core's previous request
            # (any type) was an ST at the same address as "Seq Pair": the write of an RMW instruction
            if len(p) < 7 or p[-1] != 'ST' or p[3] not in ('Begin', 'Pair') or not p[5].lstrip('[').startswith('0x'):
                continue
            core, addr = int(p[1]), addr_of(p)
            line = addr >> 6
            if p[3] == 'Begin':
                rq = {'kind': 'store'}
                prevreq[core] = (addr, rq)
                lastreq[(core, line)] = rq
            else:
                pa = prevreq.get(core)
                if pa and pa[0] == addr:
                    pa[1]['kind'] = 'rmw'
                    lastreq[(core, line)] = pa[1]
                    rmw_lines.add(line)
                    rmw_cores[line].add(core)
                else:
                    an['pairs without their first request'] += 1
            continue
        if p[2] not in ('L1Cache', 'L2Cache') or ln.rstrip().endswith('Stall'):
            continue
        n += 1
        tick, ver, ev, st = int(p[0]), int(p[1]), p[3], p[4]
        cur, _, nxt = st.partition('>')
        line = addr_of(p) >> 6
        if p[2] == 'L1Cache' and repl:
            if ev == 'Store' and ((cur == 'I' and nxt == 'IM') or (cur in ('S', 'SS') and nxt == 'SM')):
                raw.append((tick, 'S', line, ver, cur))
            elif ev == 'Load' and cur == 'I' and nxt == 'IS':
                raw.append((tick, 'L', line, ver, cur))
            elif ev == 'L1_Replacement':
                raw.append((tick, 'R', line, ver, cur))
        if p[2] == 'L1Cache':
            if ev == 'Store' and ((cur == 'I' and nxt == 'IM') or (cur in ('S', 'SS') and nxt == 'SM')):
                if (ver, line) in issued:
                    an['issues while one is pending'] += 1
                issued[(ver, line)] = lastreq.get((ver, line))
                fifo[line].append(ver)
            elif ev in ('Inv', 'Fwd_GETX', 'L0_Invalidate_Else') and line in open_tx:
                tx = open_tx[line]
                (tx['stale'] if ev == 'Inv' and cur in STALE else tx['live']).add(ver)
            elif cur in ('IM', 'SM') and nxt == 'M':
                tx = open_tx.pop(line, None)
                rq = issued.pop((ver, line), None)
                if tx is None:
                    an['completions without a transaction'] += 1    # its L2 transition came before the trace
                    continue
                tx['req'], tx['rq'] = ver, rq     # its kind is read at the end: an RMW's Pair comes after this
                if ver in tx['live'] | tx['stale']:
                    an['requester among holders'] += 1
                tx['live'].discard(ver)
                tx['stale'].discard(ver)
                if tx['event']:
                    events.append(tx)
                    if tx['fifo'] is not None and tx['fifo'] != ver:
                        an['events the issue order pairs differently'] += 1
        else:
            if ev not in ('L1_GETX', 'L1_UPGRADE'):
                continue
            if (ev, cur) not in POP:
                if cur not in STALL:
                    an['L2 request transitions in an unlisted state'] += 1
                continue
            old = open_tx.pop(line, None)
            if old is not None and old['event']:
                an['events unpaired'] += 1
            q = fifo[line]
            if not q:
                an['L2 requests without an L1 issue in the trace'] += 1
            open_tx[line] = dict(tick=tick, line=line, state=cur, event=(ev == 'L1_GETX' and cur in ('SS', 'MT')),
                                 fifo=q.popleft() if q else None, live=set(), stale=set(), req=None, rq=None)
    an['events unpaired'] += sum(1 for tx in open_tx.values() if tx['event'])
    an['issues left pending'] = len(issued)
    for e in events:
        e['kind'] = e['rq']['kind'] if e['rq'] else None
        e['holders'] = e['live'] | e['stale']
        e['stale'] -= e['live']
        if not e['holders']:
            an['events without a holder'] += 1
        if e['kind'] is None:
            an['events without an instruction'] += 1
    print(f'# h6b_attr.py gem5 {path}: {n} L1/L2 transition lines; {len(events)} events (SS/MT L1_GETX, paired); traced {",".join(map(str, traced))}', file=out)
    for k in ANOMALIES + REPORTED:
        print(f'# anomaly {k} {an[k]}', file=out)
    print(f'# rmw_lines {len(rmw_lines)}', file=out)
    contended = sum(1 for e in events if e['kind'] == 'rmw' and len(rmw_cores.get(e['line'], ())) >= 2)
    print(f'# RMW events on lines with RMWs from two or more cores {contended}', file=out)
    for e in sorted(events, key=lambda e: e['tick']):
        h = ','.join(map(str, sorted(e['holders']))) or '-'
        print(f'E {e["tick"]} {e["line"]:x} {e["req"]} {e["state"]} {e["kind"] or "-"} {h} {int(e["line"] in rmw_lines)} {len(e["stale"])}', file=out)
    for t, op, line, c, cs in raw:
        print(f'{op} {t} {line:x} {c} {cs}', file=out)
    return events, an


# gated (the 1% rule) and reported counts of the parser
ANOMALIES = ('events unpaired', 'events without a holder', 'events without an instruction')
REPORTED = ('events the issue order pairs differently', 'requester among holders', 'completions without a transaction',
            'L2 requests without an L1 issue in the trace', 'L2 request transitions in an unlisted state',
            'issues while one is pending', 'issues left pending', 'pairs without their first request')


def read_ev(path):
    head, ev = {}, []
    for ln in open(path):
        if ln.startswith('# anomaly '):
            q = ln[len('# anomaly '):].rsplit(None, 1)
            head[q[0]] = int(q[1])
        elif ln.startswith('# ') and ' events (' in ln:
            head['events'] = int(re.search(r'; (\d+) events', ln).group(1))
        elif ln.startswith('# RMW events on lines with RMWs from two or more cores'):
            head['contended'] = int(ln.split()[-1])
        elif ln[:2] in ('S ', 'L ', 'R '):
            p = ln.split()
            head.setdefault('raw', []).append((int(p[1]), p[0], p[2], int(p[3]), p[4] if len(p) > 4 else '-'))
        elif ln.startswith('E '):
            p = ln.split()
            ev.append(dict(t=int(p[1]), line=p[2], req=int(p[3]), state=p[4], kind=p[5],
                           holders=() if p[6] == '-' else tuple(int(x) for x in p[6].split(',')), rmwline=p[7] == '1',
                           stale=int(p[8]) if len(p) > 8 else 0))
    return head, ev


# ------------------------------------------------------------------ QP
# L1 states whose replacement the L2 sees (a PUTX: it forgets the core); a replacement from S / SS
# is silent (MESI_Two_Level-L1cache.sm), so the L2 still lists the core and an Inv finds no copy (stale)
EXCL = {'E', 'EE', 'M', 'MM'}


def qp(case, path, kinds=True):
    """QP (amendment 2): each round's events must equal the hand sequence's exactly: requester,
    holders, kind and the number of stale holders. The micro's caches are small, so a holder's L1 may
    replace the line before the next request. From E / M (a PUTX) the L2 forgets the holder: that
    hand-over finds no other holder and is, by definition, no event, so it is removed from the
    expected list. From S (silent) the L2 still lists the holder: it stays, as a stale holder. Both
    are read from the raw trace (gem5 ... --repl): the holder's L1_Replacement of the line between its
    own store issue (or load, for readers) and the requester's store issue. A round is found by its
    line's store issues: exactly A, B, A, B (ping-pong; A = j % 4, B = (j + 1) % 4), or exactly D after
    loads by A, B and C (readers). A round with no expected event left fails. kinds=False only in a
    check of traces without Seq lines."""
    want = {'pp_store': 'store', 'pp_lock': 'rmw', 'pp_rmw': 'rmw', 'readers': 'store'}[case]
    head, ev = read_ev(path)
    raw = collections.defaultdict(list)
    for t, op, line, c, cs in head.get('raw', []):
        raw[line].append((t, op, c, cs))
    by = collections.defaultdict(list)
    for e in ev:
        by[e['line']].append(e)
    rounds, removed, stale = collections.Counter(), collections.Counter(), collections.Counter()

    def gone(ops, c, t0, t1):
        """None if c kept the line from t0 to t1; 'excl' if it replaced it from E / M (the L2 forgot
        it); 'shared' if only silently (the L2 still lists it)."""
        r = [cs for t, op, cc, cs in ops if op == 'R' and cc == c and t0 < t < t1]
        return None if not r else ('excl' if any(x in EXCL for x in r) else 'shared')

    for line, ops in raw.items():
        ops.sort()
        st = [(t, c) for t, op, c, _ in ops if op == 'S']
        for j in range(4):
            A, B, C, D = j % 4, (j + 1) % 4, (j + 2) % 4, (j + 3) % 4
            exp, rm, ns = [], 0, 0
            if case == 'readers':
                if [c for _, c in st] != [D]:
                    continue
                ts = st[0][0]
                loads = {c: max(t for t, op, cc, _ in ops if op == 'L' and cc == c and t < ts)
                         for c in (A, B, C) if any(op == 'L' and cc == c and t < ts for t, op, cc, _ in ops)}
                if set(loads) != {A, B, C}:
                    continue
                g = {c: gone(ops, c, loads[c], ts) for c in (A, B, C)}
                h = tuple(sorted(c for c in (A, B, C) if g[c] != 'excl'))
                rm, ns = 3 - len(h), sum(1 for c in h if g[c] == 'shared')
                exp = [(D, h, ns)] if h else []
            else:
                if [c for _, c in st] != [A, B, A, B]:
                    continue
                for k in range(1, 4):
                    (th, ch), (tr, cr) = st[k - 1], st[k]
                    g = gone(ops, ch, th, tr)
                    if g == 'excl':
                        rm += 1
                    else:
                        ns += g == 'shared'
                        exp.append((cr, (ch,), int(g == 'shared')))
            got = [(e['req'], tuple(sorted(e['holders'])), e['kind'], e['stale']) for e in sorted(by.get(line, []), key=lambda e: e['t'])]
            if not kinds:
                got = [(g[0], g[1], want, g[3]) for g in got]
            if exp and got == [(r, h, want, n) for r, h, n in exp]:
                rounds[j] += 1
                removed[j] += rm
                stale[j] += ns
    ok = all(rounds[j] >= 1 for j in range(4))
    print(f'QP {case}: rounds 0-3 matching the hand sequence exactly: {[rounds[j] for j in range(4)]}; holders removed '
          f'(replaced from E / M first) {[removed[j] for j in range(4)]}; stale holders (replaced from S) {[stale[j] for j in range(4)]}; '
          f'{len(by)} lines with events, {len(ev)} events{"" if kinds else " (kinds not checked)"} -> {"holds" if ok else "FAILS"}')
    return 0 if ok else 1


# ------------------------------------------------------------------ ChampSim
def rmwips(paths, warmup, sim):
    import numpy as np
    dt = np.dtype([('ip', '<u8'), ('br', 'u1'), ('bt', 'u1'), ('dr', 'u1', 2), ('sr', 'u1', 4), ('dm', '<u8', 2), ('sm', '<u8', 4)])
    assert dt.itemsize == 64
    limit = int((warmup + sim) * 1.05)
    ips, lines = set(), set()
    for path in paths:
        f = subprocess.Popen(['xz', '-dc', path], stdout=subprocess.PIPE).stdout if path.endswith('.xz') else open(path, 'rb')
        pos = 0
        while pos < limit:
            buf = f.read(64 * min(4_000_000, limit - pos))
            if not buf:
                break
            r = np.frombuffer(buf[:len(buf) - len(buf) % 64], dtype=dt)
            sync = r['dm'][:, 1] == SYNC_MAGIC
            d0 = r['dm'][:, 0]
            rmw = (d0 != 0) & ~sync & ((d0 == r['sm'][:, 0]) | (d0 == r['sm'][:, 1]) | (d0 == r['sm'][:, 2]) | (d0 == r['sm'][:, 3]))
            ips.update(int(x) for x in np.unique(r['ip'][rmw]))
            idx = np.arange(pos, pos + len(r))
            inwin = rmw & (idx >= warmup) & (idx < warmup + sim)
            lines.update(int(x) for x in np.unique(d0[inwin] >> 6))
            pos += len(r)
        print(f'# {path}: {pos} records read', file=sys.stderr)
    print(f'# h6b_attr.py rmwips: {len(ips)} RMW ips, {len(lines)} RMW lines in the measured span')
    for x in sorted(ips):
        print(f'IP {x:x}')
    for x in sorted(lines):
        print(f'LINE {x:x}')


def champsim(evlog, rmwf, runlog, out=sys.stdout):
    ips, lines = set(), set()
    for ln in open(rmwf):
        p = ln.split()
        if len(p) == 2 and p[0] == 'IP':
            ips.add(int(p[1], 16))
        elif len(p) == 2 and p[0] == 'LINE':
            lines.add(int(p[1], 16))
    m = re.search(r'^LLC COHERENCE DIR RFO GEM5-RULE EVENTS.*?(\d+)$', open(runlog, errors='replace').read(), re.M)
    want = int(m.group(1)) if m else None
    ev = []
    for ln in opener(evlog):
        p = ln.split()
        if len(p) < 13 or p[0] != 'G' or p[3] != '0':
            continue
        g5 = int(p[12], 16)
        if not g5:
            continue
        ip, vline = int(p[6], 16), int(p[7], 16)
        hold = [w for w in range(64) if g5 >> w & 1]
        ev.append((int(p[2]), vline, int(p[4]), 'rmw' if ip in ips else 'store', hold, int(vline in lines)))
    print(f'# h6b_attr.py champsim {evlog}: {len(ev)} events; run log {want}; QC0 {"holds" if want == len(ev) else "FAILS"}', file=out)
    for c, v, cpu, k, h, rl in ev:
        print(f'E {c} {v:x} {cpu} - {k} {",".join(map(str, h))} {rl}', file=out)


# ------------------------------------------------------------------ checks and readings
def stats(path):
    d = {}
    for ln in open(path, errors='replace'):
        p = ln.split()
        if len(p) >= 2 and not ln.startswith('-'):
            d[p[0]] = p[1]
    return d


def qg1(a, b):
    x, y = stats(a), stats(b)
    diff = [k for k in set(x) | set(y) if not k.startswith('host') and x.get(k) != y.get(k)]
    print(f'QG1 {"holds" if not diff else "FAILS"}: {len(diff)} statistics differ (host statistics aside)' + (f'; e.g. {", ".join(sorted(diff)[:5])}' if diff else ''))
    return 0 if not diff else 1


def r(c, s, g):
    return c * s / g if g else float('nan')


def report(prog, g5f, csf, s50, s150, orig, qe0f, out=None):
    P = PROGRAMS[prog]
    say = (out or []).append if out is not None else print
    s = P['Ig'] / P['Ic']
    gh, gev = read_ev(g5f)
    csl = open(csf).readline()
    cev = read_ev(csf)[1]
    a, b = stats(s50), stats(s150)
    win = sum(int(b.get(L2 + x + '.L1_GETX', 0)) - int(a.get(L2 + x + '.L1_GETX', 0)) for x in ('SS', 'MT'))
    G = len(gev)
    qg0 = abs(G + gh.get('events unpaired', 0) - win) <= 0.001 * win
    q1 = qg1_quiet(orig, s150)
    qe0 = open(qe0f).readline().startswith('QE0 HOLDS')   # h6_lockreq.py qe0's own words
    qc0 = 'QC0 holds' in csl
    say(f'== H6(b) {prog}: gem5 events {G} paired (+ {gh.get("events unpaired", 0)} unpaired) against the stats window {win}; QG0 {"holds" if qg0 else "FAILS"}; '
        f'QG1 {"holds" if q1 else "FAILS (a rerun, not the scored run)"}; QE0 {"holds" if qe0 else "FAILS"}; QC0 {"holds" if qc0 else "FAILS"}')
    anom = gh.get('events unpaired', 0) + gh.get('events without a holder', 0) + gh.get('events without an instruction', 0)
    say(f'   anomalies: unpaired {gh.get("events unpaired", 0)}, no holder {gh.get("events without a holder", 0)}, '
        f'no instruction {gh.get("events without an instruction", 0)} = {100 * anom / max(win, 1):.2f}% of the window (gate 1%)')
    if not (qg0 and qe0 and qc0) or anom > 0.01 * win:
        say('   READINGS NOT MADE (a check above failed)')
        return None
    C = len(cev)
    tr = set(P['traced'])
    gu = [e for e in gev if e['req'] not in tr or any(h not in tr for h in e['holders'])]
    gu_ids = {id(e) for e in gu}
    gt = [e for e in gev if id(e) not in gu_ids]
    rA = r(C, s, G - len(gu))
    say(f'   C {C} (scored {P["C"]}), G {G} (scored {P["G"]}), s {s:.4f}; R_g5 on these {r(C, s, G):.3f}')
    say(f'   Step 1: G_u {len(gu)} events with an untraced CPU ({len([e for e in gu if e["req"] not in tr])} as requester); '
        f'C x s / (G - G_u) = {rA:.3f} -> {"A1" if rA >= 0.5 else "A2"}')
    kinds = collections.Counter('rmw' if e['kind'] in RMW_KINDS else e['kind'] for e in gt)
    ck = collections.Counter(e['kind'] for e in cev)
    rs, rr = r(ck['store'], s, kinds['store']), r(ck['rmw'], s, kinds['rmw'])
    say(f'   Step 2 (traced only): gem5 store {kinds["store"]}, RMW {kinds["rmw"]}, no instruction {kinds["-"]}; '
        f'ChampSim store {ck["store"]}, RMW {ck["rmw"]}')
    k = 'K1' if 0.5 <= rs <= 2 and rr < 0.5 else 'K2' if rs < 0.5 else 'K3'
    say(f'   R_store {rs:.3f}, R_RMW {rr:.3f} -> {k}')
    ctrl = None
    if prog == 'canneal':
        cl = [(name, g, c) for name, g, c in (('store', kinds['store'], ck['store']), ('RMW', kinds['rmw'], ck['rmw'])) if g >= 100]
        ctrl = all(0.5 <= r(c, s, g) <= 2 for _, g, c in cl)
        say(f'   CONTROL: classes with >= 100 gem5 events: ' + ', '.join(f'{n} R {r(c, s, g):.3f}' for n, g, c in cl) + f' -> {"holds" if ctrl else "FAILS"}')
    # reported
    gl = collections.Counter(e['line'] for e in gev)
    cl_ = collections.Counter(e['line'] for e in cev)
    top = lambda cnt: sum(v for _, v in cnt.most_common(10)) / max(sum(cnt.values()), 1)
    say(f'   lines: gem5 {len(gl)} distinct, top 10 {100 * top(gl):.1f}%; ChampSim {len(cl_)} distinct, top 10 {100 * top(cl_):.1f}%')
    say(f'   on lines an RMW touches: gem5 {sum(e["rmwline"] for e in gt)} of {len(gt)}; ChampSim {sum(e["rmwline"] for e in cev)} of {C}')
    say(f'   requesters: gem5 {dict(sorted(collections.Counter(e["req"] for e in gev).items()))}; ChampSim {dict(sorted(collections.Counter(e["req"] for e in cev).items()))}')
    say(f'   holders per event: gem5 {dict(sorted(collections.Counter(len(e["holders"]) for e in gev).items()))}; '
        f'ChampSim {dict(sorted(collections.Counter(len(e["holders"]) for e in cev).items()))}')
    say(f'   gem5 RMW events on lines with RMWs from two or more cores: {gh.get("contended", 0)}')
    say(f'   gem5 events whose every holder was stale (no copy): {sum(1 for e in gev if e["holders"] and e["stale"] == len(e["holders"]))}; '
        f'with some stale holder: {sum(1 for e in gev if e["stale"])}')
    say('   parser counts: ' + ', '.join(f'{k} {gh.get(k, 0)}' for k in REPORTED))
    return dict(A='A1' if rA >= 0.5 else 'A2', K=k, control=ctrl)


def qg1_quiet(a, b):
    x, y = stats(a), stats(b)
    return not [k for k in set(x) | set(y) if not k.startswith('host') and x.get(k) != y.get(k)]


# ------------------------------------------------------------------ selftest
TR = """\
      100   0    L1Cache               Store      I>IM     0x1000
      101   0    L2Cache             L1_GETX     NP>IM     0x1000
      102   0    L1Cache       Data_all_Acks     IM>M      0x1000
      140   0        Seq               Begin       >       0x2004 ST
      141   0        Seq                Pair       >       0x2004 ST
      150   1    L1Cache               Store      I>IM     0x1000
      151   0    L2Cache             L1_GETX     MT>MT_MB  0x1000
      152   0    L1Cache            Fwd_GETX     MM>I      0x1000
      153   1    L1Cache       Data_all_Acks     IM>M      0x1000
      160   2        Seq               Begin       >       0x1008 ST
      161   2    L1Cache               Store      I>IM     0x1000
      162   0    L2Cache             L1_GETX     MT>MT_MB  0x1000 Resource Stall
      163   0    L2Cache             L1_GETX     MT>MT_MB  0x1000
      164   1    L1Cache            Fwd_GETX     MM>I      0x1000
      165   2    L1Cache       Data_all_Acks     IM>M      0x1000
      166   2        Seq                Pair       >       0x1008 ST
      170   3        Seq               Begin       >       0x2010 ST
      171   3    L1Cache               Store      I>IM     0x2000
      172   0    L2Cache             L1_GETX     SS>SS_MB  0x2000
      173   1    L1Cache                 Inv     SS>I      0x2000
      174   2    L1Cache                 Inv      I>I      0x2000
      175   3    L1Cache       Data_all_Acks     IM>M      0x2000
      180   0    L2Cache             L1_GETX     SS>SS_MB  0x3000
      190   0    L1Cache               Store      I>IM     0x4000
      191   0    L2Cache             L1_GETX     MT>MT_MB  0x4000
      192   0    L1Cache       Data_all_Acks     IM>M      0x4000
      200   2        Seq               Begin       >       0x5000 ST
      201   2    L1Cache               Store     SS>SM     0x5000
      202   1        Seq               Begin       >       0x5000 ST
      203   1    L1Cache               Store      I>IM     0x5000
      204   0    L2Cache             L1_GETX     SS>SS_MB  0x5000
      205   0    L2Cache          L1_UPGRADE  SS_MB>SS_MB  0x5000
      206   2    L1Cache  L0_Invalidate_Else     SM>SM_IL0 0x5000
      207   3    L1Cache                 Inv     SS>I      0x5000
      208   1    L1Cache       Data_all_Acks     IM>M      0x5000
      209   2    L1Cache              L0_Ack SM_IL0>IM     0x5000
      210   0    L2Cache          L1_UPGRADE  SS_MB>SS_MB  0x5000
      211   0    L2Cache             L1_GETX     MT>MT_MB  0x5000
      212   1    L1Cache            Fwd_GETX     MM>I      0x5000
      213   2    L1Cache       Data_all_Acks     IM>M      0x5000
      220   0        Seq               Begin       >       0x6000 ST
      221   0    L1Cache               Store     SS>SM     0x6000
      222   0    L2Cache          L1_UPGRADE     SS>SS_MB  0x6000
      223   3    L1Cache                 Inv     SS>I      0x6000
      224   0    L1Cache             Ack_all     SM>M      0x6000
      230   0    L2Cache             L1_GETX     XX>XX     0x7000
"""


def selftest():
    d = tempfile.mkdtemp()
    t = os.path.join(d, 'tr')
    open(t, 'w').write(TR)
    ok = True
    with open(os.path.join(d, 'ev'), 'w') as f:
        ev, an = gem5(t, (0, 1, 2, 3), out=f)
    got = [(e['req'], e['state'], e['kind'], tuple(sorted(e['holders'])), len(e['stale'])) for e in sorted(ev, key=lambda e: e['tick'])]
    # 101: a GETX from NP pops, not an event; 151: core 1 asks, core 0 owns (MT), core 1 had no
    # Seq Begin on 0x1000 -> no instruction; 163: core 2's RMW (its ST at 0x1008, then the Pair),
    # held by core 1 (the Resource Stall line ignored); 172: core 3's store, holders 1 and 2 (2 stale,
    # an Inv in I); 180: never completes -> unpaired; 191: core 0, no holder, no instruction;
    # 204: core 2 asked first (UPGRADE, SS > SM), but core 1 completes: the L2 took core 1's GETX first,
    # invalidating 2 (L0_Invalidate_Else in SM) and 3; 205 / 210: stalled, no pop; 211: core 2's UPGRADE,
    # no longer a sharer, taken as L1_GETX in MT, held by core 1; 222: an L1_UPGRADE (not an event);
    # 230: a state the table does not list (counted)
    want = [(1, 'MT', None, (0,), 0), (2, 'MT', 'rmw', (1,), 0), (3, 'SS', 'store', (1, 2), 1), (0, 'MT', None, (), 0),
            (1, 'SS', 'store', (2, 3), 0), (2, 'MT', 'store', (1,), 0)]
    if got != want:
        ok = False
        print('selftest: gem5 events', got)
    exp = {'events unpaired': 1, 'events without a holder': 1, 'events without an instruction': 2,
           'events the issue order pairs differently': 2, 'L2 requests without an L1 issue in the trace': 1,
           'L2 request transitions in an unlisted state': 1, 'issues left pending': 0, 'requester among holders': 0,
           'completions without a transaction': 0, 'pairs without their first request': 0}
    if any(an[k] != v for k, v in exp.items()):
        ok = False
        print('selftest: anomalies', {k: an[k] for k in exp})
    # amendment 2: the same trace with L1 / L2 addresses as gem5 25.1 prints them ("[0xA, line 0xL]",
    # an L2 line's NetDest after it); the pipe's Seq lines stay bare. Same events, same anomalies.
    def g25(ln):
        q = ln.split()
        if len(q) >= 6 and q[2] in ('L1Cache', 'L2Cache'):
            a = int(q[5], 16)
            ln = ln.replace(f' {q[5]}', f' [{q[5]}, line {a & ~63:#x}]' + (' [NetDest (20) 0 0 0 0  - 1 0 0 0  - ]' if q[2] == 'L2Cache' else ''), 1)
        return ln
    t25 = os.path.join(d, 'tr25')
    open(t25, 'w').write('\n'.join(g25(ln) for ln in TR.splitlines()) + '\n')
    with open(os.path.join(d, 'ev25'), 'w') as f:
        ev25, an25 = gem5(t25, (0, 1, 2, 3), out=f)
    if [(e['req'], e['state'], e['kind'], tuple(sorted(e['holders'])), len(e['stale'])) for e in sorted(ev25, key=lambda e: e['tick'])] != want \
            or any(an25[k] != v for k, v in exp.items()) or '[0x1000, line 0x1000]' not in open(t25).read():
        ok = False
        print('selftest: gem5 25.1 address form', an25)
    # the plain RMW: core 0's ST at 0x2004 right after its RMW_Read there is 'rmw'
    t2 = os.path.join(d, 'tr2')
    open(t2, 'w').write('      140   0        Seq               Begin       >       0x2004 ST\n'
                        '      142   0    L1Cache               Store      I>IM     0x2000 \n'
                        '      143   0    L2Cache             L1_GETX     MT>MT_MB  0x2000 \n'
                        '      144   1    L1Cache            Fwd_GETX     MM>I      0x2000 \n'
                        '      145   0    L1Cache       Data_all_Acks     IM>M      0x2000 \n'
                        '      146   0        Seq                Pair       >       0x2004 ST\n'
                        '      150   0        Seq               Begin       >       0x2008 ST\n'
                        '      151   0        Seq                Pair       >       0x2010 ST\n')
    with open(os.path.join(d, 'ev2'), 'w') as f:
        ev2, an2 = gem5(t2, (0, 1), out=f)
    if [(e['kind'], tuple(e['holders'])) for e in ev2] != [('rmw', (1,))] or an2['pairs without their first request'] != 1:
        ok = False
        print('selftest: plain RMW', ev2)
    # QP (amendment 2) on hand-made ev files. Ping-pong on line 10j: store issues A, B, A, B; in round
    # 1 the holder B replaces the line from MM before A's store (removed: no event). Readers on line
    # 20j: loads by A, B, C; B replaces from SS (silent: it stays, stale 1); D stores.
    def qpfile(name, kind, drop_excl=True, extra_event=False, stale_wrong=False):
        q = os.path.join(d, name)
        with open(q, 'w') as f:
            tk = 0
            for j in range(4):
                A, B, C, D = j % 4, (j + 1) % 4, (j + 2) % 4, (j + 3) % 4
                ln = f'{0x100 + j:x}'
                seq = []
                for k, (rq, h) in enumerate(((A, None), (B, A), (A, B), (B, A))):
                    tk += 10
                    seq.append(f'S {tk} {ln} {rq} I')
                    if j == 1 and k == 2:
                        seq.append(f'R {tk - 5} {ln} {h} MM')          # B replaced the line just before A's store
                        if not extra_event:
                            continue
                    if h is not None:
                        print(f'E {tk + 1} {ln} {rq} MT {kind} {h} 0 0', file=f)
                for x in seq:
                    print(x, file=f)
                rl = f'{0x200 + j:x}'
                for c in (A, B, C):
                    tk += 10
                    print(f'L {tk} {rl} {c} I', file=f)
                print(f'R {tk + 1} {rl} {B} SS', file=f)
                tk += 10
                print(f'S {tk} {rl} {D} I', file=f)
                print(f'E {tk + 1} {rl} {D} SS store {",".join(map(str, sorted((A, B, C))))} 0 {0 if stale_wrong else 1}', file=f)
        return q
    res = [qp('pp_store', qpfile('q1', 'store')) == 0, qp('readers', qpfile('q2', 'store')) == 0,
           qp('pp_lock', qpfile('q3', 'rmw')) == 0,
           qp('pp_lock', qpfile('q4', 'store')) != 0,                        # kinds differ
           qp('pp_store', qpfile('q5', 'store', extra_event=True)) != 0,     # an event the replacement rules out
           qp('readers', qpfile('q6', 'store', stale_wrong=True)) != 0]      # the stale count differs
    if not all(res):
        ok = False
        print('selftest: QP', res)
    # ChampSim side
    el = os.path.join(d, 'el')
    open(el, 'w').write('G LLC 10 0 1 5 401000 40 40 RFO 0 0 1\n'      # rmw ip, holder core 0
                        'G LLC 11 0 2 6 402000 41 41 RFO 0 0 6\n'      # store, holders 1, 2
                        'G LLC 12 0 2 7 402000 41 41 RFO 0 0 0\n'      # no gem5-rule holder: not an event
                        'G LLC 13 1 2 8 402000 41 41 RFO 0 0 1\n'      # warm-up
                        'U L1D 14 0 3 9 402000 41 41 RFO 0 0 1\n')     # an upgrade: not a G
    rm = os.path.join(d, 'rm')
    open(rm, 'w').write('IP 401000\nLINE 40\n')
    rl = os.path.join(d, 'rl')
    open(rl, 'w').write('LLC COHERENCE DIR RFO GEM5-RULE EVENTS: 2\n')
    with open(os.path.join(d, 'cs'), 'w') as f:
        champsim(el, rm, rl, out=f)
    lines = open(os.path.join(d, 'cs')).read().splitlines()
    if 'QC0 holds' not in lines[0] or lines[1:] != ['E 10 40 1 - rmw 0 1', 'E 11 41 2 - store 1,2 0']:
        ok = False
        print('selftest: champsim', lines)
    print('selftest PASS' if ok else 'selftest FAIL')
    return 0 if ok else 1


def main(a):
    if a[:1] == ['gem5'] and len(a) >= 2:
        traced = (1, 2, 3, 4)
        if '--traced' in a:
            traced = tuple(int(x) for x in a[a.index('--traced') + 1].split(','))
        gem5(a[1], traced, repl='--repl' in a)
        return 0
    if a[:1] == ['qp'] and len(a) == 3:
        return qp(a[1], a[2])
    if a[:1] == ['rmwips'] and '--warmup' in a and '--sim' in a:
        i = a.index('--warmup')
        paths = [x for x in a[1:min(i, a.index('--sim'))]]
        rmwips(paths, int(a[i + 1]), int(a[a.index('--sim') + 1]))
        return 0
    if a[:1] == ['champsim'] and len(a) == 4:
        champsim(a[1], a[2], a[3])
        return 0
    if a[:1] == ['qg1'] and len(a) == 3:
        return qg1(a[1], a[2])
    if a[:1] == ['report'] and len(a) == 8:
        return 0 if report(*a[1:]) is not None else 1
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]) or 0)
