# H6(b): where gem5's extra sharing events are in fluidanimate and vips -- results (2026-11-17)

Design: `h6b_attribution_design_2026-11-14.md` (pre-registered `b936869`;
amendment 1 `15c7b57`: an RMW is a same-address ST pair of one core, the
locked / plain split dropped; amendment 2 `b34f55d`: gem5 25.1's address
format, QP exact under the protocol's replacements, disclosed). QP held on
the relaunch (2026-11-14 23:09:05, `c9f35f2`). The chain ended 2026-11-17
07:02:13 server time; pulled the same day (`bash scripts/h6b_all.sh pull`
-> `simulator/results/h6b/`). The reports below are the server's
`report_<p>.txt`, read once, after the pull.

## Checks

| | fluidanimate | vips | canneal 4c (control) |
|---|---|---|---|
| QG0 (events from T_a = stats window count) | holds, 43,879 = 43,879 | holds, 3,242 = 3,242 | holds, 89,307 = 89,307 |
| QG1 (rerun's stats = the scored 150 M run's) | holds (0 differ) | holds | holds |
| QE0 (ChampSim log = its F-C rerun's, times masked) | holds (2,175 lines) | holds (2,177) | holds (2,175) |
| QC0 (event log = run log's gem5-rule count) | holds, 18,744 | holds, 1,031 | holds, 91,376 |
| anomalies (unpaired, no holder, no instruction; gate 1%) | 0.00% | 0.00% | 0.00% |

QG1 holding means the readings are of the scored runs themselves, not "a
rerun". Each program's C and G equal its scored values (fluidanimate R_g5
0.400, vips 0.308, canneal 1.018 on these counts).

## Readings, as fixed

**Control (canneal 4c):** the only class with at least 100 gem5 events is
RMW (89,305 of 89,307): R_RMW 1.018, in the band. **The control holds**, so
K1-K3 are read. (canneal's own report prints "K2" from its store class,
which holds 2 gem5 events; the control reads only classes with >= 100, and
canneal's K reading means nothing.)

| | fluidanimate | vips |
|---|---|---|
| G_u (gem5 events with an untraced CPU) | 0 | 58 (all as requester: CPU 0 53, CPU 1 5) |
| C x s / (G - G_u) | 0.400 | 0.314 |
| **Step 1** | **A2** | **A2** |
| gem5 store / RMW events (traced) | 42,043 / 1,836 | 3,101 / 83 |
| ChampSim store / RMW events | 17,414 / 1,330 | 1,020 / 11 |
| R_store, R_RMW | **0.388**, 0.678 | **0.319**, 0.129 |
| **Step 2** | **K2** | **K2** |

- **A2 for both:** events involving the untraced threads explain none of
  fluidanimate's gap (0 events) and almost none of vips's (58 of 3,242).
  This settles round 1's open "H-A can explain vips" (`disagree_diagnosis_
  results_2026-11-06.md`, which counted messages, not events): it does not.
  By the design, F-W is not started for vips on this ground (bodytrack's
  QW failure is a separate matter).
- **K2 for both:** the gap is in plain stores, not lock words. RMW events are
  4% of gem5's fluidanimate events and 3% of vips's. ChampSim's plain stores
  find another core's copy 2.6x (fluidanimate) and 3.1x (vips) less often
  than gem5's.

## Reported, deciding nothing

| | fluidanimate gem5 | fluidanimate ChampSim | vips gem5 | vips ChampSim |
|---|---|---|---|---|
| distinct lines | 7,248 | 7,529 | 2,762 | 974 |
| top 10 lines' share | 0.6% | 2.6% | 8.4% | 6.5% |
| events on lines an RMW touches | 1,849 of 43,879 | 1,379 of 18,744 | 90 of 3,184 | 14 of 1,031 |
| events per requester | 10,882 / 11,005 / 10,963 / 11,029 | 4,663 / 4,577 / 4,647 / 4,857 | CPUs 3-6: 869 / 741 / 686 / 888 | cores 0-3: 441 / 16 / 85 / 489 |
| holders per event (1 / 2 / 3) | 43,874 / 4 / 1 | 18,736 / 5 / 3 | 3,233 / 7 / 2 | 1,031 / 0 / 0 |
| events whose every holder was stale | 87 | -- | 0 | -- |

- fluidanimate: both simulators see sharing on about the same set of lines
  (7.2 k against 7.5 k), spread evenly over the four workers, with ChampSim
  finding about 0.43 of gem5's events on each core. The contention count
  (gem5 RMW events on lines RMW'd by two or more cores) is 1,836, i.e. every
  gem5 RMW event.
- vips: ChampSim's events touch a third as many distinct lines, and its
  cores are uneven (cores 1 and 2: 16 and 85 events, against gem5's 741 and
  686 for the matching threads).
- Parser counts: events the issue order pairs differently 24 (fluidanimate),
  1 (vips), 18 (canneal); every other parser count 0.

## What follows (by the design)

K2: the next round asks why ChampSim's stores find fewer holders (drift
within a phase, or private-cache capacity), in its own note. H5
(`gem5_settings_results_2026-11-17.md`) adds that gem5's out-of-order CPU
does not close the gap (fluidanimate 0.391, vips 0.165 under O3). Nothing is
scored or tuned; the scored verdicts (P15 fails on both) stand.
