# A5 — at matched pressure, sharing reorders the policies

**2026-10-01.** Raw rows: `phasea_rows_v8.txt` (302 rows), pulled after the
scaled-private queues completed (2026-09-29 13:04 UTC). The 249 rows already
complete in `phasea_rows_v7.txt` are byte-identical here. Every number comes
from `scripts/analyze_rows.py`. Its new `compare` command was checked by
reproducing the 2026-09-26 doc's τ (+0.86 / +0.71 / +0.64) exactly, and
`rank` gives byte-identical output to the previous version on the v7 tables.

## V7 on the scaled-private trees — all checks pass

`phaseA_scaled_private` 28/28 (7 baselines × canneal 4/8/16c + barnes 4c),
`phaseA_scaled_private_armA` 12/12, `phaseA_scaled_private_armB` 12/12:
- complete, no wrapped trace, no page-pool exhaustion;
- TOTAL identity holds; min == max cycles;
- 100.1–103.2 M instructions per core;
- invalidations and aliased fills exactly 0;
- no two policies share a cycle count, so barnes 4c is distinct here (its
  private side takes misses);
- the arms differ in all 12 configurations.

**Provenance.** Each side combines rows from more than one tree:
- **Scaled-private baselines** ran on the 2026-09-20 build
  (`bin/champsim_phaseA_20260923`, from `queue.env`). Their LRU row comes from
  `phaseA_scaled`, which `v7arm` shows is identical to that build.
- **Fixed-2 MB shared baselines** come from `phaseA`, on the 2026-09-17 build
  at 8c (shown equivalent by `v7equiv`) and the 2026-09-20 build otherwise.
- **COALESCE rows** come from the arm binaries, which differ from those builds
  only inside `replacement/coalesce*` (`v7_relaunch_2026-09-28.md`).

## The design

The two regimes differ in pressure as well as sharing: aliasing shrinks the
shared working set at any cache size (`v7_relaunch_2026-09-28.md`,
"Correction"). So two comparisons are made, each controlling one thing:

| comparison | matched | not matched | LRU LLC load hit, private vs shared |
|---|---|---|---|
| **pressure-matched** — scaled private vs fixed-2 MB shared | LRU pressure (within 1.6–2.4 pp) | LLC size and set count | 26.1 / 26.3 / 26.4% vs 23.7 / 24.0 / 24.8% |
| **geometry-matched** — scaled private vs scaled shared | LLC size and set count | pressure | 26.1 / 26.3 / 26.4% vs 67.7 / 86.8 / 97.7% |
| *(2026-09-26)* fixed private vs fixed shared | LLC size and set count | pressure (private thrashes) | 1.7 / 0.6 / 0.3% vs 23.7 / 24.0 / 24.8% |

## Result — canneal, 8 baselines

Kendall τ between the private and shared rankings (1 = same order):

| comparison | 4c | 8c | 16c |
|---|---|---|---|
| **pressure-matched** | +0.57 | **+0.29** | **+0.29** |
| geometry-matched | +0.29 | +0.14 | +0.29 |
| fixed 2 MB (2026-09-26, confounded) | +0.86 | +0.71 | +0.64 |

**Pressure-matched orders, speedup over LRU in `max_cycles`:**

| | private (scaled) | shared (fixed 2 MB) |
|---|---|---|
| 4c | mockingjay +9.62, hawkeye +8.67, drrip +3.94, srrip +1.96, **lru**, ship −0.36, random −2.97, srrip_bias −5.10 | mockingjay +14.44, hawkeye +13.95, srrip +10.77, srrip_bias +8.83, drrip +6.36, ship +3.62, **lru**, random −0.52 |
| 8c | hawkeye +9.78, mockingjay +8.30, drrip +3.88, srrip +1.98, **lru**, ship −1.41, random −3.10, srrip_bias −4.46 | srrip +12.69, mockingjay +12.69, srrip_bias +12.24, hawkeye +12.07, drrip +7.85, ship +5.53, **lru**, random −0.25 |
| 16c | hawkeye +9.95, mockingjay +8.13, drrip +4.02, srrip +3.15, **lru**, ship −0.67, srrip_bias −2.28, random −2.97 | srrip +14.67, srrip_bias +14.44, mockingjay +12.19, hawkeye +11.34, drrip +7.34, ship +5.55, **lru**, random −0.71 |

