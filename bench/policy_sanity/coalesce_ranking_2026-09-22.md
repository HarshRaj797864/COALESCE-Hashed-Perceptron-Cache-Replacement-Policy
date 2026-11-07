# Where COALESCE ranks, and why

> **Measured on the pre-fix policy** (added 2026-09-23). COALESCE's ghost-tag
> rescue could not tell one address from another until `97aa5da`; every
> COALESCE figure below predates that fix and is provisional until re-run. See
> `coalesce_ghost_defect_2026-09-23.md`, "Which COALESCE findings are now
> provisional".


> ## ⚠️ ABSOLUTE PER-INSTRUCTION RATES BELOW ARE 2x TOO HIGH (found 2026-09-23)
>
> `plain_printer.cc:184-199` prints the whole cache-stat block twice when
> `NUM_CPUS > 1`, and `begin_phase()` zeroes both stat sets while `end_phase()`
> copies sim into roi — so the two blocks are **identical** and the extraction
> summed them. Every LLC counter in the multi-core rows is exactly **2x**.
>
> | quantity | affected? |
> |---|---|
> | hit rates, and anything "vs SRRIP" or "vs best" | **no** — both sides doubled |
> | policy rankings, `max_cycles`, cycle percentages | **no** — printed once |
> | improvement factors between geometries | **no** — both sides doubled |
> | **absolute MPKI, TR miss/KI, wb miss/KI, non-load MPKI** | **YES — halve them** |
> | `invals/KI`, `aliased_fills` | **no** — extracted with `grep -m1`, first match only |
> | anything from A4 | **no** — single core skips the first block |
>
> No conclusion in this document changes; every comparison here is a ratio.
>
> **Corrected data is available**: `phasea_rows_v5.txt`. Verified against v4 —
> all 130 rows in common have their LLC counters exactly halved, while
> `max_cycles`, `instrs`, `inv` and `af` are identical in 130/130. The factor
> really was exactly 2, so halving a figure below is exact rather than
> approximate. Fixed in `2e74427`.

> ## ⚠️ PARTIALLY REFUTED 2026-09-22 — see `verification_2026-09-22.md`
>
> Audited the same day it was written. Two claims below do not survive:
>
> - **"COALESCE is the best policy of eleven, +12.82% over LRU"** is misleading.
>   Six of eleven policies sit within **0.74%** of first and COALESCE leads
>   SRRIP by **0.12%**. It is a six-way tie in which COALESCE is nominally
>   first, not a win. The +12.82% measures how badly LRU does, not how well
>   COALESCE does.
> - **"The gain correlates +0.64 with capacity pressure, so the advantage is
>   pressure and not coherence"** is refuted. Every policy correlates positively
>   on that metric (hawkeye +0.96, ship +0.93, srrip +0.89) and COALESCE is the
>   *lowest* of any real policy. It is an artifact of measuring gain over LRU.
>   On a metric not anchored to LRU, COALESCE is rho +0.00.
>
> What survives: COALESCE is inside the leading tie at 2 MB and clearly outside
> it at 2 MB/core (+3.52% and +3.00% behind the winner). Read the rest with
> those two corrections applied.

**2026-09-22.** From `phasea_rows_v4.txt`, 111 usable runs. Supersedes the
"COALESCE does not work" summary in `phasea_results_2026-09-22.md` §2, which
read only the scaled sweep and was too narrow.

## The ranking depends almost entirely on LLC size

| configuration | COALESCE | vs LRU | winner |
|---|---|---|---|
| **2 MB fixed, canneal 8c** | **1 / 11** | **+12.82%** | **coalesce** |
| 2 MB fixed, water 8c | 5 / 11 | +8.40% | mockingjay |
| 2 MB fixed, barnes 4c | 7 / 11 | −0.62% | lru |
| 2 MB/core, canneal 4c | 7 / 11 | +2.41% | mockingjay |
| 2 MB/core, canneal 8c | 8 / 11 | −1.56% | srrip |
| 2 MB/core, canneal 16c | 10 / 11 | −1.02% | ship |
| single-core SPEC (A4) | 8 / 11 | +2.23% | mockingjay |

**COALESCE is the best policy of eleven on canneal 8-core at a 2 MB LLC, by
12.82% over LRU.** The same workload at the same core count with a 16 MB LLC
puts it 8th, below LRU.

