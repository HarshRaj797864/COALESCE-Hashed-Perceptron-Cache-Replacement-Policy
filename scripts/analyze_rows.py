#!/usr/bin/env python3
"""Re-derive the V7 checks and the policy rankings from a rows file.

The rows file is `run_phase_a.sh rows` output, pulled to the laptop:

  ssh -n -p 2222 user@your-server 'bash ~/run_phase_a.sh rows' > bench/policy_sanity/phasea_rows_vN.txt

Usage:
  scripts/analyze_rows.py ROWS check TREE...
      integrity, extraction identity, run length, overlay, distinct cycles
  scripts/analyze_rows.py ROWS same TREE_A TREE_B
      every configuration present in both trees must match in every column
  scripts/analyze_rows.py ROWS rank BASE_TREE[,BASE_TREE...] ARM_TREE...
      baselines from the BASE_TREEs, the first listed tree winning where two
      hold the same row (their COALESCE-family rows are dropped as pre-fix);
      COALESCE-family rows from each ARM_TREE labelled with the arm; one
      table per configuration, fastest first
  scripts/analyze_rows.py ROWS compare TREES:REGIME TREES:REGIME
      two rankings of the same policies at each workload and core count --
      e.g. one regime against the other -- with Kendall's tau over the
      baselines and over every policy both sides hold, and the LRU LLC load
      hit rate of each side, which says whether the two are at equal pressure.
      Compare pressure across binaries on the load+RFO rate, which it also
      prints: a B3 v3+ binary issues read-modify-write loads as RFOs.
      TREES is a comma list read as in `rank`; a tree whose name ends in
      armA/armB contributes its COALESCE-family rows, labelled with the arm

Nothing here trusts a summary: every number comes from the row columns, and
the rank table states the gap to the adjacent policy, not only to LRU.
"""
import sys
from collections import defaultdict

COLS = ("tree pol wl cores rg st vm tw max_cyc min_cyc ins load_acc load_hit "
        "tot_acc tot_hit wr_acc wr_hit rfo_acc rfo_hit tr_acc tr_hit aliased inval").split()
NUMERIC = COLS[8:]
FAMILY = ("coalesce", "coalesce_no_mesi", "coalesce_no_sharer")
MIN_INSTR_PER_CORE = 100_000_000


def load(path):
    rows = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            parts = line.split()
            if not parts:
                continue
            if len(parts) != len(COLS):
                sys.exit(f"{path}:{n}: {len(parts)} columns, expected {len(COLS)}")
            r = dict(zip(COLS, parts))
            r["cores"] = int(r["cores"])
            for c in NUMERIC:
                r[c] = int(r[c])
            rows.append(r)
    return rows


def cfg(r):
    return (r["wl"], r["cores"], r["rg"])


def cfg_str(c):
    return f"{c[0]} {c[1]}c {c[2]}"


