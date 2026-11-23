#!/usr/bin/env python3
"""Step 5's checks and score (policy_rerun_design_2026-10-19.md, with its
amendment 1). Written and tested on a made-up case before any step 5 number
was read.

  scripts/policy_score.py logrows TOP CFGDIR     > bench/policy_sanity/p2_log_rows_vN.txt
      one line per step 5 run.log under TOP/phaseA_b3_p2_*: complete, SYNC
      DEADLOCK, end of trace, view-order raw / by silent re-listing /
      unexplained, the mutex order printed, the LLC's MSHRs in its config
      (CFGDIR = the chain's ~/sync_pol/cfg, <suffix>_<regime>_<policy>.json)
  scripts/policy_score.py check ROWS B3ROWS LOGROWS MIXDIR
  scripts/policy_score.py score ROWS B3ROWS LOGROWS MIXDIR
      ROWS = phasea_rows_vN.txt, B3ROWS = b3_rows_vN.txt (both from
      pull_results.sh); MIXDIR holds canneal 16's raw<t>.mix files (QT).
      `score` runs every check first and prints P11-P14 and the reported
      rankings only if every check holds ("a failed check is fixed, and the
      affected runs rerun, before any number is read").
  scripts/policy_score.py selftest
  POLICY_TREE=phaseA_b3_p3_ scripts/policy_score.py fccompare ROWS B3ROWS LOGROWS MIXDIR P2TOP P3TOP
      amendment 3 (H7): C1-C7 on the p3 trees (as check), then C8 from the
      logs (P2TOP/P3TOP hold phaseA_b3_p2_* / phaseA_b3_p3_* trees: the p3 log
      prints SYNC LOCK WORD: request once and one LOCK-WORD REQUESTS line a
      CPU, its .bin names the F-C binary, its window and traces by CPU equal
      the p2 log's); only then P-H7a (every canneal run within +-0.5% of its
      p2 max_cycles), P-H7b (P11-P14 verdicts equal on p2 and p3) and the
      reported table (each run's change and requests; p2 vs p3 tau a tree)

The checks (the design's "Checks before anything is scored", amendment 1):
  C1 all 171 jobs of policy_jobs.py have a complete row and a complete log
  C2 no SYNC DEADLOCK and no end of trace in any log; the rows' trace-wrap
     and page-pool flags ok
  C3 every run at private-coherence level 2; self-check 0; stale-holders 0;
     VIEW-ORDER VIOLATIONS UNEXPLAINED 0 (raw = by silent re-listing allowed)
  C4 wherever a SYNC MUTEX ORDER line is printed (the trace has mutex
     records), it reads `timing`
  C5 the regime flag: private 0 aliased fills and 0 invalidations, shared
     non-zero aliased fills (and the rest of analyze_rows.py's standing
     checks, tree by tree)
  C6 QT for canneal 16: 16 traced threads, each at least 172.5 M instructions
  C7 the LLC's MSHRs: 64 in the _mshr64 runs, 16 in every other

The score:
  P11 canneal 4 and 8, at fixed 2 MB and at 2 MB a core: Kendall tau between
      the shared and the private ranking of the 9 policies >= +0.5, all four
  P12 canneal fixed 2 MB, 4 and 8 cores: the best policy's gain over LRU is
      larger shared than private, at both
  P13 ocean, both sizes: shared against private tau >= +0.7
  P14 canneal 4c fixed shared: 64 LLC MSHRs against 16, tau >= +0.7
  barnes std: checked, NOT ranked (amendment 1, item 3: not validated).
  Reported, no prediction: synchronised (this step) against the level-2 A5
  rerun on drifting traces (phaseA_l2_fixed / _scaled, shared; canneal 4/8/16,
  ocean 4); COALESCE's place and gaps; canneal 16.

Ranking: max_cycles, lower first; gains are lru / policy - 1 (as
analyze_rows.py rank); tau is analyze_rows.kendall_tau on the orders, ties
broken by policy name as analyze_rows.py compare does (ties are listed).
"""
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_rows as AR          # noqa: E402
import policy_jobs as PJ           # noqa: E402

B3 = ('tree pol wl cores rg st ins rfo_ev rfo_sh wb_ev wb_inv pres_ev pres_co prot_ev prot_co registered selfcheck rmw'
      ' level up_ev up_co up_pres inval_copies stale_fills stale_holders rfo_bounded up_bounded'
      ' rfo_g5 rfo_g5_co up_g5 up_g5_co view_order').split()   # = b3_score.py's B3
