#!/usr/bin/env python3
"""H4 and H5 (bench/policy_sanity/gem5_settings_design_2026-11-14.md): gem5's
LLC replacement policy and CPU model as settings, fixed before any of their
runs exists.

    hset_check.py qh0 ORIG_DIR NEW_DIR SETTING     (server) SETTING lru|srrip|drrip
    hset_check.py qo0 ORIG_DIR NEW_DIR             (server) the X86O3CPU run
    hset_check.py qend NEW_DIR [ENDED]             (server) ended at its instruction stop?
    hset_check.py cfg REF_JSON NEW_JSON SETTING    (server) the ChampSim config = the reference's but LLC.replacement
    hset_check.py rows [DIR]  > bench/policy_sanity/hset_gem5_rows_vN.txt   (b3_score.py's gem5 columns)
    hset_check.py mix [DIR]   > bench/policy_sanity/hset_gem5_mix_vN.txt    (run, loads, stores, instructions)
    hset_check.py score HSET_GEM5_ROWS HSET_GEM5_MIX ORIG_GEM5_MIX
    hset_check.py selftest                         hand cases, and QO0 on the speed test's real pair if present

QH0: NEW/config.ini equals ORIG/config.ini (ORIG's directory read as NEW's) in
every section except [system.ruby.l2_cntrl0.L2cache.replacement_policy] and its
children, which must hold exactly SETTING's declared policy; the original's
section must read TreePLRURP. Exit 0 = PASS, 1 = FAIL.
QO0: every section of ORIG exists in NEW; every section only in NEW lies under
system.cpu<N>.; every section other than [system.cpu<N>] is identical; in each
[system.cpu<N>] every line of ORIG is present but type (BaseTimingSimpleCPU ->
BaseO3CPU), branchPred and children (NEW's list contains ORIG's).
qend: exit 0 = ENDED-AT-STOP ("because a thread reached the max instruction
count", one statistics dump), 4 = OTHER, 5 = not ended.

score (laptop), H4 per program (ocean 2 MB, canneal 4c 2 MB, lunc, radix) and
setting (lru, srrip, drrip):
  C   ChampSim gem5-rule RFO events per KI: lru = the F-C reference run
      (simulator/results/lockfix/logs), srrip / drrip = H4's runs
      (simulator/results/hset/logs), read as lock_fix_score reads them; a run
      is used only if it qualifies (lock_fix_score.qualify against the
      reference) and its pulled config passes `cfg`
  G   gem5 SS + MT L1_GETX per KI in the window (longer stop - shorter stop)
  R   C / G for the 12 matched pairs, beside the scored one (gem5 TreePLRU)
  M   LLC demand misses per KI in the window: gem5 L2 demand accesses - hits;
      ChampSim the LLC's (TOTAL - WRITE) misses in the Region of Interest
  P-H4a lru in the band for each of the four; P-H4b srrip and drrip (8);
  "holds under three matched LLC policies" only if all 12 are in the band;
  the order by M: pairwise signs over 12 pairs, a pair under 1% relative
  difference in either simulator is a tie (counted apart).
H5 per program (ocean 2 MB, canneal 4c 2 MB, fluidanimate, vips): G_O3, R_O3
= C (the F-C reference's) / G_O3 beside the scored R; P-H5a ocean and canneal
in the band; per-CPU window instructions and loads / stores per KI against
TimingSimpleCPU's, reported.
"""
import json
import math
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HS_LOGS = os.environ.get('HS_LOGS', os.path.join(ROOT, 'simulator/results/hset/logs'))      # a rehearsal points these elsewhere
HS_CFG = os.environ.get('HS_CFG', os.path.join(ROOT, 'simulator/results/hset/cfg'))
SPEED = os.environ.get('HS_SPEED', os.path.join(ROOT, 'simulator/results/hset/speedcfg'))   # the speed test's TS / O3 config pair
BAND = (0.5, 2.0)
TIE = 0.01
EXIT_OK = 'because a thread reached the max instruction count'
P = 'system.ruby.l2_cntrl0.L2cache.replacement_policy'
BR = {'type': 'BRRIPRP', 'hit_priority': 'true', 'num_bits': '2'}
SPEC = {
    'lru': {P: {'type': 'LRURP'}},
    'srrip': {P: dict(BR, btp='0')},
    'drrip': {P: {'type': 'DuelingRP', 'constituency_size': '512', 'team_size': '16'},
              P + '.replacement_policy_a': dict(BR, btp='3'),
              P + '.replacement_policy_b': dict(BR, btp='100')},
}
SETTINGS = ('lru', 'srrip', 'drrip')
# program -> (F-C span label, ChampSim tree suffix, gem5 tag, short stop, long stop)
H4 = {'ocean4': ('ocean 2 MB', 'ocean4', 'ocean_4c', 50, 150),
      'canneal4': ('canneal 4c 2 MB', 'canneal4', 'canneal_4c', 50, 150),
      'lunc': ('lunc', 'lunc4', 'lunc_4c', 50, 150),
      'radix': ('radix', 'radix4', 'radix_4c', 830, 930)}
