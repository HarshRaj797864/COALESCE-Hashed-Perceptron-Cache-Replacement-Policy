# Matched B3 windows: fluidanimate_4 scored (2026-11-18)

Design: `matched_b3_design_2026-11-17.md` (amendment 1: QM1's sum). Binary
`champsim_mw_61d97f20`.

## The run

- **Run:** `phaseA_b3_mw_h2_fluidanimate4`, the only key of
  `matched_runs_v1.txt`.
- **Ended:** 2026-11-18 06:30 server time.
- **QM2 holds:** every line of the F-C reference. At B 100,000, the bins
  starting in the spans hold 18,744 events, and the counter holds 18,744.
- **Pulled:** `bash scripts/mw_all.sh pull`.

## The score

```
python3 scripts/matched_b3.py score <the run.log> bench/policy_sanity/matched_loc_set2_v1.txt \
  bench/policy_sanity/h2_count_rows_v1.txt bench/policy_sanity/gem5_b3_rows_v7.txt fluidanimate \
  heldout2/fluidanimate/l2_2MB_mi50M/fluidanimate_4c heldout2/fluidanimate/l2_2MB_mi150M/fluidanimate_4c
```

The output is in `matched_score_v1.txt`.

- **R_g5 from this log: 0.400.** That is 18,744 events in 412,469,348
  instructions, against gem5's 0.1137 per 1,000. It equals the scored F-C
  value, as QM2 implies.
- **R_g5m is not computed, on all three counter runs.**
  - Core 0 (thread 1)'s located window is 48.7-142.4 M. Its measured span
    is 50.82-150.82 M.
  - So the window starts 2,116,931 instructions before the span, inside
    the warm-up, where the instrument has no bins.
  - That is beyond the 1 M clipping limit, fixed in the design before any
    number existed.

## Reading (by the design)

- **fluidanimate's matched ratio does not exist under the pre-registered
  limit.** The paper reports this as it is: placement could not be tested
  on fluidanimate, because gem5's thread 1 window begins in ChampSim's
  warm-up.
- **Nothing is re-chosen.** The limit, B and the threshold stay as fixed.
- K2's reading of fluidanimate (I: within a burst, gem5 passes a line back
  and forth 2.4 times as often) is unchanged. So is R_g5, 0.400.
- **What remains:** streamcluster_4 and the Part B keys over 5 M lag. Each
  is rerun only once its F-C reference has completed and it passes every
  check. Then it is scored the same way. The cut-off is Sat 5 Dec.