The two sweeps are comparable. The `phaseA` runs are from 2026-09-17, after all
four audit fixes landed on 09-16 (fill hook `6963644`, ghost key `c9319cd`,
detraining `2b25406`, associativity `c04f477`). The only later changes to
`coalesce.cc` are `eddcb19` (`[]` to `.at()`) and `0cf55c4` (counter increments
and print statements) — both verified behaviour-neutral for victim selection.
The binaries made identical decisions.

## It is capacity pressure, not coherence

The sharpest comparison isolates it, same workload and core count:

| | invals/KI | LRU load MPKI | COALESCE |
|---|---|---|---|
| 2 MB fixed, canneal 8c | 0.542 | 7.802 | **1 / 11, +12.82%** |
| 2 MB/core, canneal 8c | 2.525 | 1.353 | **8 / 11, −1.56%** |

Going from the first to the second, coherence traffic rises **4.7x** and
capacity pressure falls **5.8x** — and COALESCE goes from best of eleven to
worse than LRU. **Coherence went up and COALESCE got worse.**

Across all seven configurations:

    COALESCE's gain over LRU vs coherence traffic : rho -0.36
    COALESCE's gain over LRU vs capacity pressure : rho +0.64
    (are the two axes the same thing?)            : rho +0.29

n=7, so treat the correlations as directional rather than conclusive. The sign
is what matters: the gain tracks **pressure**, positively, and coherence
traffic **negatively**. The two axes are largely independent, so this is not
one effect read twice.

**This does not support the project's original thesis.** COALESCE's advantage
is not coherence-specific — it is a capacity-pressure-aware policy that happens
to read coherence bits. Under pressure it is genuinely the best policy tested;
that win does not come from the mechanism the policy was built to exploit.

The ablations remain true and are not in conflict: removing either coherence
feature makes the policy *worse* (4c scaled: coalesce +2.41 > no_mesi +0.71 >
no_sharer −9.06). The features are load-bearing for how the policy works. They
are not the reason it beats LRU where it does.

## Why a large cache destroys it

`coalesce_diagnosis_2026-09-22.md` has the mechanism: the bias is strictly
non-negative and keys on MESI state and sharer count, so a page-table line —
neither MODIFIED nor multiply-shared — is the lowest-voted way by construction
and is evicted regardless of merit. `find_victim` never inspects `type`.

Its cost depends entirely on how much else is missing:

| config | LRU load MPKI | COALESCE TR miss/KI | vs best policy |
|---|---|---|---|
| 2 MB fixed, canneal 8c | 7.802 | 0.636 | **2.8x** |
| 2 MB/core, canneal 8c | 1.353 | 0.319 | **794x** |
| 2 MB/core, canneal 16c | 0.232 | 0.083 | **537x** |

Under pressure the translation penalty is noise against a flood of demand
misses. Remove the pressure and demand misses fall ~6x while the translation
defect does not — so it becomes the dominant differentiator. The flaw did not
grow; everything else shrank around it.

The bias magnitude compounds this with core count: `+20 x sharers` reaches +160
at 8 sharers and +360 at 16, against a perceptron output range of about
[−256, +254]. Past ~4 sharers the bias replaces the learned signal rather than
informing it, which matches 7th → 8th → 10th as cores rise.

## What this means

1. **The policy is not dead.** It is the best of eleven under capacity
   pressure, which is the regime replacement policies are normally evaluated
   in. Reporting only the scaled sweep understates it badly.
2. **The claimed mechanism is not the operative one.** The win does not track
   coherence. That needs saying plainly in any write-up; it is the difference
   between an honest paper and one a reviewer dismantles.
3. **The LLC sizing decision determines the result**, more than the policy
   does. Both geometries are defensible and they give opposite answers, so the
   paper must report both and say which question each one answers.
4. **The translation defect is worth fixing** regardless — it costs nothing
   under pressure and everything without it.

## The gap in the evidence

The 2 MB fixed sweep covers only canneal 8c, water 8c and barnes 4c. There is no
canneal 4c or 16c at fixed 2 MB, so pressure cannot be swept within one
geometry — LLC size and core count move together. The clean experiment is
canneal 4/8/16c at a fixed 2 MB with the current binary: ~11 jobs, and it would
separate the two axes properly instead of relying on n=7 across geometries.