H5 = {'ocean4': ('ocean 2 MB', 'ocean4', 'ocean_4c', 50, 150),
      'canneal4': ('canneal 4c 2 MB', 'canneal4', 'canneal_4c', 50, 150),
      'fluidanimate': ('fluidanimate', 'fluidanimate4', 'fluidanimate_4c', 50, 150),
      'vips': ('vips', 'vips4', 'vips_4c', 50, 150)}


# ---------------------------------------------------------------- server side
def secs(path, orig_dir=None, new_dir=None):
    """section name -> its lines, in order (ORIG's directory read as NEW's)"""
    d, cur = {}, None
    for ln in open(path).read().splitlines():
        if orig_dir:
            ln = ln.replace(orig_dir.rstrip('/'), new_dir.rstrip('/'))
        m = re.fullmatch(r'\[(.*)\]', ln)
        if m:
            cur = m.group(1)
            d[cur] = []
        elif cur is not None and ln.strip():
            d[cur].append(ln)
    return d


def kv(lines):
    return dict(ln.split('=', 1) for ln in lines if '=' in ln)


def first_diff(x, y):
    for i, (a, b) in enumerate(zip(x, y)):
        if a != b:
            return f'original "{a}", new "{b}"'
    return f'{len(x)} lines in the original, {len(y)} in the new run'


def qh0(orig_dir, new_dir, setting, out=print):
    if setting not in SPEC:
        out(f'QH0 FAIL: unknown setting {setting}')
        return False
    a = secs(os.path.join(orig_dir, 'config.ini'), orig_dir, new_dir)
    b = secs(os.path.join(new_dir, 'config.ini'))
    under = lambda s: s == P or s.startswith(P + '.')
    bad = []
    if kv(a.get(P, [])).get('type') != 'TreePLRURP':
        bad.append(f'the original\'s [{P}] is not TreePLRURP')
    na, nb = {s for s in a if not under(s)}, {s for s in b if not under(s)}
    bad += [f'[{s}] missing in the new run' for s in sorted(na - nb)]
    bad += [f'[{s}] only in the new run' for s in sorted(nb - na)]
    bad += [f'[{s}]: {first_diff(a[s], b[s])}' for s in sorted(na & nb) if a[s] != b[s]]
    spec = SPEC[setting]
    pb = {s for s in b if under(s)}
    if pb != set(spec):
        bad.append(f'policy sections {sorted(pb)}, declared {sorted(spec)}')
    for s, want in spec.items():
        got = kv(b.get(s, []))
        for k, v in want.items():
            if got.get(k) != v:
                bad.append(f'[{s}] {k}={got.get(k)}, declared {v}')
    for x in bad[:12]:
        out('   QH0: ' + x)
    out(f'QH0 {"PASS" if not bad else "FAIL"}: L2 replacement policy {setting} ({spec[P]["type"]})' + ('' if not bad else f'; {len(bad)} problem(s)'))
    return not bad