TREE = os.environ.get('POLICY_TREE', 'phaseA_b3_p2_')   # amendment 3 (H7): phaseA_b3_p3_ for the F-C rows
P2, P3 = 'phaseA_b3_p2_', 'phaseA_b3_p3_'
FC_BIN = 'champsim_fc_a2e88e46'
POLS = PJ.POLICIES
QT_MIN = 172_500_000


def jobs():
    """[(tree, wl, cores, regime, policy, mshr)] from policy_jobs.py's SETS."""
    out = []
    for traces, wl, cores, regimes, mshr, sizes in PJ.SETS:
        for scaled in sizes:
            suffix = f'{wl if traces != "barnesstd" else "barnesstd"}{cores}' + ('_scaled' if scaled else '') + (f'_mshr{mshr}' if mshr else '')
            for rg in regimes:
                for pol in POLS:
                    out.append((TREE + suffix, wl, cores, rg, pol, int(mshr or 16)))
    return out


# ---------------------------------------------------------------- logrows
def roi(lines):
    i = next((k for k, ln in enumerate(lines) if ln.startswith('Region of Interest Statistics')), None)
    return lines[i:] if i is not None else lines


def llc_mshr(cfgfile):
    import json
    try:
        c = json.load(open(cfgfile))
    except Exception:
        return '-'
    llc = c.get('LLC') or {}
    return str(llc.get('mshr_size', '-'))


def logrows(top, cfgdir):
    print('# policy_score.py logrows', top, cfgdir)
    for tree, wl, cores, rg, pol, mshr in jobs():
        d = os.path.join(top, tree, f'regime_{rg}', f'{wl}_{cores}core', pol)
        f = os.path.join(d, 'run.log')
        key = f'{tree} {rg} {wl} {cores} {pol}'
        if not os.path.exists(f):
            print(f'LOG {key} ABSENT')
            continue
        lines = open(f, errors='replace').read().splitlines()
        r = roi(lines)

        def llc(name):
            v = [ln.split()[-1] for ln in r if re.match(rf'LLC COHERENCE DIR {name}:', ln)]
            return v[0] if v else '-'
        mx = next((ln for ln in lines if ln.startswith('SYNC MUTEX ORDER:')), '')
        mm = re.match(r'SYNC MUTEX ORDER: (\S+)', mx)
        fin = [(int(m.group(2)), int(m.group(1))) for m in (re.match(r'Simulation finished CPU (\d+) instructions: \d+ cycles: (\d+)', ln) for ln in lines) if m]
        last = max(fin) if fin else None
        import hashlib
        llcmd5 = hashlib.md5('\n'.join(ln for ln in r if '->LLC ' in ln).encode()).hexdigest()[:12]
        cf = os.path.join(cfgdir, f"{tree.replace(TREE, '')}_{rg}_{pol}.json")
        print(f'LOG {key} complete {int(any("ChampSim completed all CPUs" in ln for ln in lines))} '
              f'deadlock {sum("SYNC DEADLOCK" in ln for ln in lines)} eot {sum("Reached end of trace" in ln for ln in lines)} '
              f'raw {llc("VIEW-ORDER VIOLATIONS")} bysilent {llc("VIEW-ORDER LINES BY SILENT RE-LISTING")} '
              f'unexplained {llc("VIEW-ORDER VIOLATIONS UNEXPLAINED")} mutex_order {mm.group(1) if mm else "-"} '
              f'llc_mshr {llc_mshr(cf) if os.path.exists(cf) else "-"} '
              f'lastcpu {last[1] if last else "-"} lastcyc {last[0] if last else "-"} llcmd5 {llcmd5}')


def load_logrows(path):
    out = {}
    for ln in open(path):
        p = ln.split()
        if not p or p[0] != 'LOG':
            continue
        key = (p[1], p[2], p[3], int(p[4]), p[5])
        if p[6] == 'ABSENT':
            out[key] = None
            continue
        out[key] = dict(zip(p[6::2], p[7::2]))
    return out


def load_b3(path):
    out = {}
    for ln in open(path):
        p = ln.split()
        if len(p) != len(B3) or not p[0].startswith(TREE):
            continue
        r = dict(zip(B3, p))
        out[(r['tree'], r['rg'], r['wl'], int(r['cores']), r['pol'])] = r
    return out