The smallest gap between adjacent policies in the private orders is 0.36 /
1.36 / 0.68% of cycles at 4/8/16c, so those orders do not rest on hair-thin margins.
The shared order at 8c does at its top: SRRIP and Mockingjay are 0.001%
apart.

**What a multi-programmed evaluation would conclude, and what sharing does to
it:**
1. **Hawkeye against SRRIP changes sign.**
   - Private: Hawkeye beats SRRIP by 6.6 / 7.7 / 6.6% at 4/8/16c.
   - Shared at matched pressure: Hawkeye still leads at 4c (2.8%), but SRRIP
     is faster at 8c (by 0.55%) and 16c (by 2.99%).
   - The private regime's winner, Hawkeye at 8c and 16c, places 4th of 8
     shared.
2. **srrip_bias flips from below LRU to the top.** Private −5.10 / −4.46 /
   −2.28%; shared +8.83 / +12.24 / +14.44%, and 2nd at 16c. In the private
   regime its MODIFIED bias can only mean "dirty", and it costs.
3. **The learned policies' lead shrinks under sharing.** In private, the
   better of Hawkeye and Mockingjay leads DRRIP, the best non-learned policy,
   by 5.5 / 5.7 / 5.7%. In shared at 8c and 16c the RRIP family matches or
   beats them.

**COALESCE, both arms, pressure-matched:**

| | private (scaled) | shared (fixed 2 MB) |
|---|---|---|
| arm A | −6.66 / −5.68 / −3.01% | +9.85 / +13.42 / +14.66% |
| arm B | −8.52 / −7.45 / −4.44% | +9.67 / +13.08 / +14.01% |

COALESCE is below LRU in every private configuration and among the fastest
shared. That is the same flip as srrip_bias. Its coherence features are inert
without sharing (sharer count ≡ 1, MODIFIED means dirty).

**barnes 4c cannot discriminate** in this comparison. All 8 baselines lie
within 0.14% of each other in private and within 0.81% in shared, so its τ
(+0.50) is not read.

## Threats — state these with the result

1. **One workload.** canneal at 4/8/16 cores, and barnes does not
   discriminate. A second shared workload is needed before the paper states
   this generally.
2. **The pressure-matched pair differs in LLC size and set count** (2 MB /
   2048 sets against 8 / 16 / 32 MB). Policies that sample sets see different
   sample sizes: Hawkeye's sampled-set count varies with geometry (PLAN § 8),
   as do DRRIP's and SHiP's leader sets. The geometry-matched pair has no such
   difference and gives the same direction (τ +0.29 / +0.14 / +0.29), but its
   pressure differs hugely. The two comparisons, each controlling what the
   other cannot, agree.
3. **Pressure is matched on LRU only.** Other policies' hit rates differ
   between the sides; the scaled-private baselines span 18–40% load hit rate.
4. **Single deterministic runs.** No variation across trace windows has been
   measured. τ over 8 items is coarse: +0.29 is 18 concordant pairs against
   10.

## For the paper

**Defensible now, with the threats above:**
- On canneal, at LRU-matched pressure, the ranking a multi-programmed
  (private) evaluation produces is a poor predictor of the multithreaded
  (shared) ranking: τ = +0.29 at 8 and 16 cores.
- The verdict between Hawkeye and SRRIP reverses at 8 and 16 cores.
- The policies with coherence-derived inputs (srrip_bias, COALESCE) move from
  below LRU to near the top.

**Not yet:** any statement beyond canneal, or any attribution to coherence as
opposed to the reuse pattern sharing creates. SRRIP has no coherence input
and still gains 8.8 / 10.7 / 11.5 pp over LRU under sharing.