def qo0(orig_dir, new_dir, out=print):
    a = secs(os.path.join(orig_dir, 'config.ini'), orig_dir, new_dir)
    b = secs(os.path.join(new_dir, 'config.ini'))
    cpu, child = re.compile(r'system\.cpu\d+'), re.compile(r'system\.cpu\d+\..*')
    bad = []
    bad += [f'[{s}] missing in the new run' for s in a if s not in b]
    bad += [f'[{s}] only in the new run, not under a CPU' for s in b if s not in a and not child.fullmatch(s)]
    cpus = [s for s in a if cpu.fullmatch(s)]
    if not cpus:
        bad.append('no [system.cpu<N>] section in the original')
    for s in a:
        if s in b and not cpu.fullmatch(s) and a[s] != b[s]:
            bad.append(f'[{s}]: {first_diff(a[s], b[s])}')
    for s in cpus:
        if s not in b:
            continue
        ka, kb = kv(a[s]), kv(b[s])
        if ka.get('type') != 'BaseTimingSimpleCPU':
            bad.append(f'[{s}] original type {ka.get("type")}, not BaseTimingSimpleCPU')
        if kb.get('type') != 'BaseO3CPU':
            bad.append(f'[{s}] new type {kb.get("type")}, not BaseO3CPU')
        if not set(ka.get('children', '').split()) <= set(kb.get('children', '').split()):
            bad.append(f'[{s}] children {ka.get("children")} not all in the new run\'s')
        lb = set(b[s])
        miss = [ln for ln in a[s] if not ln.startswith(('type=', 'branchPred=', 'children=')) and ln not in lb]
        bad += [f'[{s}] original "{ln}" not in the new run (new: {kb.get(ln.split("=", 1)[0])})' for ln in miss]
    for x in bad[:12]:
        out('   QO0: ' + x)
    out(f'QO0 {"PASS" if not bad else "FAIL"}: {len(cpus)} CPU(s) TimingSimpleCPU -> O3' + ('' if not bad else f'; {len(bad)} problem(s)'))
    return not bad


def qend(new_dir, ended=True, out=print):
    if not ended:
        out('QEND RUNNING')
        return 5
    lp, sp = os.path.join(new_dir, 'run.log'), os.path.join(new_dir, 'stats.txt')
    log = open(lp, errors='replace').read() if os.path.exists(lp) else ''
    dumps = open(sp).read().count('Begin Simulation Statistics') if os.path.exists(sp) else 0
    if EXIT_OK in log and dumps == 1:
        ft = re.search(r'^finalTick\s+(\d+)', open(sp).read(), re.M)
        out(f'QEND ENDED-AT-STOP finalTick {ft.group(1) if ft else "?"}')
        return 0
    tail = [ln for ln in log.splitlines() if ln.strip()][-1:] or ['<empty run.log>']
    out(f'QEND OTHER: {dumps} statistics dump(s); last line: {tail[0][:160]}')
    return 4


def cfg(ref_json, new_json, setting, out=print):
    a, b = json.load(open(ref_json)), json.load(open(new_json))
    bad = []
    if a.get('LLC', {}).get('replacement') != 'lru':
        bad.append(f'the reference\'s LLC replacement is {a.get("LLC", {}).get("replacement")}, not lru')
    if b.get('LLC', {}).get('replacement') != setting:
        bad.append(f'the new LLC replacement is {b.get("LLC", {}).get("replacement")}, not {setting}')
    if isinstance(b.get('LLC'), dict):
        b = json.loads(json.dumps(b))
        b['LLC']['replacement'] = a.get('LLC', {}).get('replacement')
    if a != b:
        bad.append('the configs differ elsewhere than LLC.replacement')
    for x in bad:
        out('   CFG: ' + x)
    out(f'CFG {"PASS" if not bad else "FAIL"}: LLC replacement lru -> {setting}')
    return not bad


# ---------------------------------------------------------------- laptop side
def mix(root):
    import glob
    for stats in sorted(glob.glob(f'{root}/**/stats.txt', recursive=True)):
        d = os.path.dirname(stats)
        if '.prev_' in os.path.relpath(d, root):
            continue
        s = {}
        for line in open(stats):
            p = line.split()
            if len(p) >= 2 and re.fullmatch(r'-?[0-9.e+]+', p[1]) and p[0] not in s:
                s[p[0]] = float(p[1])
        if 'simInsts' not in s:
            continue
        ld = sum(v for k, v in s.items() if re.fullmatch(r'system\.cpu\d+\.commitStats0\.numLoadInsts', k))
        st = sum(v for k, v in s.items() if re.fullmatch(r'system\.cpu\d+\.commitStats0\.numStoreInsts', k))
        print(os.path.relpath(d, root), int(s['simInsts']), int(ld), int(st))


def llc_misses(txt):
    """ChampSim's LLC (TOTAL - WRITE) misses in the Region of Interest, as lock_fix_score counts accesses"""
    tot = wr = 0
    roi = False
    for ln in txt.splitlines():
        if 'Region of Interest' in ln:
            roi = True
        if not roi:
            continue
        p = ln.split()
        miss = sum(int(p[i + 1]) for i in range(len(p) - 1) if p[i] == 'MISS:')
        if re.match(r'cpu[0-9]+->LLC TOTAL', ln):
            tot += miss
        elif re.match(r'cpu[0-9]+->LLC WRITE', ln):
            wr += miss
    return tot - wr


