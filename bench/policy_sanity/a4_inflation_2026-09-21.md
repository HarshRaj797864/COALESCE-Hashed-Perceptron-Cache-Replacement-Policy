# A4 — why the magnitudes ran ~2x published, and unevenly

> **Not affected by the 2026-09-23 double-count.** That defect doubles LLC
> counters only when `NUM_CPUS > 1`; A4 is single core, so `plain_printer`
> emits one stat block and every figure here is correct as printed. Worth
> stating because the Phase A sweep's per-instruction rates were 2x and the two
> datasets were briefly on different bases.

**2026-09-21.** Follow-up to `a4_results_2026-09-21.md`, which recorded the
uneven inflation as an open observation. Reproduce with:

```bash
python3 scripts/run_a4.sh.py inflation < bench/policy_sanity/a4_rows_2026-09-21.txt
```

The 132 raw rows are committed alongside this file, so nothing here depends on
re-reading a summary.

## The question

A4's geomeans over LRU came out at Hawkeye 2.13x, Mockingjay 1.98x and SHiP
1.25x their published values. The explanation recorded at the time was
benchmark-set enrichment: our twelve traces were selected for LLC sensitivity,
the published averages span SPEC2006 + SPEC2017 + GAP including benchmarks
where every policy ties. That explains *inflation*, but it predicts a similar
lift for all three policies. 2.13x against 1.25x is not similar.

The guess appended to it — "reuse-predicting policies gain more from
LLC-pressured workloads than SHiP's signature scheme does" — is testable.
It is also **wrong**.

## First: the runs are honest

All 132 runs simulated 50.00M instructions, derived as IPC x cycles from each
log rather than from the figure the harness requested. A wrapped or truncated
run still prints an IPC, so this is checked rather than assumed. No run
deviates by more than 1%.

## The pressure explanation is refuted

Rank the traces by LRU's LLC load MPKI and split at the median. Enrichment
predicts the low-pressure half lands near published and the high-pressure half
overshoots.

| policy | published | low half | high half | low/pub | high/pub |
|---|---|---|---|---|---|
| ship | +3.4% | +5.14% | +3.38% | 1.51x | **0.99x** |
| hawkeye | +4.5% | +10.56% | +8.65% | 2.35x | 1.92x |
| mockingjay | +5.7% | +12.85% | +9.75% | 2.25x | 1.71x |

It comes out backwards. SHiP's **high**-pressure half is 0.99x published —
dead on — and its low-pressure half is the inflated one. Hawkeye and Mockingjay
are inflated in both halves roughly equally, so pressure is not separating them
from SHiP at all.

The correlation of gain with pressure says the same thing: SHiP +0.54, Hawkeye
+0.43, Mockingjay +0.41. The prediction required the most-inflated policies to
have the steepest slope. The **least** inflated one does.

## The axis is reuse, not pressure

Split instead on how much reuse LRU already finds — its LLC load hit rate.

| policy | published | LRU hit <5% | LRU hit >=5% | no-reuse/pub | has-reuse/pub |
|---|---|---|---|---|---|
| ship | +3.4% | +5.56% | +2.97% | 1.64x | 0.87x |
| hawkeye | +4.5% | +14.39% | +5.02% | 3.20x | 1.12x |
| mockingjay | +5.7% | +17.21% | +5.67% | 3.02x | 0.99x |

The gap between an OPT-reconstructing policy and a signature-based one is the
quantity that actually varies, so correlate it directly rather than inferring
it from two separate correlations:

```
hawkeye-minus-ship gap   vs LRU hit rate  rho -0.74   (leave-one-out -0.85 .. -0.64)
                         vs LLC MPKI      rho +0.37
mockingjay-minus-ship    vs LRU hit rate  rho -0.72
                         vs LLC MPKI      rho +0.31
```

Per trace, ordered by how much reuse LRU finds:

    462.libquantum   LRU hit  0.0%   gap  +4.57pp
    470.lbm          LRU hit  0.0%   gap +17.97pp
    410.bwaves       LRU hit  0.0%   gap  +3.09pp
    429.mcf          LRU hit  1.3%   gap +14.81pp
    482.sphinx3      LRU hit  4.5%   gap  +3.12pp
    437.leslie3d     LRU hit 12.7%   gap  +5.00pp
    450.soplex       LRU hit 16.7%   gap  +4.03pp
    471.omnetpp      LRU hit 20.0%   gap  +0.25pp
    483.xalancbmk    LRU hit 55.2%   gap  +1.52pp
    473.astar        LRU hit 70.2%   gap  -0.26pp

The two axes are not independent — LRU hit rate against MPKI is rho -0.47 — so
part of the weak MPKI signal is reuse leaking through. But the gap tracks reuse
roughly twice as tightly as it tracks pressure, and the sign of the MPKI
correlation is what that leakage would produce.

## The mechanism

On a trace where LRU almost never hits, there is no recency to exploit and
nearly every line is dead on arrival. SHiP's contribution is learning *which PC
signatures* produce dead lines and inserting those at distant RRPV — which buys
little when the answer is "all of them". Hawkeye and Mockingjay reconstruct
OPT's decisions and can still pick out the minority of lines worth protecting
against the stream, which is precisely the cache-averse/cache-friendly
separation they are built for.

Half our twelve-trace subset is that kind of workload — libquantum, lbm and
bwaves at 0.0% LRU hit rate, mcf at 1.3%. Selecting for LLC sensitivity
selected, in practice, for streaming and thrashing. That class inflates every
policy's headline number and inflates the OPT-reconstructing ones far more, so
the uneven inflation follows from the benchmark composition after all — just
along a different axis than the one recorded.

## What is solid and what is not

**Solid.** The refutation of the pressure explanation, and the reuse
correlation. rho -0.74 holds between -0.64 and -0.85 under every
leave-one-out, both policy pairs agree, and the split is stable for any
threshold from 5% to 15%.

**Not solid.** The has-reuse half landing within 13% of published
(0.87x / 1.12x / 0.99x) is striking but rests on **five traces**. Dropping
450.soplex alone takes it to 0.18x / 0.49x / 0.50x. Below a 5% cut the picture
also changes, because 482.sphinx3 at 4.5% LRU hit rate is the one trace where
SHiP too gains enormously (+29.5%) and it moves the whole half.

So this is a finding about the **mechanism**, not a replacement set of
validation numbers. The right claim is "the inflation is explained by the
subset being half streaming workloads, a class that separates OPT
reconstruction from signature-based insertion", not "the baselines reproduce
the literature when restricted to traces with reuse" — n=5 does not support
the second.

## Consequence for the paper

The A4 table can now state why it reads high instead of noting it and moving
on, which is the difference between a reviewer reading it as a caveat and
reading it as an unexplained discrepancy. It also means the honest way to
report A4 is with the per-trace LRU hit rate beside each row, since that column
is what determines how far a policy departs from its published figure.

Nothing here changes the two checks A4 passed: every policy still behaves
distinctly on all ten discriminating traces, and the ordering still matches
Mockingjay HPCA'22 Table I.