def mix_instructions(path):
    """Instructions in a trace from its .mix (trace_mix.c): the T line's
    record count, less its sync records when it ends 'sync K' -- QT's own
    rule in sync_server.sh."""
    for ln in open(path, errors='replace'):
        p = ln.split()
        if p and p[0] == 'T':
            return int(p[1]) - (int(p[-1]) if len(p) > 2 and p[-2] == 'sync' else 0)
    return None


# ---------------------------------------------------------------- checks
def run_checks(rows, b3, logs, mixdir):
    bad = []
    J = jobs()
    byk = {(r['tree'], r['rg'], r['wl'], r['cores'], r['pol']): r for r in rows if r['tree'].startswith(TREE)}
    print(f'== checks: {len(J)} jobs expected, {len(byk)} step 5 rows, {sum(v is not None for v in logs.values())} logs, {len(b3)} store-time rows')
    for tree, wl, cores, rg, pol, mshr in J:
        k = (tree, rg, wl, cores, pol)
        tag = ' '.join(map(str, k))
        r, lg, s = byk.get(k), logs.get(k), b3.get(k)
        # C1
        if r is None or r['st'] != 'complete':
            bad.append(f'C1 {tag}: row {"absent" if r is None else r["st"]}')
        if lg is None or lg.get('complete') != '1':
            bad.append(f'C1 {tag}: log {"absent" if lg is None else "not complete"}')
            continue
        # C2
        if lg['deadlock'] != '0':
            bad.append(f'C2 {tag}: SYNC DEADLOCK x{lg["deadlock"]}')
        if lg['eot'] != '0':
            bad.append(f'C2 {tag}: end of trace x{lg["eot"]}')
        if r is not None and (r['tw'] != 'ok' or r['vm'] != 'ok'):
            bad.append(f'C2 {tag}: trace-wrap {r["tw"]}, page pool {r["vm"]}')
        # C3
        if s is None:
            bad.append(f'C3 {tag}: no store-time row')
        else:
            if s['level'] != '2':
                bad.append(f'C3 {tag}: level {s["level"]}')
            if s['selfcheck'] != '0':
                bad.append(f'C3 {tag}: self-check {s["selfcheck"]}')
            if s['stale_holders'] != '0':
                bad.append(f'C3 {tag}: stale-holders {s["stale_holders"]}')
        if lg['unexplained'] != '0':
            bad.append(f'C3 {tag}: view-order unexplained {lg["unexplained"]} (raw {lg["raw"]}, by silent re-listing {lg["bysilent"]})')
        # C4
        if lg['mutex_order'] not in ('-', 'timing'):
            bad.append(f'C4 {tag}: SYNC MUTEX ORDER {lg["mutex_order"]}')
        # C7
        if lg['llc_mshr'] != str(mshr):
            bad.append(f'C7 {tag}: LLC MSHRs {lg["llc_mshr"]}, expected {mshr}')
    # C5: analyze_rows.py's standing checks, tree by tree (the regime flag among them)
    trees = sorted({j[0] for j in J})
    print('== C5: the standing row checks (analyze_rows.py check), the 19 step 5 trees')
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        AR.check(rows, trees)
    out = buf.getvalue()
    print(out, end='')
    cur, other = None, []
    for ln in out.splitlines():
        m = re.match(r'== (phaseA\S+): ', ln)
        if m:
            cur = m.group(1)
            continue
        if not ln.startswith('   FAIL '):
            continue
        m = re.match(r'   FAIL (\S+) (\d+)c (\S+): (.+) share max_cycles (\d+)$', ln)
        if not m:
            other.append(ln.strip())
            continue
        wl, c, rg, pols = m.group(1), int(m.group(2)), m.group(3), m.group(4).split(', ')
        ls = [logs.get((cur, rg, wl, c, p)) for p in pols]
        why = explained_tie(ls)
        if why:
            print(f'   C5 tie EXPLAINED (amendment 2): {cur} {rg} {", ".join(pols)}: {why}')
        else:
            other.append(f'{cur}: {ln.strip()} (not an explained tie)')
    if other:
        bad.append(f'C5 {len(other)} standing check failure(s): ' + '; '.join(other))
    # C6: QT for canneal 16
    got = {}
    for t in range(1, 17):
        f = os.path.join(mixdir, f'raw{t}.mix')
        got[t] = mix_instructions(f) if os.path.exists(f) else None
    short = {t: v for t, v in got.items() if v is None or v < QT_MIN}
    print(f'== C6 (QT) canneal 16, threads 1-16: ' + ' '.join(f'{t}:{(v or 0) / 1e6:.1f}M' for t, v in got.items()))
    if short:
        bad.append(f'C6 canneal16 threads below {QT_MIN / 1e6} M or unread: {short}')
    mo = defaultdict(int)
    for k, lg in logs.items():
        if lg is not None:
            mo[(k[0].replace(TREE, ''), lg['mutex_order'])] += 1
    print('== C4 mutex order printed, by tree: ' + ', '.join(f'{t} {o} x{n}' for (t, o), n in sorted(mo.items())))
    print(f'== {len(bad)} check failure(s)' if bad else '== EVERY CHECK HOLDS (C1-C7)')
    for b in bad:
        print('   FAIL ' + b)
    return bad


