# A and B: error statistics across programs, and the metric's power (results, 2026-11-18)

- **Design:** `panel_design_2026-11-18.md`, pre-registered `98b902b`
  before any statistic was computed.
- **Tool:** `scripts/panel_stats.py`; its self-test holds 10 of 10.
- **Rows:** `panel_rows_v1.txt`, read from the 14 F-C reruns through
  `lock_fix_score`'s functions. The parser check holds on 14 of 14, and
  every rerun qualifies.
- **Output:** `panel_stats_v1.txt`.
- **No verdict changes.**

## Check on the rows

Every S ratio (x / y) equals its scored R_g5 to three decimals, on 14 of
14 spans (`cal_results_2026-11-18.md`'s table). Traffic equals
`lock_fix_score_v1.txt`'s values.

## A. Error statistics

### The scored set (11 spans)

| counter | n | in the band | Spearman ρ (p) | Pearson r of logs | geometric-mean error | median error | NRMSE |
|---|---|---|---|---|---|---|---|
| **S, store misses finding a holder (R_g5)** | 11 | 8 | **+0.873 (0.0008)** | +0.962 | ×1.58 | ×1.53 | 0.64 |
| U, upgrades (gem5 ≥ 10,000) | 6 | 5 | +1.000 (0.0031) | +0.974 | ×1.37 | ×1.25 | 2.00 |
| H, all hand-overs (S + U) | 11 | 9 | +1.000 (≤ 0.00001) | +0.977 | ×1.44 | ×1.31 | 1.93 |
| T, traffic | 11 | 11 | +0.964 (≤ 0.00001) | +0.983 | ×1.21 | ×1.09 | 0.15 |

### One span per program (8)

| counter | n | in the band | Spearman ρ (p) | Pearson r of logs | geometric-mean error | median error | NRMSE |
|---|---|---|---|---|---|---|---|
| **S** | 8 | 6 | **+0.857 (0.011)** | +0.969 | ×1.60 | ×1.49 | 0.41 |
| U | 4 | 3 | +1.000 (0.082) | +0.988 | ×1.34 | ×1.15 | 2.01 |
| H | 8 | 6 | +1.000 (≤ 0.00001) | +0.986 | ×1.42 | ×1.16 | 2.24 |
| T | 8 | 8 | +0.952 (0.0010) | +0.993 | ×1.18 | ×1.10 | 0.11 |

p values are two-sided, from 100,000 permutations (seed 20261118). "≤
0.00001" is the floor, 1 / (permutations + 1).

### The reading, as fixed in the note

**"ChampSim orders programs by store-time sharing as gem5 does" may be
said.** S has ρ +0.873 with p 0.0008 on the scored set (needed ≥ 0.7 and
< 0.05), and ρ +0.857 one per program (needed ≥ 0.7).

### What the paper states with it (from the note; nothing tuned)

- **Two different questions, two answers.**
  - **Across programs:** ChampSim ranks the programs' sharing rates as
    gem5 does. All hand-overs (H) rank identically on both sets.
  - **Per program:** the typical factor between the two rates is ×1.58
    for S, and ×1.21 for traffic.
- **The correlation is the easier result.** S's gem5 rates span about
  210× across these programs (0.0035 to 0.75 per KI), so rates can
  correlate even with factor-2 errors. The note says so, and the paper
  says it too.
- **NRMSE is dominated by the largest rates.** For U and H, that is lunc
  (8.23 against 3.48 upgrades per KI). It is reported, not read.
- **A caveat outside the note, stated, not computed:** the scored set
  mixes development programs (ocean, canneal, barnes) with held-out ones
  (radix, lunc, fluidanimate, vips). The held-out programs alone are too
  few for a statistic.

### Apart (never in a statistic): the ratios

| span | S | U | H | T |
|---|---|---|---|---|
| bodytrack (not scored: QW) | 0.352 | 0.787 | 0.519 | 0.569 |
| fmm (not scored: same stream) | 0.725 | 0.707 | 0.712 | 0.773 |
| ocean non-contiguous (apart) | 0.701 | 0.967 | 0.895 | 0.984 |

## B. The metric's power

### B1, defects caught by an out-of-band R

| # | span | R with the defect | what was found | R after | notes |
|---|---|---|---|---|---|
| 1 | ocean 4c, 2 MB | **0.045** (22× low) | **Tool:** the non-inclusive LLC forgets a line's sharers when it evicts it (0.98% of RFOs hit it). Fixed with the sharer directory (B3 v2). | R_b **1.263** | `b3_ocean4_2026-10-05.md`, `b3v2_ocean4_2026-10-06.md` |
| 2 | canneal 4c, 2 MB / 8 MB | **0 / 0** | **Tool:** `lock cmpxchg` was issued as a load, not an ownership request (gem5: 946,589 GETX). Fixed in step 1: a read-modify-write is an RFO. | R_b **1.230 / 1.109** | `b3v2_canneal_barnes_2026-10-07.md`, `b3v3_step1_2026-10-09.md` |
| 3 | barnes (the `barnes_4t` traces), 2 MB | **0.001** (B3 v2, step 1), 0.057 (level 1), **4.196** (level 2) | **Tool:** no private copy was ever invalidated, so private caches were not coherent. Fixed by steps 2-3. **Input:** the traces were a 256-body-leaf build; gem5 ran the standard program. | standard barnes, level 2: R_b **0.689** (force span) | `b3v2_canneal_barnes_2026-10-07.md`, `b3v4_steps23_2026-10-12.md`, `b3_barnes_stream_2026-10-12.md`, `b3_barnes_results_2026-10-14.md` |
| 4 | radix (held out) | **42.96** (R_b) | **The measuring rule:** the protocol view never forgets a reader that silently dropped its copy. gem5 forgets an exclusive holder when its private caches drop the line (micro test). Fixed: the gem5-rule view, primary since 2026-10-27. | R_g5 **0.990** | `b3_heldout_results_2026-10-17.md`, `micro_results_2026-10-18.md`, `sync_mx_g5_results_2026-10-27.md` |
| 5 | ocean, 2 MB, under a candidate rule (the bounded view) | **0.091** | **A candidate rule rejected**, and behind it a **replay defect:** the replay's threads drifted 8-19 M instructions apart. Fixed with synchronised replay. | R_g5 0.682, then **0.712** (F-C) | `b3_bounded_results_2026-10-18.md`, `drift_finding_2026-10-18.md`, `sync_mx_g5_results_2026-10-27.md` |
| 6 | barnes std window / start; barnes-256 | **0.249 / 0.233; 0.267** | **Tool:** a contended mutex waiter issued no request for the lock word (H-C2). Fixed by F-C. | **0.954 / 0.449; 0.780** | `lock_wait_results_2026-11-12.md`, `lock_fix_results_2026-11-14.md` |

**Out of the band, not explained or not fixed (listed, not left out):**

- **fluidanimate 0.400 and vips 0.308:** robustly out (H2). K2 reads
  fluidanimate as I (within a burst, gem5 passes a line back and forth 2.4×
  more) and vips as E (a third as many stretches). Step 3's lead limit is
  running.
- **barnes std start 0.449:** near the edge. Its cause is found (H6: the
  lock-word request goes out before the holder has taken the line), but it
  is not fixed.
- **bodytrack 0.352:** not scored (QW).

**Summary:**

- Seven defects in all:
  - four in the tool (1, 2, 3, 6);
  - one in the inputs (3);
  - one in the measuring rule (4);
  - one in the replay (5).
- Each showed as R off by a large factor: 22×, 0, 900×, 43×, 11×, about
  4×.
- Every out-of-band R led to a found cause, except the three spans listed
  above.

### B2, the smallest bias each span would show

The smallest factor by which ChampSim's count would have to be inflated (2
/ R_g5) or deflated (0.5 / R_g5) for an agreeing span to leave the band:

| span | R_g5 | inflated | deflated |
|---|---|---|---|
| barnes std window | 0.954 | ×2.10 | ×0.52 |
| barnes std force | 0.635 | ×3.15 | ×0.79 |
| barnes-256 | 0.780 | ×2.57 | ×0.64 |
| ocean 2 MB | 0.712 | ×2.81 | ×0.70 |
| canneal 4c 2 MB | 1.018 | ×1.97 | ×0.49 |
| canneal 8c | 1.534 | ×1.30 | ×0.33 |
| radix | 0.988 | ×2.03 | ×0.51 |
| lunc | 1.830 | ×1.09 | ×0.27 |
| **median (8 agreeing spans)** | | **×2.06** | **×0.52** |

### What A and B say together (for the paper)

- **The band catches gross defects, not fine ones.**
  - On a typical agreeing span, a bias under about ×2 either way would not
    take R out of the band.
  - Every defect it did catch was much larger (B1).
- **Finer errors are bounded by other evidence:**
  - the exact micro tests (hand counts met exactly; Q16 66 of 66);
  - the same-stream checks;
  - traffic (×1.21 typical);
  - A's per-program factor (×1.58 for S).
- **The paper states R_g5 as a test that caught the defects that mattered,
  not as a precision instrument.** It states the cross-program agreement
  (A) and the per-program factor beside it.
- **B3, injected defects, stays optional** (an amendment with its own
  runs).