def load_mix(path):
    out = {}
    for line in open(path):
        p = line.split()
        if p and not p[0].startswith('#'):
            out[p[0]] = tuple(int(x) for x in p[1:4])
    return out


def in_band(x):
    return x is not None and BAND[0] <= x <= BAND[1]


def verdict(k_in, n, expected):
    """a prediction over EXPECTED points, N measured, K_IN of them in the band"""
    if n == expected and k_in == expected:
        return 'HOLDS'
    if k_in < n:
        return 'FAILS'
    return 'not decided (not all measured)'


def three_policies(k_in, n):
    if n == 12 and k_in == 12:
        return 'YES (12 of 12)'
    if k_in < n:
        return 'NO -- give the count and name each one outside'
    return f'NOT DECIDED ({n} of 12 measured)'


def order_pairs(mc, mg):
    """pairwise signs of M over the settings: (agree, disagree, ties)"""
    ag = dis = tie = 0
    s = [x for x in SETTINGS if x in mc and x in mg]
    for i in range(len(s)):
        for j in range(i + 1, len(s)):
            a, b = s[i], s[j]
            rc = abs(mc[a] - mc[b]) / max(mc[a], mc[b]) if max(mc[a], mc[b]) else 0.0
            rg = abs(mg[a] - mg[b]) / max(mg[a], mg[b]) if max(mg[a], mg[b]) else 0.0
            if rc < TIE or rg < TIE:
                tie += 1
            elif (mc[a] < mc[b]) == (mg[a] < mg[b]):
                ag += 1
            else:
                dis += 1
    return ag, dis, tie