def explained_tie(ls):
    """Amendment 2 (2026-11-10): two or more runs that share max_cycles are
    a tie, not a disguised policy, when their LLC counters differ (the
    policies made different choices) and the same core finishes last at the
    same cycle in each (the run ends when the last core reaches its count, so
    a difference off that core's path cannot move the end)."""
    if any(x is None or x.get('llcmd5') in (None, '-') or x.get('lastcpu') in (None, '-') for x in ls):
        return ''
    if len({x['llcmd5'] for x in ls}) != len(ls):
        return ''
    if len({(x['lastcpu'], x['lastcyc']) for x in ls}) != 1:
        return ''
    return f"LLC counters differ ({', '.join(x['llcmd5'] for x in ls)}); CPU {ls[0]['lastcpu']} finishes last at {int(ls[0]['lastcyc']):,} in each"


# ---------------------------------------------------------------- score
def order(rows, tree, rg, pols=POLS):
    d = {r['pol']: r for r in rows if r['tree'] == tree and r['rg'] == rg and r['st'] == 'complete' and r['pol'] in pols}
    return d, sorted(sorted(d), key=lambda p: d[p]['max_cyc'])


def ties(d):
    seen = defaultdict(list)
    for p, r in d.items():
        seen[r['max_cyc']].append(p)
    return [v for v in seen.values() if len(v) > 1]


def tau(rows, ta, ra, tb, rb):
    da, oa = order(rows, ta, ra)
    db, ob = order(rows, tb, rb)
    common = sorted(set(da) & set(db))
    oa = [p for p in oa if p in common]
    ob = [p for p in ob if p in common]
    return AR.kendall_tau(oa, ob), len(common), ties(da) + ties(db)


def gain(rows, tree, rg):
    d, o = order(rows, tree, rg)
    best = o[0]
    return d['lru']['max_cyc'] / d[best]['max_cyc'] - 1, best


def table(rows, tree, rg, title):
    d, o = order(rows, tree, rg)
    lru = d['lru']['max_cyc']
    print(f'   {title}')
    for i, p in enumerate(o):
        gap = f"{d[o[i + 1]]['max_cyc'] / d[p]['max_cyc'] - 1:+.2%}" if i + 1 < len(o) else ''
        mark = '  <- COALESCE (arm B)' if p == 'coalesce' else ''
        print(f'     {i + 1}. {p:11} {d[p]["max_cyc"]:>14,}  vs LRU {lru / d[p]["max_cyc"] - 1:+.2%}  gap to next {gap:>7}{mark}')


