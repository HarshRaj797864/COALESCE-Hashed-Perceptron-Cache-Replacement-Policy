# The published SRRIP row: results (2026-11-23)

Scored by `python3 scripts/sp_score.py score` on the logs pulled on 23 Nov
(`scripts/sp_all.sh pull`). Design: `srrip_pub_design_2026-11-18.md`. The
full output is kept in `simulator/results/sp/score_2026-11-23.txt`
(untracked); the numbers below are copied from it.

## Gates: all hold

- **Parser:** it reproduces the committed rows of step 5's 19 srrip logs,
  19 of 19.
- **QS0:** recorded as passed (2026-11-18).
- **QS1, window, traces and config:** 19 of 19. Each run:
  - completed;
  - every fill was at RRPV 2;
  - 0 unexplained view-order violations;
  - had its reference's window, CPU count and traces;
  - had `LLC.replacement` srrip_pub.

## The 19 configurations

Max cycles, against step 5 of record (p2, ChampSim's srrip).

| Configuration | Regime | pub vs srrip | pub vs LRU |
|---|---|---|---|
| canneal 16c | shared | +10.33% | -3.11% |
| canneal 16c, 2 MB a core | shared | -0.09% | +0.01% |
| canneal 8c | shared | +8.83% | -3.19% |
| canneal 8c | private | +3.09% | -0.12% |
| canneal 8c, 2 MB a core | shared | +0.18% | -1.21% |
| canneal 8c, 2 MB a core | private | +3.70% | +1.21% |
| canneal 4c | shared | +8.13% | -2.07% |
| canneal 4c | private | +5.39% | -0.13% |
| canneal 4c, 2 MB a core | shared | +2.24% | -3.22% |
| canneal 4c, 2 MB a core | private | +3.80% | +1.72% |
| barnes std 4c (not ranked) | shared | +0.51% | -0.43% |
| barnes std 4c (not ranked) | private | -0.91% | -0.33% |
| barnes std 4c, 2 MB a core (not ranked) | shared | -0.00% | -0.00% |
| barnes std 4c, 2 MB a core (not ranked) | private | -1.09% | +0.30% |
| ocean 4c | shared | -10.73% | -9.05% |
| ocean 4c | private | -11.69% | -9.41% |
| ocean 4c, 2 MB a core | shared | **-32.06%** | +0.47% |
| ocean 4c, 2 MB a core | private | **-33.22%** | +0.57% |
| canneal 4c, 64 LLC MSHRs | shared | +8.13% | -2.07% |

The full scorer output, with each row's cycles and LLC misses, is in
`simulator/results/sp/score_2026-11-23.txt` (untracked).

## What this shows

- **ocean's SRRIP anomaly is the insertion defect.** At 2 MB a core,
  step 5's ChampSim srrip takes 48-51% more cycles than LRU. The published
  insertion is within 0.6% of LRU and has 2.4-2.5x fewer LLC misses than
  ChampSim's srrip (3.75 M against 9.11 M, shared). This confirms the
  2026-11-11 diagnosis on the full runs.
- **The defect does not always lose:**
  - On canneal at fixed 2 MB, ChampSim's srrip is the faster one: published
    SRRIP is 8-10% slower in the shared regime (4, 8, 16 cores) and 3-5%
    slower in the private one.
  - At 2 MB a core, the two are within 0.2% (8c, 16c shared) to 3.8%.
  - On 429.mcf (the diagnosis) the order also reversed.
  - So the row changes magnitudes in both directions, not a fixed bias.
- **The probe's expectations (not gating):**
  - Ocean within 5% of LRU: **met** (+0.47%).
  - canneal 4c within 2% of srrip: **not met** (+2.24% to +8.13%). The
    probe ran 20 M + 50 M; the full runs differ.

## Sensitivity (reported, as fixed)

- **Kendall τ of each ranked tree, srrip_pub in srrip's place, against the
  ranking of record:** +0.61 to +1.00 over 9 policies (lowest: canneal 8c
  private, +0.61; canneal 16c shared +0.72; the other ranked trees +0.78
  to +1.00).
- **P11's shared-against-private τ:**

  | Configuration | Of record | With srrip_pub |
  |---|---|---|
  | canneal 4c, fixed 2 MB | +0.78 | +0.72 |
  | canneal 4c, 2 MB a core | +0.33 | +0.33 |
  | canneal 8c, fixed 2 MB | +0.50 | +0.56 |
  | canneal 8c, 2 MB a core | +0.28 | +0.22 |

- **No verdict of P11-P14 would change:**

  | Prediction | Of record | With srrip_pub |
  |---|---|---|
  | P11 | fails 2 of 4 | fails 2 of 4 |
  | P12 | holds | holds |
  | P13 | holds | holds |
  | P14 | holds | holds |

## For the paper

- **Step 5's rankings and verdicts of record stay on ChampSim's srrip**, as
  fixed.
- **The published row is reported beside them**, with one sentence: the
  shipped module's insertion defect moves SRRIP by -33% to +10% against the
  published policy, depending on the program, without changing any verdict.
- **The ocean anomaly (+48-51% over LRU)** is stated as the insertion defect,
  measured.
- **The reference is p2 (g6).** If H7's 171 runs all complete and p3
  becomes the record, the row is still read against p2, and the p2-p3
  difference is stated (design, last bullet).