def score(rows_path, mix_path, orig_mix_path):
    sys.path.insert(0, HERE)
    import lock_fix_score as L
    import b3_score as B
    print('== H4 / H5 (gem5_settings_design_2026-11-14.md)')
    print('== the parser, on the 14 scored logs')
    if not L.parser_check(verbose=False):
        sys.exit(1)
    D, _, sp = L.spans()
    span = {lab: (tree, ga, gb) for lab, _, tree, (_, ga, gb), _, _, _ in sp}
    Gv6 = B.load(D.G5ROWS, B.GEM5, lambda r: r['run'])
    Gh = B.load(rows_path, B.GEM5, lambda r: r['run'])
    Mh, Mo = load_mix(mix_path), load_mix(orig_mix_path)
    ki = lambda n, ins: 1000.0 * n / ins

    def gwin(setting, prog, info):
        _, _, tag, lo, hi = info
        a, b = f'{setting}/{prog}/l2_2MB_mi{lo}M/{tag}', f'{setting}/{prog}/l2_2MB_mi{hi}M/{tag}'
        if a not in Gh or b not in Gh:
            return None, f'no row for {a if a not in Gh else b}'
        try:
            return B.window(Gh, a, b), ''
        except SystemExit as e:
            return None, str(e)

    def ref(lab):
        tree, ga, gb = span[lab]
        txt = open(D.runlog(L.NEW, 'phaseA_b3_fc_' + tree[len('phaseA_b3_'):])).read()
        return txt, B.window(Gv6, ga, gb)

    # ---------------- H4
    print('\n==== H4: gem5\'s LLC policy matched to ChampSim\'s')
    h4a = h4b = n4a = n4b = 0
    agree = dis = ties = 0
    for prog, info in H4.items():
        lab, suf, tag, lo, hi = info
        ref_txt, w10 = ref(lab)
        c0 = L.counts(ref_txt)
        print(f'\n== {lab} ({prog}); window {lo} -> {hi} M')
        g10 = ki(w10['ss_getx'] + w10['mt_getx'], w10['insts'])
        mg10 = ki(w10['demand_acc'] - w10['demand_hits'], w10['insts'])
        r10 = ki(c0['C'], c0['ins']) / g10 if g10 else None
        print(f'   scored (gem5 TreePLRU, ChampSim lru): C {ki(c0["C"], c0["ins"]):.4f}/KI, G {g10:.4f}/KI, R {r10:.3f}; '
              f'M gem5 {mg10:.4f}/KI, ChampSim {ki(llc_misses(ref_txt), c0["ins"]):.4f}/KI')
        mc, mg = {}, {}
        for s in SETTINGS:
            if s == 'lru':
                txt = ref_txt
            else:
                t = f'phaseA_b3_hs_{s}_{suf}'
                if not os.path.isdir(os.path.join(HS_LOGS, t)):
                    print(f'   {s:6s} ChampSim: not measured (no run pulled)')
                    txt = None
                else:
                    txt = open(D.runlog(HS_LOGS, t)).read()
                    why = L.qualify(ref_txt, txt)
                    cf = os.path.join(HS_CFG, f'{s}_{prog}.json')
                    if not why and not os.path.exists(cf):
                        why = f'no pulled config {cf}'
                    if not why:
                        msgs = []
                        if not cfg(os.path.join(HS_CFG, f'ref_{prog}.json'), cf, s, out=msgs.append):
                            why = '; '.join(msgs)
                    if not why and L.counts(txt) == c0:
                        why = 'every count equals the LRU reference run: not the declared policy?'
                    if why:
                        print(f'   {s:6s} ChampSim: NOT USED -- {why}')
                        txt = None
            w, why = gwin(s, prog, info)
            if w is None:
                print(f'   {s:6s} gem5: not measured ({why})')
            if txt is None or w is None:
                continue
            c = L.counts(txt)
            cki, gki = ki(c['C'], c['ins']), ki(w['ss_getx'] + w['mt_getx'], w['insts'])
            r = cki / gki if gki else None
            mc[s], mg[s] = ki(llc_misses(txt), c['ins']), ki(w['demand_acc'] - w['demand_hits'], w['insts'])
            ok = in_band(r)
            if s == 'lru':
                n4a += 1
                h4a += ok
            else:
                n4b += 1
                h4b += ok
            rs = 'n/a' if r is None else f'{r:.3f}'
            print(f'   {s:6s} C {cki:.4f}/KI  G {gki:.4f}/KI  R {rs}  {"in the band" if ok else "OUTSIDE the band"}'
                  f'   M ChampSim {mc[s]:.4f}/KI, gem5 {mg[s]:.4f}/KI')
        if 'lru' in mg:
            wl, _ = gwin('lru', prog, info)
            gl = ki(wl['ss_getx'] + wl['mt_getx'], wl['insts'])
            print(f'   gem5 TreePLRU -> LRU: G {g10:.4f} -> {gl:.4f}/KI ({100 * (gl / g10 - 1):+.1f}%), '
                  f'M {mg10:.4f} -> {mg["lru"]:.4f}/KI ({100 * (mg["lru"] / mg10 - 1):+.1f}%)')
        if len(mc) >= 2:
            oc = ' < '.join(sorted(mc, key=mc.get))
            og = ' < '.join(sorted(mg, key=mg.get))
            a_, d_, t_ = order_pairs(mc, mg)
            agree, dis, ties = agree + a_, dis + d_, ties + t_
            print(f'   order by M: ChampSim {oc}; gem5 {og}; pairs agree {a_}, disagree {d_}, ties {t_}')
    print('\n== H4 reading')
    print(f'   P-H4a (gem5 LRURP, ChampSim lru): {h4a} of {n4a} measured (of 4) in the band -- {verdict(h4a, n4a, 4)}')
    print(f'   P-H4b (srrip, drrip): {h4b} of {n4b} measured (of 8) in the band -- {verdict(h4b, n4b, 8)}')
    print(f'   "the agreement holds under three matched LLC policies": {three_policies(h4a + h4b, n4a + n4b)}')
    print(f'   order by LLC demand misses (description): {agree} pairs agree, {dis} disagree, {ties} ties (< {100 * TIE:.0f}% in either)')

    # ---------------- H5
    print('\n==== H5: gem5\'s X86O3CPU')
    h5 = n5 = 0
    for prog, info in H5.items():
        lab, suf, tag, lo, hi = info
        ref_txt, wt = ref(lab)
        c0 = L.counts(ref_txt)
        print(f'\n== {lab} ({prog})')
        gt = ki(wt['ss_getx'] + wt['mt_getx'], wt['insts'])
        rt = ki(c0['C'], c0['ins']) / gt if gt else None
        w, why = gwin('o3', prog, info)
        if w is None:
            print(f'   O3: not measured ({why}); scored R (TimingSimpleCPU) {rt:.3f}')
            continue
        go = ki(w['ss_getx'] + w['mt_getx'], w['insts'])
        ro = ki(c0['C'], c0['ins']) / go if go else None
        ros = 'n/a' if ro is None else f'{ro:.3f}'
        print(f'   G Timing {gt:.4f}/KI, O3 {go:.4f}/KI;  R Timing {rt:.3f}, O3 {ros}'
              + ('' if ro is None else f' (O3 / Timing {ro / rt:.3f}); O3 {"in" if in_band(ro) else "OUTSIDE"} the band'))
        print(f'   window instructions per CPU: Timing {wt["cpus"]}, O3 {w["cpus"]}')
        _, _, gb = span[lab]
        ga_ = span[lab][1]
        ka, kb = f'o3/{prog}/l2_2MB_mi{lo}M/{tag}', f'o3/{prog}/l2_2MB_mi{hi}M/{tag}'
        if all(k in Mo for k in (ga_, gb)) and all(k in Mh for k in (ka, kb)):
            dt = [y - x for x, y in zip(Mo[ga_], Mo[gb])]
            do = [y - x for x, y in zip(Mh[ka], Mh[kb])]
            print(f'   loads / stores per KI in the window: Timing {ki(dt[1], dt[0]):.2f} / {ki(dt[2], dt[0]):.2f}, '
                  f'O3 {ki(do[1], do[0]):.2f} / {ki(do[2], do[0]):.2f}')
        else:
            print('   loads / stores per KI: not read (mix rows missing)')
        if prog in ('ocean4', 'canneal4') and ro is not None:
            n5 += 1
            h5 += in_band(ro)
    print('\n== H5 reading')
    print(f'   P-H5a (ocean and canneal, O3 in the band): {h5} of {n5} measured (of 2) -- {verdict(h5, n5, 2)}')
    print('   fluidanimate and vips: reported above, no prediction; the scored verdicts stand')