def score(rows, b3, logs, mixdir):
    bad = run_checks(rows, b3, logs, mixdir)
    if bad:
        print('\nNOT SCORED: a check failed. It is fixed and the affected runs rerun before any number is read.')
        return 1
    T = lambda s: TREE + s  # noqa: E731
    print('\n== P11: sharing keeps the order at one size (canneal 4 and 8; tau >= +0.5 at both sizes)')
    p11 = []
    for c in (4, 8):
        for sz, suf in (('fixed 2 MB', ''), ('2 MB a core', '_scaled')):
            t, n, tl = tau(rows, T(f'canneal{c}{suf}'), 'shared', T(f'canneal{c}{suf}'), 'private')
            p11.append(t >= 0.5)
            print(f'   canneal {c}c, {sz}: shared vs private tau {t:+.2f} over {n}' + (f'  ties {tl}' if tl else ''))
    print(f'   P11 {"HOLDS" if all(p11) else "FAILS"} ({sum(p11)} of {len(p11)})')
    print('\n== P12: sharing raises the stakes (canneal fixed 2 MB: best gain over LRU, shared > private)')
    p12 = []
    for c in (4, 8):
        gs, bs = gain(rows, T(f'canneal{c}'), 'shared')
        gp, bp = gain(rows, T(f'canneal{c}'), 'private')
        p12.append(gs > gp)
        print(f'   canneal {c}c: shared {gs:+.2%} ({bs}), private {gp:+.2%} ({bp})')
    print(f'   P12 {"HOLDS" if all(p12) else "FAILS"} ({sum(p12)} of {len(p12)})')
    print('\n== P13: the control (ocean, both sizes; tau >= +0.7)')
    p13 = []
    for sz, suf in (('fixed 2 MB', ''), ('2 MB a core', '_scaled')):
        t, n, tl = tau(rows, T(f'ocean4{suf}'), 'shared', T(f'ocean4{suf}'), 'private')
        p13.append(t >= 0.7)
        print(f'   ocean 4c, {sz}: shared vs private tau {t:+.2f} over {n}' + (f'  ties {tl}' if tl else ''))
    print(f'   P13 {"HOLDS" if all(p13) else "FAILS"} ({sum(p13)} of {len(p13)})')
    print('\n== P14: MSHRs (canneal 4c fixed shared, 64 against 16; tau >= +0.7)')
    t, n, tl = tau(rows, T('canneal4_mshr64'), 'shared', T('canneal4'), 'shared')
    print(f'   tau {t:+.2f} over {n}' + (f'  ties {tl}' if tl else ''))
    print(f'   P14 {"HOLDS" if t >= 0.7 else "FAILS"}')
    print('\n== barnes std: every check above held; NOT ranked (amendment 1, item 3: barnes does not agree with gem5)')
    print('\n== Reported, no prediction: synchronised (this step) against the level-2 A5 rerun on drifting traces, shared')
    for c, wl in ((4, 'canneal'), (8, 'canneal'), (16, 'canneal'), (4, 'ocean')):
        for sz, suf, old in (('fixed 2 MB', '', 'phaseA_l2_fixed'), ('2 MB a core', '_scaled', 'phaseA_l2_scaled')):
            olds = [r for r in rows if r['tree'] == old and r['wl'] == wl and r['cores'] == c and r['rg'] == 'shared' and r['st'] == 'complete']
            if not olds:
                print(f'   {wl} {c}c, {sz}: no level-2 A5 rows')
                continue
            sub = [r for r in rows if not (r['tree'] == old and not (r['wl'] == wl and r['cores'] == c))]
            t, n, tl = tau(sub, T(f'{wl}{c}{suf}'), 'shared', old, 'shared')
            print(f'   {wl} {c}c, {sz}: tau {t:+.2f} over {n}' + (f'  ties {tl}' if tl else ''))
    print('\n== Reported: the rankings (COALESCE is the case study; its architecture stays frozen)')
    for c in (4, 8, 16):
        for sz, suf in (('fixed 2 MB', ''), ('2 MB a core', '_scaled')):
            for rg in (('shared', 'private') if c < 16 else ('shared',)):
                table(rows, T(f'canneal{c}{suf}'), rg, f'canneal {c}c, {sz}, {rg}')
    for sz, suf in (('fixed 2 MB', ''), ('2 MB a core', '_scaled')):
        for rg in ('shared', 'private'):
            table(rows, T(f'ocean4{suf}'), rg, f'ocean 4c, {sz}, {rg}')
    table(rows, T('canneal4_mshr64'), 'shared', 'canneal 4c, fixed 2 MB, shared, 64 LLC MSHRs')
    return 0


# ---------------------------------------------------------------- amendment 3 (H7)
def verdicts(rows, prefix):
    """P11-P14 as score() decides them, for the trees under prefix:
    {'P11': (holds, n_held, n), ...}."""
    T = lambda s: prefix + s  # noqa: E731
    p11 = [tau(rows, T(f'canneal{c}{suf}'), 'shared', T(f'canneal{c}{suf}'), 'private')[0] >= 0.5
           for c in (4, 8) for suf in ('', '_scaled')]
    p12 = []
    for c in (4, 8):
        gs, _ = gain(rows, T(f'canneal{c}'), 'shared')
        gp, _ = gain(rows, T(f'canneal{c}'), 'private')
        p12.append(gs > gp)
    p13 = [tau(rows, T(f'ocean4{suf}'), 'shared', T(f'ocean4{suf}'), 'private')[0] >= 0.7 for suf in ('', '_scaled')]
    p14 = [tau(rows, T('canneal4_mshr64'), 'shared', T('canneal4'), 'shared')[0] >= 0.7]
    return {k: (all(v), sum(v), len(v)) for k, v in (('P11', p11), ('P12', p12), ('P13', p13), ('P14', p14))}


