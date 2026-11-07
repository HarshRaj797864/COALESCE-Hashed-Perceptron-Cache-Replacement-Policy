# First sweep on verified traces and a verified build

> **COALESCE rows measured on the pre-fix policy** (added 2026-09-23). COALESCE's
> ghost-tag rescue could not tell one address from another until `97aa5da`;
> every COALESCE-family figure below predates that fix and is provisional until
> re-run. The other policies' rows are unaffected. See
> `coalesce_ghost_defect_2026-09-23.md`, "Which COALESCE findings are now
> provisional".

**2026-09-20.** 46 of 52 jobs complete. 50M warmup + 100M simulation per core,
shared-VMEM overlay, **fixed 2 MB LLC** (the historical geometry), ChampSim
@ develop f9ed890e. Metric is `max_cycles` across cores, as in the paper.

Ocean is excluded entirely: 9 runs wrapped their trace 3.3x and 4 more are
incomplete. Those results are void.

## Geomean speedup over LRU, three workloads

| rank | policy | geomean |
|---|---|---|
| 1 | mockingjay | **+7.05%** |
| 2 | hawkeye | **+6.73%** |
| 3 | **coalesce** | **+6.72%** |
| 4 | srrip | +6.60% |
| 5 | srrip_bias | +6.50% |
| 6 | coalesce_no_mesi | +6.28% |
| 7 | drrip | +5.02% |
| 8 | ship | +4.47% |
| 9 | random | +2.32% |
| 10 | coalesce_no_sharer | +1.48% |

**COALESCE is third, 0.33 points behind Mockingjay and 0.12 ahead of SRRIP.**
On a single run per configuration, third through sixth are not distinguishable.

## Per workload

- **canneal 8c** — coalesce 1st at 204,459,124 cycles, but SRRIP is +0.12% and
  Mockingjay +0.12%. A tie, not a win.
- **barnes 4c** — coalesce **7th of 11**. The whole field spans 2.07%; barnes
  fits in the LLC, exactly as Reviewer 2 said.
- **water 8c** — coalesce **5th of 11**. Mockingjay wins.

## What changed against the submitted paper

| policy | paper, canneal 8c | now |
|---|---|---|
| Mockingjay | **last**, +30.5% behind | **tied 2nd**, +0.12% |
| coalesce_no_sharer | **1st**, beat COALESCE | **last**, +13.15% |
| LRU | last-ish, +30.0% | 9th, +12.82% |

The Mockingjay and coalesce_no_sharer rankings invert completely. Both follow
directly from the audit: Mockingjay was broken and is now a faithful port, and
the old numbers came from duplicated traces on a policy set where nine of
eleven were not the policy they claimed.

**Fixing the baselines removed COALESCE's advantage.** That is the honest
summary. It is consistent with `docs/framing.md`: the policy was never the
contribution.

## Two observations worth keeping

**Aliased fills are constant across policies** -- 907,148 to 909,196 on canneal
8c, a 0.23% spread. Aliasing is a VMEM-level event and must not depend on the
replacement policy. It does not. That is a strong internal consistency check on
the overlay.

**Invalidations vary 5.7x with policy** -- 110,757 (Mockingjay) to 633,443
(SHiP) on the same workload and traces. Interpret with care: a policy that
evicts sooner gives a line less chance to be invalidated, so low invalidation
counts may measure eviction aggressiveness rather than coherence behaviour.
Mockingjay has the fewest invalidations *and* near-best cycles, which is
consistent with that reading.

## The caveat that matters

This is the **2 MB LLC**, and `llc_sizing_2026-09-19.md` establishes that the
fixed 2 MB geometry suppresses the effect under study: coherence traffic is
2.6-3.0% of LLC accesses there against 7-19% when the cache scales with core
count. So this table says what the *paper's configuration* measures, not what is
true of a realistic machine. The scaled sweep supersedes it.
