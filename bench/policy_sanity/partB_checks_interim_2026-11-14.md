# Part B: the input checks, read early (2026-11-14). No ratio read

`breadth_bc_design_2026-11-10.md`, Note 3 (amendment 7) and amendment 10.
Owner, 2026-11-14: "besides the paper do everything". The checks that do not
depend on ChampSim were run now, before the F-C reruns end, so that a
failing program can be diagnosed while the runs finish. `check` prints no B3
ratio; none was printed (0 `R_g5` / `R_b` lines in its output), and `score`
was not run.

## What was pulled and built (laptop, 2026-11-14 ~19:00)

- **Pulls (read-only):** `partB_all.sh pull` and `tpull`, `partBfc_all.sh
  pull`, `pull_results.sh` (rows v30, b3 v21).
- **gem5 rows** from a hard-linked view of `simulator/results/gem5_b3`
  without `cal/`, `fifo/` and `hset/` (H1, H2, H4: their own notes score
  them):
  - `gem5_percpu_v3`, `gem5_mix_v7` and `gem5_b3_rows_v7`;
  - every v2 / v6 / v6 row reappears unchanged (0 missing). New rows: 702,
    58 and 56 (Part B's ended runs; radix_16's two are still running).
- **trace_mix_v6** = v5 unchanged, plus `canneal_16t_t1..t16`
  (`b3_stream_check.py window` on `stage2/canneal16/raw<k>.mix`).
- **Part B rows:**
  - `partB_keys_v1` (32 keys);
  - `partB_trace_rows_v1`, `partB_count_rows_v1` and
    `partB_gem5_config_v1`;
  - `partB_fc_run_rows_v1` (`--fc runrows` on the partBfc logs) and
    `partB_fcq_rows_v1` (`--fc fcrows`).
- **The command:** `partB_score.py --fc check` on those twelve files.

## One scorer correction, before any score

In `--fc` mode, a key whose F-C rerun is still running read "not scored (Q3)":
- its partial log fails Q3 only as "not complete";
- `fc_verdict` kept that failure.

Now Q3 is dropped while the FCQ row is PENDING. It is decided when the rerun
completes. Any other failing check still marks the key.
- Two self-test cases added; the self-test reads 50 hold, 0 fail.
- Nothing changes for a completed rerun. Without `--fc` nothing changes.

## The input checks, by key (QB, QT, QG, QW, QC, v2, 500)

| key | input checks | where it stands |
|---|---|---|
| ocean, oceannc, radix, barnes, lunc, waternsq, raytrace, streamcluster, fluidanimate, vips at 8 | all hold | wait for their F-C reruns (Q3, FC) |
| ocean, oceannc, lunc, waternsq, raytrace, streamcluster, fluidanimate, vips at 16; canneal_16 | all hold | wait for their g6 runs, then their F-C reruns |
| fft_4, fft_8, fft_16 | **500 fails**: gem5 counts 0 store misses that find another core | not discriminating, as at 4 cores before |
| volrend_4 | **QC fails** (stores outside the gem5-CPUID runs' range) | not scored |
| volrend_8 | **QC and v2 fail** (stores, RMWs) | not scored |
| volrend_16 | **v2 fails** (RMWs; stores 5-8% outside, which would be scored with the miss stated) | not scored |
| fmm_4, fmm_8, fmm_16 | **v2 fails**: RMWs at 4; stores and RMWs at 8 and 16 | not scored |
| bodytrack_8, bodytrack_16 | **QW fails**: untraced CPUs commit 1.259% (8) and 2.358% (16) of the traced CPUs' window | not scored, as expected beforehand |
| barnes_16 | **v2 fails on RMWs**: gem5 9.756 per KI against the counter runs' 10.372-10.378 (widened 5%: 9.85-10.90) | not scored; new, not diagnosed |
| radix_16 | gem5's two runs still running | PENDING |

**So at most 10 of 14 programs at 8 cores, and 9 of 15 at 16 cores
(radix_16 pending), can be scored.** fft, volrend, fmm and bodytrack fail
the same checks at every core count. barnes fails v2 at 16 cores only.

## Not done here

No `score`. No ratio. No F-C rerun is judged before it completes. The fft,
volrend, fmm and bodytrack failures are the classes the disagreement
diagnosis lists (B, `disagree_diagnosis_design_2026-11-06.md`). barnes_16's
RMW miss is added to it.

## Follow-up (same day): barnes_16's RMW miss

`v2_located_results_2026-11-14.md`: located on the windows gem5 actually ran,
the native RMW rate is 9.801-10.058 against gem5's 9.756 (W1). The miss is
window placement: gem5 stops on its first worker, and two threads lag by 19 and
29 M. Lock contention is rejected (L1). barnes_16 stays not scored. fmm's
misses are not explained by placement: in gem5 six of its eight workers have
run 0.4 M instructions when the eighth reaches 50 M.
