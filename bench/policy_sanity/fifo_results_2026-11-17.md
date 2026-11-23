# H1 and H1b: what the FIFO patch did to the scored gem5 runs -- results (2026-11-17)

Designs: `fifo_check_design_2026-11-14.md` (H1, pre-registered `63d487d`) and
`fifo_overtake_design_2026-11-14.md` (H1b, pre-registered `3a64b4c`,
amendment 1 `710f50b`). Both drivers ended before the pull of 2026-11-17
(server about 13:50 UTC; `bash scripts/fifo_all.sh pull`, `bash
scripts/ovt_all.sh pull`).

## Recomputed on the laptop

Every check was rerun on the laptop from the pulled files against the
originals in `simulator/results/gem5_b3_view`. The server's paths in each
`config.ini` were mapped to scratch directories first, because QF0 / QO0
compare paths and the laptop's differ (the unmapped first attempt failed on
exactly the three `redirect_paths` lines, as expected).

- `fifo_qf_v1.txt`: QF0 and QF1 for the 13 runs. **Each line equals the
  server's RESULT.**
- `ovt_report_v1.txt`: QO0, QO1, QO2 and the report for the 13 runs, with
  amendment 1's split of the other buffers by their `ordered` flag. **Each
  report equals the server's REPORT apart from that split**, which the
  server's copy of `ovt_check.py` (pre-amendment) did not print.

## H1: gem5's stock (ordered) FIFO buffers, the 13 scored configurations

| outcome | runs |
|---|---|
| QF0 (the same configuration but the L0 buffers' `ordered`) | 13 of 13 pass |
| COMPLETE-IDENTICAL (stats.txt equal line for line, host lines aside) | **12**: ocean 2 MB, ocean 8 MB, canneal 4c 2 MB, canneal 4c 8 MB, canneal 8c, barnes-256, radix, lunc, streamcluster, fluidanimate, vips, ocean-nc |
| PANIC | **1**: barnes std, tick 323,384,552,500, `l0_cntrl0.bufferFromL1`, delta 500, arrival 323,384,553,000, last 323,384,553,500; in the window (the 50 M stop ends at 104,456,444,500) |
| COMPLETE-DIFFERENT / OTHER | 0 |

By the design's "What each outcome means": the 12 identical configurations'
gem5 counts are stock MESI_Three_Level's, stated without a caveat. barnes
std's R stays as scored; the paper lists that its reference ran past a
suspected protocol bug at that tick.

**Which barnes spans that touches (an inference, from determinism).**
barnes std's scored spans use three gem5 stops of the same configuration:
50 M (final tick 104,456,444,500), 100 M (203,151,891,000) and 150 M
(327,495,144,500). The panic tick lies after the 100 M stop's end and before
the 150 M stop's end. gem5 is deterministic with randomization off and H1's
strict run is identical to the patched run up to the first overtake, so the
50 M and 100 M stop runs, which end earlier, contain no overtake. Only the
**window** span (50 M -> 150 M, F-C R_g5 0.954) has it in its reference; the
**start** (0 -> 50 M) and **force** (50 M -> 100 M) spans do not. The stop runs
themselves were not rerun.

## H1b: overtakes counted in each scored run (records only)

- QO-S held before any run (2026-11-14: 5,379 statistics lines equal; the
  build recompiled 1,004 objects, amendment 1).
- QO0 13 of 13; QO1 COMPLETE-IDENTICAL 13 of 13 (the counter changed no
  statistic in any run).
- **QO2 holds for barnes:** the counter's first L0 overtake is H1's panic
  line exactly (tick 323,384,552,500, `l0_cntrl0.bufferFromL1`, delta 500).

| run | L0 overtakes in the window | window L0 messages | per million | other buffers (unordered / ordered) |
|---|---|---|---|---|
| ocean 2 MB | 0 | 32,395,416 | 0 | 12,472 / 0 |
| ocean 8 MB | 0 | 32,415,408 | 0 | 34,047 / 0 |
| canneal 4c 2 MB | 0 | 7,469,435 | 0 | 1,669 / 0 |
| canneal 4c 8 MB | 0 | 7,650,735 | 0 | 1,588 / 0 |
| canneal 8c | 0 | 15,265,908 | 0 | 1,678 / 0 |
| **barnes std** | **1** (bufferFromL1; margin 500 ticks) | 9,602,428 | **0.104** | 528 / 0 |
| barnes-256 | 0 | 16,664,395 | 0 | 551 / 0 |
| radix | 0 | 76,524,407 | 0 | 7,116 / 0 |
| lunc | 0 | 37,180,533 | 0 | 9,892 / 0 |
| streamcluster | 0 | 12,614,090 | 0 | 1,753 / 0 |
| fluidanimate | 0 | 2,309,480 | 0 | 629 / 0 |
| vips | 0 | 7,198,540 | 0 | 1,023 / 0 |
| ocean-nc | 0 | 48,406,586 | 0 | 9,216 / 0 |

barnes std's single window overtake is also its only L0 overtake in the
whole run (warm-up included). Every
overtake outside the L0 buffers is in an **unordered** buffer, where gem5
allows it (amendment 1); **no ordered buffer other than barnes's one L0
message was overtaken in any scored run.**

## What the paper states

- The FIFO patch changed nothing in 12 of the 13 scored gem5
  configurations: with gem5's own strict check on, their statistics are
  identical line for line.
- In the 13th (barnes std), one message in 9.6 million L0 messages of the
  window overtook another (0.10 per million), at the tick where stock gem5
  panics; the window span's reference ran past it. barnes std's start and
  force spans end before it.
- gem5's issues #1597 and #2816 stay cited as open; the panic is not called
  a false alarm.

Nothing is tuned; no B3 ratio changes.
