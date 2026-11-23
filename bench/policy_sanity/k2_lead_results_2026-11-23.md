# K2 step 3, the diagnostic lead limit: results (2026-11-23)

Design: `k2_sharing_gap_design_2026-11-17.md`, amendments 2 and 3 (the
readings were fixed on 2026-11-17). The runs ended on 18 Nov (Q3: 8 hold)
and were pulled on 23 Nov (`scripts/k2lead_all.sh pull`). They were scored
by `python3 scripts/k2lead_score.py`; the output is in
`simulator/results/k2lead/score_2026-11-23.txt` (untracked).

## How it was scored (disclosed)

- **No scorer was written before the runs.** `scripts/k2lead_score.py` was
  written on 23 Nov, after the pull and before any number of the 8 runs was
  printed. It adds no rule. It reuses, unchanged, the code that scored F-C:
  - `lock_fix_score.counts`, `ratios` and `qualify`;
  - `disagree_diag`'s spans and gem5 windows.
  - It was committed (`24d6701`) before it was run.
- **A slip in that commit:** its message says "self-test 6/6", but the
  self-test had crashed. It was a TypeError in the test's own code (a dict
  built with tuple keyword arguments). The pipe into `tail` hid the exit
  code, so the commit and the scoring went ahead.
  - The test was fixed and passes 8/8, including the cases that matter here
    (a fall, and a control falling).
  - A rerun of the score printed the same output, line for line.
  - The scoring code itself did not change.
- **Gates, all hold:**
  - lock_fix_score's parser reproduces the committed rows of the 14 scored
    logs;
  - the F-C references, recomputed, equal amendment 2's fixed values:
    fluidanimate 0.400, vips 0.308, canneal 4c 1.018, ocean 0.712;
  - all 8 runs qualify against their F-C logs (window, CPU count, traces,
    level 2, request line, Q3, no wrap; one lead-limit line with the run's
    Delta; a LEAD HOLDS line per CPU).

## Results

| Span | Delta | R_g5 (F-C) | Change | R_b (F-C) | traffic | max cycles vs F-C |
|---|---|---|---|---|---|---|
| fluidanimate | 1,000,000 | 0.342 (0.400) | -0.058 | 0.483 (0.539) | 0.777 | +18.04% |
| **fluidanimate** | **100,000** | **0.183 (0.400)** | **-0.217** | 0.324 (0.539) | 0.772 | +28.64% |
| vips | 1,000,000 | 0.189 (0.308) | -0.120 | 0.189 (0.308) | 0.932 | -0.21% |
| vips | 100,000 | 0.190 (0.308) | -0.118 | 0.190 (0.308) | 0.947 | +16.33% |
| canneal 4c 2 MB | 1,000,000 | 1.017 (1.018) | -0.001 | 1.260 (1.261) | 1.043 | +0.02% |
| canneal 4c 2 MB | 100,000 | 1.015 (1.018) | -0.003 | 1.257 (1.261) | 1.043 | +4.54% |
| ocean 2 MB | 1,000,000 | 0.324 (0.712) | -0.387 | 1.128 (1.113) | 0.915 | +21.54% |
| **ocean 2 MB** | **100,000** | **0.157 (0.712)** | **-0.555** | 1.168 (1.113) | 0.912 | +47.23% |

**Lead-held cycles (measured) and max lead per CPU:**

| Span | Delta | Held cycles | Max lead per CPU |
|---|---|---|---|
| fluidanimate | 1 M | 48.8 M | 1.00 M / 5.93 M / 0.60 M / 8.15 M |
| fluidanimate | 100 k | 77.6 M | 0.10 M / 5.93 M / 0.51 M / 8.15 M |
| vips | 1 M | 15.6 M | 1,000,352 each |
| vips | 100 k | 119.0 M | 100,352 each |
| canneal 4c 2 MB | 1 M | 0.12 M | 1.00 M / 1.00 M / 0.94 M / 0.55 M |
| canneal 4c 2 MB | 100 k | 27.5 M | 0.10 M / 0.96 M / 0.85 M / 0.30 M |
| ocean 2 MB | 1 M | 257.0 M | 1.75 M / 1.48 M / 0.19 M / 0.21 M |
| ocean 2 MB | 100 k | 513.0 M | 1.75 M / 1.48 M / 0.10 M / 0.18 M |

- **A max lead above Delta is expected by the design's definition.** The
  bound (Delta + 358) holds while the set S of running cores is fixed. When
  the slowest core waits on a sync record it leaves S, and min jumps. When
  it rejoins S, the others' lead over it can be large at once. Where no core
  waits (vips), every max lead is exactly Delta + 352.

## The readings (fixed in amendment 2)

- **Primary, fluidanimate at Delta 100,000:** R_g5 0.183 against 0.400,
  a change of **-0.217**. The rule needs a rise of at least +0.15. **Timing
  is NOT SUPPORTED by this test.** Holding ChampSim's cores together does
  not close fluidanimate's gap; it widens it.
- **Specificity:** the ocean control moves by -0.555 at the same Delta, so
  the reading adds **"not specific to fluidanimate"**. Canneal does not move
  (-0.003).
- **What the paper states (the design's rule):** the gap on fluidanimate and
  vips, without the timing explanation. "Keeping the replayed threads within
  Delta instructions of each other did not raise the agreement (it lowered
  it)" may be added, with this note as its source.

## Reported, deciding nothing

- **The limit is not a neutral probe.** On ocean, a span that agrees with
  gem5 without it:
  - the gem5-rule view falls from 0.712 to 0.157;
  - the protocol view stays put (1.113 to 1.168);
  - the cycles rise by 47%.
  - Forcing lockstep changes which copies are still held when a store
    arrives, in the direction of fewer gem5-rule events. Why is not
    diagnosed; no claim rests on it.
- **vips** moves the same at both Deltas (0.308 to 0.19), while its cycles
  change only at 100 k.
- **fluidanimate at 100 k, split by step 1:**
  - **How it was run:** `k2_episodes.py run fluidanimate`, with H6(b)'s gem5
    events unchanged and this run's `ev.txt` and `run.log` in ChampSim's
    place (a scratch `H6B` of links; the script is unchanged).
  - **At gamma 0.001:**

    | Run | Ep | Per | share_I | ChampSim episodes (gem5 10,670) |
    |---|---|---|---|---|
    | H6(b)'s scored run | 0.949 | 0.421 | 0.943 | 10,819 |
    | Delta 100,000 | 0.689 | 0.258 | 0.784 | 7,857 |

  - Still reading I, and worse on both factors. The limit removes whole
    stretches of sharing (Ep falls) and shortens the rest (Per falls); it
    does not add passes within a burst.
  - Stores only: R 0.388 becomes 0.156.
- **Nothing scored changes.** The lead limit is never the tool's setting.