# ---------------------------------------------------------------- self-test
def selftest():
    fails = 0

    def check(name, cond):
        nonlocal fails
        print(f'   {"ok  " if cond else "FAIL"} {name}')
        fails += not cond

    def ini(path, sections):
        with open(path, 'w') as f:
            for s, lines in sections:
                f.write(f'[{s}]\n' + ''.join(x + '\n' for x in lines) + '\n')

    base = [('root', ['type=Root', 'children=system']),
            ('system', ['type=System', 'children=cpu0 ruby', 'redirect_paths=@D@/fs/proc']),
            ('system.cpu0', ['type=BaseTimingSimpleCPU', 'branchPred=Null', 'children=decoder workload', 'max_insts_any_thread=150000000', 'cpu_id=0']),
            ('system.cpu0.workload', ['type=Process', 'cmd=/bin/ocean -n514', 'cwd=@D@']),
            ('system.ruby.l2_cntrl0.L2cache', ['type=RubyCache', 'size=2097152', 'replacement_policy=' + P, 'children=replacement_policy']),
            (P, ['type=TreePLRURP', 'eventq_index=0', 'num_leaves=16'])]
    with tempfile.TemporaryDirectory() as t:
        o, n = os.path.join(t, 'orig'), os.path.join(t, 'new')
        os.makedirs(o)
        os.makedirs(n)
        sub = lambda secs_, d: [(s, [x.replace('@D@', d) for x in ls]) for s, ls in secs_]
        ini(os.path.join(o, 'config.ini'), sub(base, o))
        q = lambda *a: (lambda m: (a[0](*a[1:], out=m.append), m))([])

        def with_pol(pol_secs, edit=None):
            s = [x for x in sub(base, n) if x[0] != P] + pol_secs
            if edit:
                s = edit(s)
            ini(os.path.join(n, 'config.ini'), s)

        brr = lambda btp: ['type=BRRIPRP', f'btp={btp}', 'eventq_index=0', 'hit_priority=true', 'num_bits=2']
        with_pol([(P, ['type=LRURP', 'eventq_index=0'])])
        check('QH0 lru passes', q(qh0, o, n, 'lru')[0])
        check('QH0 lru is not srrip', not q(qh0, o, n, 'srrip')[0])
        with_pol([(P, brr(0))])
        check('QH0 srrip passes', q(qh0, o, n, 'srrip')[0])
        with_pol([(P, brr(3))])
        check('QH0 srrip with btp=3 fails', not q(qh0, o, n, 'srrip')[0])
        with_pol([(P, ['type=BRRIPRP', 'btp=0', 'hit_priority=false', 'num_bits=2'])])
        check('QH0 srrip without hit_priority fails', not q(qh0, o, n, 'srrip')[0])
        drr = [(P, ['type=DuelingRP', 'children=replacement_policy_a replacement_policy_b', 'constituency_size=512', 'team_size=16']),
               (P + '.replacement_policy_a', brr(3)), (P + '.replacement_policy_b', brr(100))]
        with_pol(drr)
        check('QH0 drrip passes', q(qh0, o, n, 'drrip')[0])
        with_pol(drr[:2])
        check('QH0 drrip without its second policy fails', not q(qh0, o, n, 'drrip')[0])
        with_pol([(drr[0][0], [x.replace('512', '64') for x in drr[0][1]])] + drr[1:])
        check('QH0 drrip with constituency 64 fails', not q(qh0, o, n, 'drrip')[0])
        with_pol([(P, ['type=LRURP'])], lambda s: [(a, [x.replace('size=2097152', 'size=8388608') for x in b]) for a, b in s])
        check('QH0 with the L2 size changed fails', not q(qh0, o, n, 'lru')[0])
        with_pol([(P, ['type=LRURP'])], lambda s: [(a, [x.replace('-n514', '-n1026') for x in b]) for a, b in s])
        r = q(qh0, o, n, 'lru')
        check('QH0 with the workload changed fails, naming it', not r[0] and any('workload' in x for x in r[1]))
        # QO0 on hand sections
        o3 = lambda edit=None: ini(os.path.join(n, 'config.ini'), (edit or (lambda s: s))(
            [(s, (['type=BaseO3CPU', 'branchPred=system.cpu0.branchPred', 'children=branchPred decoder fuPool workload',
                   'max_insts_any_thread=150000000', 'cpu_id=0', 'numIQEntries=64'] if s == 'system.cpu0' else ls))
             for s, ls in sub(base, n)] + [('system.cpu0.fuPool', ['type=FUPool']), ('system.cpu0.branchPred', ['type=TournamentBP'])]))
        o3()
        check('QO0 passes', q(qo0, o, n)[0])
        o3(lambda s: [(a, [x.replace('150000000', '50000000') for x in b]) for a, b in s])
        check('QO0 with max_insts_any_thread changed fails', not q(qo0, o, n)[0])
        o3(lambda s: [(a, [x.replace('-n514', '-n1026') for x in b]) for a, b in s])
        check('QO0 with the workload changed fails', not q(qo0, o, n)[0])
        o3(lambda s: [(a, [x.replace('size=2097152', 'size=8388608') for x in b]) for a, b in s])
        check('QO0 with the L2 size changed fails', not q(qo0, o, n)[0])
        o3(lambda s: s + [('system.extra', ['type=X'])])
        check('QO0 with a new section outside the CPUs fails', not q(qo0, o, n)[0])
        o3(lambda s: [(a, [x.replace('children=branchPred decoder fuPool workload', 'children=branchPred fuPool') for x in b]) for a, b in s])
        check('QO0 losing a CPU child fails', not q(qo0, o, n)[0])
        # qend
        open(os.path.join(n, 'run.log'), 'w').write(f'Exiting @ tick 9 {EXIT_OK}\n')
        open(os.path.join(n, 'stats.txt'), 'w').write('---------- Begin Simulation Statistics ----------\nfinalTick 9\n')
        check('qend at its stop', q(qend, n)[0] == 0)
        open(os.path.join(n, 'run.log'), 'w').write('panic: FIFO ordering violated\n')
        check('qend after a panic is OTHER', q(qend, n)[0] == 4)
        # cfg
        rj, nj = os.path.join(t, 'r.json'), os.path.join(t, 'n.json')
        c = {'num_cores': 4, 'LLC': {'sets': 2048, 'replacement': 'lru'}, 'sync_lock_word': 'request'}
        json.dump(c, open(rj, 'w'))
        json.dump(dict(c, LLC={'sets': 2048, 'replacement': 'srrip'}), open(nj, 'w'))
        check('cfg srrip passes', q(cfg, rj, nj, 'srrip')[0])
        check('cfg declared drrip fails', not q(cfg, rj, nj, 'drrip')[0])
        json.dump(dict(c, LLC={'sets': 1024, 'replacement': 'srrip'}), open(nj, 'w'))
        check('cfg with the LLC sets changed fails', not q(cfg, rj, nj, 'srrip')[0])
        # misses, order
        log = ('Region of Interest\ncpu0->LLC TOTAL        ACCESS:        100  HIT:  60  MISS:  40\n'
               'cpu0->LLC WRITE        ACCESS:         30  HIT:  25  MISS:   5\n'
               'cpu1->LLC TOTAL        ACCESS:        50  HIT:  20  MISS:  30\n')
        check('LLC misses (TOTAL - WRITE) = 65', llc_misses('cpu0->LLC TOTAL ACCESS: 9 HIT: 0 MISS: 9\n' + log) == 65)
        check('order: all agree', order_pairs({'lru': 1, 'srrip': 2, 'drrip': 3}, {'lru': 10, 'srrip': 20, 'drrip': 30}) == (3, 0, 0))
        check('order: one swap', order_pairs({'lru': 1, 'srrip': 2, 'drrip': 3}, {'lru': 20, 'srrip': 10, 'drrip': 30}) == (2, 1, 0))
        check('verdict: all measured, all in', verdict(4, 4, 4) == 'HOLDS')
        check('verdict: one measured outside', verdict(2, 3, 4) == 'FAILS')
        check('verdict: none measured is not a failure', verdict(0, 0, 8).startswith('not decided'))
        check('three policies: 12 of 12', three_policies(12, 12).startswith('YES'))
        check('three policies: 11 measured, all in', three_policies(11, 11).startswith('NOT DECIDED'))
        check('three policies: one outside', three_policies(10, 11).startswith('NO'))
        check('order: a 0.5% gap is a tie', order_pairs({'lru': 1, 'srrip': 1.005, 'drrip': 3}, {'lru': 10, 'srrip': 20, 'drrip': 30}) == (2, 0, 1))
    # QO0 on the speed test's real pair (the same program under both CPUs), if pulled
    ts, o3d = os.path.join(SPEED, 'G-ts-ruby.1'), os.path.join(SPEED, 'G-o3-ruby.1')
    if os.path.exists(os.path.join(ts, 'config.ini')) and os.path.exists(os.path.join(o3d, 'config.ini')):
        with tempfile.TemporaryDirectory() as t:   # the pair names its server directories: read them where they sit here
            for src, name in ((ts, 'G-ts-ruby.1'), (o3d, 'G-o3-ruby.1')):
                os.makedirs(os.path.join(t, name))
                open(os.path.join(t, name, 'config.ini'), 'w').write(
                    open(os.path.join(src, 'config.ini')).read().replace('/home/harshraj/speed/' + name, os.path.join(t, name)))
            m = []
            check('QO0 passes on the speed test\'s real TimingSimpleCPU / O3 pair', qo0(os.path.join(t, 'G-ts-ruby.1'), os.path.join(t, 'G-o3-ruby.1'), out=m.append))
            for x in m[-3:]:
                print('        ' + x)
            b = open(os.path.join(t, 'G-o3-ruby.1', 'config.ini')).read()
            open(os.path.join(t, 'G-o3-ruby.1', 'config.ini'), 'w').write(b.replace('max_insts_any_thread=30000000', 'max_insts_any_thread=30000001', 1))
            check('QO0 fails on that pair with one CPU\'s stop changed', not qo0(os.path.join(t, 'G-ts-ruby.1'), os.path.join(t, 'G-o3-ruby.1'), out=m.append))
    else:
        print(f'   (the speed test\'s real pair is not under {SPEED}: not checked)')
    print(f'SELF-TEST {"PASSES" if not fails else f"FAILS ({fails})"}')
    return not fails


def main(a):
    if not a:
        sys.exit(__doc__)
    m = a[0]
    if m == 'qh0' and len(a) == 4:
        sys.exit(0 if qh0(a[1], a[2], a[3]) else 1)
    if m == 'qo0' and len(a) == 3:
        sys.exit(0 if qo0(a[1], a[2]) else 1)
    if m == 'qend' and len(a) in (2, 3):
        sys.exit(qend(a[1], len(a) == 2 or a[2] == '1'))
    if m == 'cfg' and len(a) == 4:
        sys.exit(0 if cfg(a[1], a[2], a[3]) else 1)
    if m == 'rows':
        sys.path.insert(0, HERE)
        import b3_score as B
        B.gem5_rows(a[1] if len(a) > 1 else os.path.join(ROOT, 'simulator/results/hset/gem5'))
        return
    if m == 'mix':
        mix(a[1] if len(a) > 1 else os.path.join(ROOT, 'simulator/results/hset/gem5'))
        return
    if m == 'score' and len(a) == 4:
        score(a[1], a[2], a[3])
        return
    if m == 'selftest':
        sys.exit(0 if selftest() else 1)
    sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
