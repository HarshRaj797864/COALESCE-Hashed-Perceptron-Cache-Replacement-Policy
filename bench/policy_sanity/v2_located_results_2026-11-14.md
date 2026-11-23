# v2's Part B misses: the located windows. Results, 2026-11-14

- **Note:** `v2_located_design_2026-11-14.md` (`3adc60d`), committed before
  the tool ran on real rows.
- **Rows:** `v2_located_v1.txt`, from `scripts/v2_located.py run` on
  `partB_keys_v1`, `partB_count_rows_v1`, the pulled counter runs,
  `gem5_percpu_v3` and `gem5_mix_v7`. Self-test PASS.
- **QV holds:** the tool's counter-window ranges equal `check`'s v2 numbers
  for every key (barnes_16 RMWs 10.372-10.378; each failing measure as the
  interim lists it).
- **Nothing is scored.** barnes_16 stays not scored, as the note fixed.

## barnes_16 (primary): W1 and L1

| | gem5 | counter windows | located windows |
|---|---|---|---|
| loads | 323.157 | 322.089-322.133 | 322.798-323.315 |
| stores | 208.352 | 205.441-205.453 | 206.673-207.641 |
| RMWs | **9.756** | 10.372-10.378 (outside) | **9.801-10.058 (inside)** |

- **W1: H-W is supported.** On the windows gem5 actually ran, the native
  RMW rate is within 0.05 of gem5's, and inside v2's 5% widening. The
  RMW miss comes from where the windows lie; the stream is not shown to
  differ. Loads and stores also move toward gem5's values.
- **L1: H-L is rejected.** Lock-wait stores are 0.031-0.042 per 1,000
  (B 0.042). Removing all of them would not close even s = 0.097.
- **Placement:** gem5 stops when its first worker reaches 150 M. At that
  moment the other threads lag (end of window, M instructions):

  | thread | t8 | t7 | t1 | t2 | t9 | t0 | the rest |
  |---|---|---|---|---|---|---|---|
  | lag (M) | -28.9 | -19.1 | -8.8 | -8.3 | -5.7 | -3.5 | 0 to -0.4 |

  The window starts agree within 0.4 M.

## The secondary keys

| key | failing in v2 | reading | located against gem5 |
|---|---|---|---|
| fmm_4 | RMWs | W2 | 0.803-0.812 against 1.124 |
| fmm_8 | stores, RMWs | W2, W2 | stores 29.74-29.95 against 22.81; RMWs 2.49 against 0.55 |
| fmm_16 | stores, RMWs | W2, W2; L1 (B 0.0006) | stores 23.37-23.48 against 19.33; RMWs 1.42 against 0.40 |
| volrend_4 | none (it fails QC) | - | - |
| volrend_8 | stores, RMWs | W2, W2 | stores 38.38-38.88 against 41.52; RMWs 0.844-0.870 against 1.083 |
| volrend_16 | stores, RMWs | stores W2, **RMWs W1** | RMWs 0.828-0.975 against 1.007 |

- **volrend_16's stores** sit 5-8% outside the range. `check` scores that as
  a miss stated (the held-out rule); this tool applies only the 5% edge
  (disclosed). Its RMWs are explained by placement; its stores are not.
- **fmm's located rates move away from gem5's, not toward them.**
  - gem5 runs fmm's workers very unevenly. In the fmm_8 run at the 50 M
    stop, CPUs 1-6 had committed about 0.40 M instructions each, while CPU 7
    had 50 M and CPU 0 56.6 M (`gem5_percpu_v3`).
  - The gem5 window therefore holds threads 1-6's first ~86 M instructions,
    against the counter's 50-150 M. It lags by 49-50 M at the start and 63-65
    M at the end; fmm_4 and fmm_16 are the same.
  - Even at the same positions, the instructions differ. Why is not
    diagnosed.
  - fmm stays not scored.

## Control C: 24 of 24 hold

Every key that passes v2 on the counter windows also passes on the located
windows. So the located test is consistent with v2 wherever v2 already
holds.

## Placement for every key (reported)

The largest lags at the high stop, gem5's window end minus the counter
window's (M instructions):

| key | largest lag at the end (M) |
|---|---|
| fmm 8 / 16 | -65 |
| fft 8 / 16 | -66 / -68 (one thread) |
| fluidanimate_16 | -43 |
| volrend_16 | -36 to -40 (all but CPU 1) |
| barnes_16 | -29 |
| volrend_8 | -21 |
| fmm_4 | -18 |
| lunc_16 | -18 |
| raytrace_16 | -19 |
| lunc_8 | -14 |
| waternsq | -12 |
| raytrace_8 | -10 |
| streamcluster | -10 |

Everything else lies within about 3 M.

B3 compares gem5's events in these windows with ChampSim's events in its
own windows. This note does not measure what that does to any ratio.

## What follows (the owner's decisions; nothing done)

1. **barnes_16.** A remedy would let it pass v2: v2 judged on located
   windows. Control C supports that as consistent. It would be an
   amendment to Note 3, applied to every key, on the owner's word.
2. **Placement and B3.** For keys whose gem5 threads lag by tens of M, B3
   compares windows at different positions. One remedy is to read gem5's
   events over matched windows, which needs per-CPU stop points. It would
   need its own note.
3. **fmm.** In gem5, fmm's workers barely run while one worker reaches 50 M.
   That is gem5-side behaviour, for a separate diagnosis (for example, how
   SE-mode futex wakes reach them).