def log_facts(path):
    """What C8 compares, from one run.log (and its .bin)."""
    if not os.path.exists(path):
        return None
    lines = open(path, errors='replace').read().splitlines()
    g = lambda pre: next((ln.split()[-1] for ln in lines if ln.startswith(pre)), None)  # noqa: E731
    tr = sorted((int(m.group(1)), m.group(2)) for m in (re.match(r'CPU (\d+) runs (\S+)', ln) for ln in lines) if m)
    rq = [re.match(r'CPU (\d+) LOCK-WORD REQUESTS: measured (\d+) warmup (\d+)', ln) for ln in lines]
    rq = [m for m in rq if m]
    b = path + '.bin'
    return {'wu': g('Warmup Instructions:'), 'si': g('Simulation Instructions:'), 'traces': [t for _, t in tr],
            'lockword': sum(ln == 'SYNC LOCK WORD: request' for ln in lines), 'rqlines': len(rq),
            'measured': sum(int(m.group(2)) for m in rq), 'warmup': sum(int(m.group(3)) for m in rq),
            'bin': open(b).read().strip() if os.path.exists(b) else None,
            'complete': any('ChampSim completed all CPUs' in ln for ln in lines)}


def fccompare(rows, b3, logs, mixdir, p2top, p3top):
    if TREE != P3:
        print(f'fccompare reads the p3 trees: run it with POLICY_TREE={P3}')
        return 1
    bad = run_checks(rows, b3, logs, mixdir)
    J = jobs()
    facts = {}
    for tree, wl, cores, rg, pol, mshr in J:
        suf = tree[len(P3):]
        rel = os.path.join(f'regime_{rg}', f'{wl}_{cores}core', pol, 'run.log')
        a, b = log_facts(os.path.join(p2top, P2 + suf, rel)), log_facts(os.path.join(p3top, P3 + suf, rel))
        tag = f'{suf} {rg} {pol}'
        if a is None or b is None:
            bad.append(f'C8 {tag}: {"p2" if a is None else "p3"} log absent')
            continue
        facts[(suf, rg, pol)] = (a, b)
        if b['lockword'] != 1:
            bad.append(f'C8 {tag}: SYNC LOCK WORD: request printed {b["lockword"]} times')
        if b['rqlines'] != cores:
            bad.append(f'C8 {tag}: {b["rqlines"]} LOCK-WORD REQUESTS lines for {cores} CPUs')
        if b['bin'] != FC_BIN:
            bad.append(f'C8 {tag}: .bin {b["bin"]}, not {FC_BIN}')
        if (a['wu'], a['si']) != (b['wu'], b['si']):
            bad.append(f'C8 {tag}: window {b["wu"]} + {b["si"]}, the p2 run\'s {a["wu"]} + {a["si"]}')
        if a['traces'] != b['traces'] or len(b['traces']) != cores:
            bad.append(f'C8 {tag}: traces differ from the p2 run\'s (or not {cores})')
        if a['lockword'] != 0:
            bad.append(f'C8 {tag}: the p2 log prints SYNC LOCK WORD (not a g6 run)')
    print(f'== C8: {len(facts)} of {len(J)} p2 / p3 log pairs read')
    if bad:
        print(f'== {len(bad)} check failure(s)')
        for x in bad:
            print('   FAIL ' + x)
        print('\nNOT SCORED: a check failed. It is fixed and the affected runs rerun before any number is read.')
        return 1
    print('== EVERY CHECK HOLDS (C1-C8)')
    mc = {(r['tree'], r['rg'], r['pol']): r['max_cyc'] for r in rows if r['st'] == 'complete'}
    print('\n== Reported: each run, p3 against p2 (max_cycles; lock-word requests measured / warm-up)')
    worst, canneal_ok, cn = defaultdict(float), True, 0
    for tree, wl, cores, rg, pol, mshr in J:
        suf = tree[len(P3):]
        a, b = mc[(P2 + suf, rg, pol)], mc[(P3 + suf, rg, pol)]
        d = b / a - 1
        f2, f3 = facts[(suf, rg, pol)]
        worst[(suf, rg)] = max(worst[(suf, rg)], abs(d))
        if wl == 'canneal':
            cn += 1
            if abs(d) > 0.005:
                canneal_ok = False
        print(f'   {suf:22} {rg:7} {pol:11} {a:>14,} -> {b:>14,}  {d:+.3%}  requests {f3["measured"]:,} / {f3["warmup"]:,}' + ('  OUTSIDE 0.5%' if wl == 'canneal' and abs(d) > 0.005 else ''))
    print('\n== Reported: the p2 and p3 orders, each tree and regime (Kendall tau over 9; largest |change|)')
    for suf, rg in sorted(worst):
        t, n, tl = tau(rows, P2 + suf, rg, P3 + suf, rg)
        print(f'   {suf:22} {rg:7} tau {t:+.2f} over {n}  largest |change| {worst[(suf, rg)]:.3%}' + (f'  ties {tl}' if tl else ''))
    print(f'\n== P-H7a: every canneal run within +-0.5% of its p2 max_cycles ({cn} runs): {"HOLDS" if canneal_ok else "FAILS"}')
    v2, v3 = verdicts(rows, P2), verdicts(rows, P3)
    same = all(v2[k][0] == v3[k][0] for k in v2)
    for k in v2:
        print(f'   {k}: p2 {"HOLDS" if v2[k][0] else "FAILS"} ({v2[k][1]} of {v2[k][2]}), p3 {"HOLDS" if v3[k][0] else "FAILS"} ({v3[k][1]} of {v3[k][2]})')
    print(f'== P-H7b: P11-P14 read the same verdicts on p3 as on p2: {"HOLDS" if same else "FAILS"}')
    return 0