def check(rows, trees):
    bad = 0

    def fail(msg):
        nonlocal bad
        bad += 1
        print(f"   FAIL {msg}")

    for tree in trees:
        sel = [r for r in rows if r["tree"] == tree]
        print(f"== {tree}: {len(sel)} rows ==")
        if not sel:
            fail("no rows"); continue
        done = [r for r in sel if r["st"] == "complete"]
        pending = [r for r in sel if r["st"] != "complete"]
        if pending:
            print(f"   {len(pending)} INCOMPLETE (in flight or killed) -- excluded from every check below:")
            for r in pending:
                print(f"      {r['pol']} {cfg_str(cfg(r))}")
        for r in done:
            tag = f"{r['pol']} {cfg_str(cfg(r))}"
            if r["vm"] != "ok":
                fail(f"{tag}: page pool exhausted")
            if r["tw"] != "ok":
                fail(f"{tag}: trace wrapped")
            if r["tot_acc"] != r["load_acc"] + r["wr_acc"] + r["rfo_acc"] + r["tr_acc"]:
                fail(f"{tag}: TOTAL accesses != LOAD+WRITE+RFO+TRANSLATION")
            if r["tot_hit"] != r["load_hit"] + r["wr_hit"] + r["rfo_hit"] + r["tr_hit"]:
                fail(f"{tag}: TOTAL hits != LOAD+WRITE+RFO+TRANSLATION")
            if r["min_cyc"] != r["max_cyc"]:
                fail(f"{tag}: min_cycles {r['min_cyc']} != max_cycles {r['max_cyc']}")
            if r["ins"] < MIN_INSTR_PER_CORE * r["cores"]:
                fail(f"{tag}: {r['ins'] / r['cores']:,.0f} instructions per core")
            if r["rg"] == "private" and (r["inval"] != 0 or r["aliased"] != 0):
                fail(f"{tag}: private regime with inval={r['inval']} aliased={r['aliased']}")
            if r["rg"] == "shared" and (r["inval"] == 0 or r["aliased"] == 0):
                fail(f"{tag}: shared regime with inval={r['inval']} aliased={r['aliased']}")
        if done:
            per_core = [r["ins"] / r["cores"] for r in done]
            print(f"   complete {len(done)}; instructions per core {min(per_core):,.0f} .. {max(per_core):,.0f}")

        # shared invalidations must rise with core count, per policy (canneal)
        byp = defaultdict(dict)
        for r in done:
            if r["rg"] == "shared" and r["wl"] == "canneal":
                byp[r["pol"]][r["cores"]] = r["inval"]
        for pol, d in sorted(byp.items()):
            ks = sorted(d)
            if len(ks) > 1 and any(d[a] >= d[b] for a, b in zip(ks, ks[1:])):
                fail(f"{pol}: shared invalidations do not rise with cores: {d}")

        # No two policies may share a cycle count in one configuration -- how
        # Hawkeye == SRRIP was caught. One exception, checked, not assumed: an
        # LLC with no miss in the region of interest never evicts, so no policy
        # is ever consulted and all must agree (barnes 4c at the scaled
        # geometry; internals_finding_2026-09-21.md).
        byc = defaultdict(list)
        for r in done:
            byc[cfg(r)].append(r)
        for c, rs in sorted(byc.items()):
            seen = defaultdict(list)
            for r in rs:
                seen[r["max_cyc"]].append(r)
            for mc, same_rs in seen.items():
                if len(same_rs) < 2:
                    continue
                pols = ", ".join(r["pol"] for r in same_rs)
                if all(r["tot_hit"] == r["tot_acc"] for r in same_rs):
                    print(f"   note {cfg_str(c)}: {pols} share max_cycles {mc} -- expected: "
                          f"zero LLC misses in the ROI, so no eviction ever consults the policy")
                else:
                    fail(f"{cfg_str(c)}: {pols} share max_cycles {mc}")
    print(f"== {'ALL CHECKS PASS' if bad == 0 else f'{bad} FAILURE(S)'} ==")
    return bad


def same(rows, a, b):
    ra = {(r["pol"],) + cfg(r): r for r in rows if r["tree"] == a and r["st"] == "complete"}
    rb = {(r["pol"],) + cfg(r): r for r in rows if r["tree"] == b and r["st"] == "complete"}
    common = sorted(set(ra) & set(rb))
    print(f"== {a} vs {b}: {len(common)} configuration(s) in both ==")
    diff = 0
    for k in common:
        d = [c for c in NUMERIC if ra[k][c] != rb[k][c]]
        label = f"{k[0]} {cfg_str(k[1:])}"
        if d:
            diff += 1
            print(f"   DIFFER {label}: " + ", ".join(f"{c} {ra[k][c]} vs {rb[k][c]}" for c in d))
        else:
            print(f"   identical  {label}  max_cycles {ra[k]['max_cyc']:,}  (all {len(NUMERIC)} columns)")
    if not common:
        print("   nothing to compare"); return 1
    return diff


def is_arm(tree):
    return tree.endswith(("armA", "armB"))


def collect(rows, trees, regime=None):
    """{config: {label: row}} from the trees in order; the first tree to hold
    a (label, config) wins. COALESCE-family rows count only from arm trees
    (labelled pol@armX); anywhere else they are pre-fix and dropped."""
    out = defaultdict(dict)
    for tree in trees:
        for r in rows:
            if r["tree"] != tree or r["st"] != "complete":
                continue
            if regime and r["rg"] != regime:
                continue
            if r["pol"] in FAMILY:
                if not is_arm(tree):
                    continue
                label = f"{r['pol']}@{tree.rsplit('_', 1)[-1]}"
            else:
                label = r["pol"]
            out[cfg(r)].setdefault(label, r)
    return out


