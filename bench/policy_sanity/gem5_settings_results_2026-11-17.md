# H4 and H5: gem5's LLC policy and CPU model as settings -- results (2026-11-17)

Design: `gem5_settings_design_2026-11-14.md` (pre-registered `3c55d96`,
built and rehearsed `fffd9d1`, amendment 1 `9a0be12`: the policy set through
`Root.getInstance()`). H4's gem5 chain ended 2026-11-16 22:49, H5's
2026-11-17 08:39, the ChampSim chain 2026-11-16 11:40 (server time). Pulled
2026-11-17 (`bash scripts/hset_all.sh pull`: 32 gem5 statistics, 8 ChampSim
logs, 12 originals) and scored by the design's commands:

```
python3 scripts/hset_check.py rows simulator/results/hset/gem5 > bench/policy_sanity/hset_gem5_rows_v1.txt
python3 scripts/hset_check.py mix  simulator/results/hset/gem5 > bench/policy_sanity/hset_gem5_mix_v1.txt
python3 scripts/hset_check.py mix  simulator/results/hset/orig > bench/policy_sanity/hset_orig_mix_v1.txt
HS_LOGS=simulator/results/hset/logs HS_CFG=simulator/results/hset/cfg \
  python3 scripts/hset_check.py score <the three files>   # -> hset_score_v1.txt
```

## Checks

- QH0 (server): 24 of 24 pass (each run reads exactly the declared
  `LRURP` / `BRRIPRP` / `DuelingRP` section, nothing else differs).
- QO0 (server): 8 of 8 pass (4, 5, 5 and 7 CPUs TimingSimpleCPU -> O3).
- QS1: all 32 gem5 runs ended at their instruction stop (one dump each).
- QH2: all 8 ChampSim runs qualify against their F-C reference, and their
  configs equal the reference's but `LLC.replacement` (none NOT USED).
- The scorer's parser reproduces the 14 committed F-C rows.

## H4: gem5's L2 policy matched to ChampSim's

R_g5 = C / G (band 0.5-2). "scored" is the F-C row (gem5 TreePLRU, ChampSim
lru).

| program | scored | lru (LRURP) | srrip (BRRIP btp=0) | drrip (DuelingRP) |
|---|---|---|---|---|
| ocean 2 MB | 0.712 | 0.694 | 1.986 | 0.754 |
| canneal 4c 2 MB | 1.018 | 1.009 | 1.700 | 1.479 |
| **lunc** | 1.830 | **2.302** | **3.247** | **3.098** |
| radix | 0.988 | 0.985 | 1.007 | 0.985 |

- **P-H4a FAILS** (3 of 4: lunc outside under LRURP). It was the one named
  at risk beforehand.
- **P-H4b FAILS** (6 of 8: lunc outside under both).
- **"The agreement holds under three matched LLC policies": NO.** The paper
  gives the count, **9 of 12**, and names lunc as the one outside, under all
  three non-default policies. Ocean, canneal and radix stay in the band
  under every policy; ocean's srrip pair is at the band's edge (1.986).
- **gem5 TreePLRU -> LRU** (how much gem5's default mattered): G moves +2.6%
  (ocean), +0.9% (canneal), +0.2% (radix), **-20.5% (lunc)**; gem5's L2
  demand misses move at most 0.6% in each. So lunc's gem5 sharing count
  depends on which line the L2 evicts, at nearly the same miss count. Not
  diagnosed; a candidate (untested): gem5's L2 is inclusive, so the victim
  choice decides which private copies, and their sharers, are back-
  invalidated.
- With H2's s\*, each of the 12 also gets its label: **pending** (H2 is not
  scored yet).

**LLC demand misses per KI (M), described, not tested:**

| program | ChampSim lru / srrip / drrip | gem5 lru / srrip / drrip |
|---|---|---|
| ocean | 18.94 / 20.19 / 15.24 | 22.06 / 33.39 / 19.55 |
| canneal 4c | 4.17 / 3.38 / 3.69 | 4.46 / 7.80 / 3.62 |
| lunc | 2.27 / 1.74 / 2.04 | 5.91 / 10.03 / 5.81 |
| radix | 21.52 / 21.49 / 21.52 | 21.75 / 79.87 / 22.70 |

- Over the 12 pairs of settings, the order by M agrees in 5, disagrees in 4,
  and 3 are ties (< 1% in either simulator, all radix). With three policies
  no ranking statistic is significant, and none is claimed.
- All four disagreements involve srrip (canneal and lunc, srrip against
  lru and against drrip). gem5's BRRIP with `btp=0` misses 1.5-3.7x as often
  as its LRU (radix 79.87 against 21.75), while ChampSim's srrip misses at
  most 6.6% more than its lru (ocean 20.19 against 18.94), fewer on canneal
  and lunc, and as many on radix. So the
  design's "BRRIP btp=0 = ChampSim's srrip as it behaves" does not hold in
  behaviour inside Ruby. A candidate, from the design's "differences that
  stay": Ruby updates an L2 line's replacement state only on a fill and
  where the protocol calls `setMRU`, so a line inserted at RRPV 3 may not be
  promoted on the hits ChampSim's module sees. Not diagnosed.

## H5: gem5's X86O3CPU

| program | R_g5 Timing | R_g5 O3 | O3 / Timing |
|---|---|---|---|
| ocean 2 MB | 0.712 | 0.739 | 1.038 |
| canneal 4c 2 MB | 1.018 | 1.019 | 1.001 |
| fluidanimate | 0.400 | 0.391 | 0.979 |
| vips | 0.308 | **0.165** | 0.535 |

- **P-H5a HOLDS** (ocean and canneal in the band under O3).
- fluidanimate and vips (no prediction): both stay outside the band, so
  their disagreement does not depend on gem5's CPU model; vips moves further
  out (gem5's G rises from 0.0081 to 0.0152 /KI). The scored verdicts stand.
- Reported: each traced CPU's window instructions under O3 are within 1.7%
  of TimingSimpleCPU's (the largest, ocean's CPU 2: 100,225,395 against
  98,591,904); loads and stores per KI agree to 0.2% (O3 against Timing:
  ocean 313.39 / 72.08 against 313.47 / 72.23; fluidanimate 226.40 / 37.00
  against 226.06 / 37.00; vips 188.92 / 55.02 against 188.98 / 55.02;
  canneal equal to two decimals).

## What the paper states

- The B3 agreement does not depend on gem5's CPU model (ocean, canneal:
  O3 / Timing 1.04, 1.00).
- Under three gem5 LLC policies matched to ChampSim's, 9 of 12 R_g5 values
  stay in the band; lunc leaves it under each (2.30-3.25), and its gem5
  sharing count moves 20% between TreePLRU and LRU at the same miss count.
  lunc's scored agreement (1.830, near the band's top) is therefore stated
  as sensitive to gem5's L2 replacement.
- Matching a replacement policy by name across the two simulators does not
  match its behaviour (srrip above); the policy ordering by LLC misses agrees
  in 5 of 9 non-tied pairs. This is a caution for comparing policy rankings
  across simulators, not a test.

Nothing is tuned; no scored verdict changes.