# ---------------------------------------------------------------- selftest
def selftest():
    """A made-up step 5: every job present and clean; shared and private
    rankings set by hand, so every tau, gain and verdict is known."""
    import tempfile
    tmp = tempfile.mkdtemp()
    J = jobs()
    base = {p: 300_000_000 + 1_000_000 * i for i, p in enumerate(POLS)}   # lru fastest ... coalesce slowest
    rev = {p: 300_000_000 + 1_000_000 * (len(POLS) - 1 - i) for i, p in enumerate(POLS)}   # the reverse

    def cyc(tree, rg, pol):
        if tree.endswith('barnesstd4_scaled') and rg == 'shared' and pol == 'srrip_bias':
            return base['srrip']     # a tie the logs explain (amendment 2)
        if tree.endswith('canneal8_scaled') and rg == 'private':
            return rev[pol]          # P11 must fail on this one comparison (tau -1)
        if tree.endswith('canneal4') and rg == 'shared':
            return base[pol] - (30_000_000 if pol == 'srrip' else 0)   # srrip best shared: gain 300/271 - 1 = 10.70%
        if tree.endswith('canneal4') and rg == 'private':
            return base[pol] - (3_000_000 if pol == 'srrip' else 0)    # srrip best private: 300/298 - 1 = 0.67%; P14 then has one swap, tau 34/36
        return base[pol]
    rows, b3l, logl = [], [], []
    for tree, wl, cores, rg, pol, mshr in J:
        mc = cyc(tree, rg, pol)
        sh = rg == 'shared'
        la, wa, ra, ta = 1000, 100, 50, 10
        rows.append(f'{tree} {pol} {wl} {cores} {rg} complete ok ok {mc} {mc} {100_000_000 * cores} {la} 500 {la + wa + ra + ta} 650 {wa} 100 {ra} 40 {ta} 10 {7 if sh else 0} {5 * cores if sh else 0}')
        b3l.append(' '.join([tree, pol, wl, str(cores), rg, 'complete'] + ['1'] * 10 + ['0', '0', '2'] + ['1'] * 5 + ['0'] + ['1'] * 6 + ['0']))
        logl.append(f'LOG {tree} {rg} {wl} {cores} {pol} complete 1 deadlock 0 eot 0 raw 0 bysilent 0 unexplained 0 '
                    f'mutex_order {"timing" if wl == "barnes" else "-"} llc_mshr {mshr} lastcpu 1 lastcyc {mc} llcmd5 {pol}')
    # the canneal 16 shared-invalidation rise across trees: invalidations scale with cores above
    for t in range(1, 17):
        open(os.path.join(tmp, f'raw{t}.mix'), 'w').write(f'C 0 0 0 0 0 x y\nT {215_001_236} 1 2 3 4 z 0 sync 1236\n')
    for name, lines in (('rows', rows), ('b3', b3l), ('logs', logl)):
        open(os.path.join(tmp, name), 'w').write('\n'.join(lines) + '\n')
    R, B, L = AR.load(os.path.join(tmp, 'rows')), load_b3(os.path.join(tmp, 'b3')), load_logrows(os.path.join(tmp, 'logs'))
    if len(B) != len(J):
        print(f'selftest: {len(B)} made-up store-time rows loaded, expected {len(J)}')
        return 1
    import io
    import contextlib
    ok = True

    def run(r, b, lg):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = score(r, b, lg, tmp)
        return rc, buf.getvalue()
    rc, out = run(R, B, L)
    expect = ['C5 tie EXPLAINED (amendment 2): phaseA_b3_p2_barnesstd4_scaled shared', 'EVERY CHECK HOLDS', 'canneal 8c, 2 MB a core: shared vs private tau -1.00 over 9', 'P11 FAILS (3 of 4)',
              'canneal 4c: shared +10.70% (srrip), private +0.67% (srrip)', 'canneal 8c: shared +0.00% (lru), private +0.00% (lru)',
              'P12 FAILS (1 of 2)', 'P13 HOLDS (2 of 2)', 'tau +0.94 over 9', 'P14 HOLDS', 'no level-2 A5 rows', 'NOT ranked']
    for e in expect:
        if e not in out:
            ok = False
            print(f'selftest: missing "{e}"')
    if rc != 0:
        ok = False
        print('selftest: clean case did not score')
    # faults: each must stop the score
    faults = [
        ('C1', lambda r, b, lg: (r[:-1], b, lg)),
        ('C2', lambda r, b, lg: (r, b, {**lg, next(iter(lg)): {**next(iter(lg.values())), 'eot': '1'}})),
        ('C3', lambda r, b, lg: (r, {k: ({**v, 'level': '0'} if i == 0 else v) for i, (k, v) in enumerate(b.items())}, lg)),
        ('C3', lambda r, b, lg: (r, b, {k: ({**v, 'unexplained': '2'} if i == 3 else v) for i, (k, v) in enumerate(lg.items())})),
        ('C4', lambda r, b, lg: (r, b, {k: ({**v, 'mutex_order': 'recorded'} if i == 5 else v) for i, (k, v) in enumerate(lg.items())})),
        ('C5', lambda r, b, lg: ([{**x, 'aliased': 3} if x['rg'] == 'private' and x['pol'] == 'lru' and x['tree'].endswith('ocean4') else x for x in r], b, lg)),
        ('C7', lambda r, b, lg: (r, b, {k: ({**v, 'llc_mshr': '16'} if k[0].endswith('mshr64') else v) for k, v in lg.items()})),
        # the tie unexplained: the same LLC counters (a disguised policy), or another last cycle
        ('C5', lambda r, b, lg: (r, b, {k: ({**v, 'llcmd5': 'srrip'} if k[0].endswith('barnesstd4_scaled') and k[1] == 'shared' and k[4] == 'srrip_bias' else v) for k, v in lg.items()})),
        ('C5', lambda r, b, lg: (r, b, {k: ({**v, 'lastcyc': '1'} if k[0].endswith('barnesstd4_scaled') and k[1] == 'shared' and k[4] == 'srrip_bias' else v) for k, v in lg.items()})),
    ]
    for name, f in faults:
        r2, b2, l2 = f(list(R), dict(B), dict(L))
        rc, out = run(r2, b2, l2)
        if rc == 0 or f'FAIL {name}' not in out or 'NOT SCORED' not in out or 'P11' in out:
            ok = False
            print(f'selftest: fault {name} not stopped')
    os.remove(os.path.join(tmp, 'raw7.mix'))
    rc, out = run(R, B, L)
    if rc == 0 or 'FAIL C6' not in out:
        ok = False
        print('selftest: fault C6 not stopped')
    print('selftest PASS' if ok else 'selftest FAIL')
    return 0 if ok else 1


def main(a):
    if a[:1] == ['logrows'] and len(a) == 3:
        return logrows(a[1], a[2])
    if a[:1] in (['check'], ['score']) and len(a) == 5:
        rows, b3, logs = AR.load(a[1]), load_b3(a[2]), load_logrows(a[3])
        if a[0] == 'check':
            return 1 if run_checks(rows, b3, logs, a[4]) else 0
        return score(rows, b3, logs, a[4])
    if a[:1] == ['fccompare'] and len(a) == 7:
        return fccompare(AR.load(a[1]), load_b3(a[2]), load_logrows(a[3]), a[4], a[5], a[6])
    if a == ['selftest']:
        return selftest()
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
