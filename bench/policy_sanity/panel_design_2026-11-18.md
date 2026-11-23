# A and B: error statistics across programs, and the metric's power (pre-registration, 2026-11-18)

This is the owner's decision of 2026-11-18 (PLAN § 10 item 10, A and B).
It is written before any statistic below has been computed. The
per-span ratios it uses were scored earlier and are already known; the
cross-program statistics are not.

**Nothing here changes a verdict.** R_g5 stays the primary measure, with
its band. A and B are reported beside the verdicts.

## A. Error statistics across programs

### Spans

The 14 spans of the F-C set, each read from its F-C rerun as
`scripts/lock_fix_score.py` reads it (its parser check first). gem5's side
is each span's gem5 window, as for every score.

- **The scored set (11):**
  - fluidanimate, vips;
  - barnes std window, barnes std start, barnes std force;
  - barnes-256;
  - ocean 2 MB;
  - canneal 4c 2 MB, canneal 8c;
  - radix;
  - lunc.
- **Left out:**
  - bodytrack (not scored: QW);
  - fmm (not scored: same stream);
  - ocean non-contiguous (reported apart, as always).

  They are listed in an appendix table and never enter a statistic.
- **One span per program (8):**
  - fluidanimate, vips;
  - barnes std force (barnes std's primary span);
  - barnes-256 (a different build);
  - ocean 2 MB;
  - canneal 4c 2 MB;
  - radix;
  - lunc.

  This set guards against barnes's three spans and canneal's two core
  counts inflating n.
- **Part B's keys** join by the same rule once they are scored, in a
  later version of the output.

### Counters

For each span, the ChampSim rate x and the gem5 rate y, both per 1,000
instructions:

| counter | ChampSim (x) | gem5 (y) |
|---|---|---|
| **S, store misses finding a holder** (R_g5's terms) | C | SS + MT L1_GETX |
| **U, upgrades** | gem5-rule upgrade events | SS upgrades |
| **H, all store-time hand-overs** (S + U) | C + upgrades | SS + MT GETX + SS upgrades |
| **T, traffic** | LLC (TOTAL - WRITE) accesses | L2 demand accesses |

For U, a span enters only where gem5 has at least 10,000 upgrades,
`lock_fix_score`'s rule. The ratio is x / y.

### Statistics (per counter, on each set)

- **n**, and the count with x / y in [0.5, 2].
- **Spearman ρ of x against y**, with a two-sided p-value from 100,000
  permutations (seed 20261118).
- **Pearson r of ln x against ln y.**
- **The geometric-mean error:** exp(mean |ln(x / y)|), and the median
  |ln(x / y)| as a factor.
- **NRMSE** = sqrt(mean (x - y)²) / mean y, as Accel-Sim reports it. Rates
  span orders of magnitude across programs, so NRMSE is dominated by the
  largest. It is reported, not read.

### Reading (fixed now)

- **The paper may say "ChampSim orders programs by store-time sharing as
  gem5 does"** only if, for S, Spearman ρ ≥ 0.7 with p < 0.05 on the
  scored set **and** ρ ≥ 0.7 on the one-per-program set. Otherwise it
  reports the numbers without that sentence.
- The geometric-mean error is reported as the typical factor by which a
  program's rate differs. It is not judged against a threshold.
- **Correlation across programs and per-program accuracy answer different
  questions.** Rates that span orders of magnitude correlate even with
  factor-2 errors. The paper reports both and says so.

## B. The metric's power

### B1, defects caught (from the committed result notes; no new number)

- **The rule for an entry:** every B3 result note in which a scored span's
  R (R_b before 2026-10-27, R_g5 after) lay outside [0.5, 2], and a defect
  in the tool, its inputs or a candidate rule was then found. Each entry
  gives:
  - the span;
  - R with the defect;
  - R after the fix, or the rule rejected;
  - the defect;
  - the source note.
- Every number is read from its note at compile time and quoted with the
  note's name.
- An out-of-band R whose cause was never found is listed under "not
  explained", not left out.

### B2, the smallest bias each span would show (analytic)

- For each span in the scored set with R_g5 in the band: f_hi = 2 / R_g5
  and f_lo = 0.5 / R_g5.
- These are the smallest factors by which ChampSim's count would have to
  be inflated or deflated for the span to leave the band.
- Reported per span, with their medians over the agreeing spans.

### B3, injected defects

- **Optional.** A later amendment, with its own runs. Nothing here.

## Tool and output

- `scripts/panel_stats.py`:
  - `rows`: one row per span and counter, from the F-C logs and the gem5
    windows, through `lock_fix_score`'s functions;
  - `stats`;
  - `power` (B2);
  - `selftest`: hand cases for ρ, the permutation p, the geometric-mean
    error and NRMSE.
- Rows file `panel_rows_v1.txt`.
- Results: `panel_results_2026-11-18.md`, with B1's table compiled from the
  notes.