def rank(rows, base, arms):
    got = collect(rows, base.split(",") + sorted(arms))
    entries = {c: list(d.items()) for c, d in got.items()}
    for c in sorted(entries):
        es = entries[c]
        if not any(lbl.split("@")[0] in FAMILY for lbl, _ in es):
            continue  # nothing of COALESCE's to place in this configuration
        lru = next((r for lbl, r in es if lbl == "lru"), None)
        print(f"== {cfg_str(c)}  ({len(es)} policies; baselines from {base}) ==")
        if lru is None:
            print("   no LRU row -- cannot state speedups"); continue
        es.sort(key=lambda e: e[1]["max_cyc"])
        print(f"   {'':3} {'policy':28} {'max_cycles':>14} {'vs LRU':>8} {'gap to next':>11} {'LLC load hit':>12}")
        for i, (lbl, r) in enumerate(es):
            sp = lru["max_cyc"] / r["max_cyc"] - 1
            gap = ""
            if i + 1 < len(es):
                gap = f"{es[i + 1][1]['max_cyc'] / r['max_cyc'] - 1:+.2%}"
            hit = r["load_hit"] / r["load_acc"] if r["load_acc"] else 0.0
            print(f"   {i + 1:>2}. {lbl:28} {r['max_cyc']:>14,} {sp:>+8.2%} {gap:>11} {hit:>12.2%}")
    return 0


def load_rfo_hit(r):
    """LLC hit rate over loads and RFOs together. From B3 v3 step 1 on
    (f23e03f), a read-modify-write's load is issued as an RFO, so the load-only
    rate of a newer binary is not the older binary's: canneal 16c, private,
    2 MB per core, LRU reads 26.41% on the older binary and 38.28% on
    champsim_b3v4. Loads plus RFOs is the same on both (26.42%), so it is the
    measure of pressure to compare across binaries (2026-10-14)."""
    acc = r["load_acc"] + r["rfo_acc"]
    return (r["load_hit"] + r["rfo_hit"]) / acc if acc else 0.0


def kendall_tau(order_a, order_b):
    """Kendall's tau between two orderings of the same items (no ties)."""
    pos = {x: i for i, x in enumerate(order_b)}
    n, conc, disc = len(order_a), 0, 0
    for i in range(n):
        for j in range(i + 1, n):
            if pos[order_a[i]] < pos[order_a[j]]:
                conc += 1
            else:
                disc += 1
    return (conc - disc) / (n * (n - 1) / 2) if n > 1 else float("nan")


def compare(rows, spec_a, spec_b):
    sides = []
    for spec in (spec_a, spec_b):
        trees, _, regime = spec.partition(":")
        if regime not in ("shared", "private"):
            sys.exit(f"compare: '{spec}' needs :shared or :private")
        got = collect(rows, trees.split(","), regime)
        sides.append(({(c[0], c[1]): d for c, d in got.items()}, spec))
    (a, la), (b, lb) = sides
    for key in sorted(set(a) & set(b)):
        common = sorted(set(a[key]) & set(b[key]))
        if "lru" not in common or len(common) < 3:
            continue
        print(f"== {key[0]} {key[1]}c: {len(common)} policies in both ==")
        print(f"   A = {la}\n   B = {lb}")
        orders = []
        for side in (a, b):
            orders.append(sorted(common, key=lambda p, s=side: s[key][p]["max_cyc"]))
        for name, side in (("A", a), ("B", b)):
            lru = side[key]["lru"]
            print(f"   {name}: LRU LLC load hit {lru['load_hit'] / lru['load_acc']:.2%}, load+RFO hit {load_rfo_hit(lru):.2%}")
        print(f"   {'':3} {'A order':24} {'vs LRU':>8}    {'B order':24} {'vs LRU':>8}")
        for i in range(len(common)):
            pa, pb = orders[0][i], orders[1][i]
            sa = a[key]["lru"]["max_cyc"] / a[key][pa]["max_cyc"] - 1
            sb = b[key]["lru"]["max_cyc"] / b[key][pb]["max_cyc"] - 1
            print(f"   {i + 1:>2}. {pa:24} {sa:>+8.2%}    {pb:24} {sb:>+8.2%}")
        base_only = [p for p in common if "@" not in p]
        ta = kendall_tau([p for p in orders[0] if p in base_only], [p for p in orders[1] if p in base_only])
        print(f"   Kendall tau, {len(base_only)} baselines: {ta:+.2f}", end="")
        if len(common) > len(base_only):
            print(f"   all {len(common)}: {kendall_tau(orders[0], orders[1]):+.2f}")
        else:
            print()
    return 0


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    rows = load(argv[1])
    cmd, args = argv[2], argv[3:]
    if cmd == "check" and args:
        return 1 if check(rows, args) else 0
    if cmd == "same" and len(args) == 2:
        return 1 if same(rows, *args) else 0
    if cmd == "rank" and len(args) >= 2:
        return rank(rows, args[0], set(args[1:]))
    if cmd == "compare" and len(args) == 2:
        return compare(rows, *args)
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
