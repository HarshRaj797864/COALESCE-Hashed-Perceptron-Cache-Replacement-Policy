# Round 2, step 1: the waited-acquire counter, scored. H-C2 SUPPORTED (2026-11-12)

Design and fixed prediction: `lock_wait_design_2026-11-06.md` (`9fe727f`;
§ 4 the prediction and the verdict rule). Scorer `scripts/lock_wait_score.py`,
last changed `2019f05` (2026-11-10), before the runs; its self-test passes.
Score output: `lock_wait_score_v1.txt` (this commit).

## The runs

- Launched 2026-11-11 on the owner's word (`scripts/lockwait_all.sh`):
  frozen `champsim_lc_c601b4e4`; Q0 8 of 8, Q0m 2 of 2.
- **14 of 14 reruns complete** (chain ended 2026-11-11 15:10 server time),
  into `phaseA_b3_lc_*`.
- **Q0-full: 14 identical, 0 differ** (every older line of every rerun equals
  the scored run's; only the new `MUTEX WAITED ACQUIRES` lines are added).
- Pulled 2026-11-12 (`scripts/lockwait_all.sh pull`, logs in
  `simulator/results/lockwait/logs/`, untracked); scored the same day.

## The rules (design § 4) and what they read

R_g5(k) = ((C + k·N) / I_c) / (G / I_g), N = measured contended waited
acquires summed over cores; C, I_c, G, I_g from the scored rows (equal in the
reruns by Q0-full).

| span | role | R_g5 | contended N | own | W_m | [R(1), R(2)] | rule |
|---|---|---|---|---|---|---|---|
| fluidanimate | failing | 0.398 | 70 | 52,492 | 2.53% | [0.400, 0.401] | **P-L1 misses (short)** |
| barnes std window | failing | 0.249 | 60,443 | 253,386 | 13.29% | [1.492, 2.736] | P-L1 holds |
| barnes std start | failing | 0.233 | 43,875 | 132,712 | 15.82% | [0.614, 0.994] | P-L1 holds |
| barnes-256 | failing | 0.267 | 271,397 | 1,695,138 | 67.87% | [1.160, 2.054] | P-L1 holds |
| barnes std force | agreeing | 0.634 | 36 | 86,151 | 7.16% | 0.684, 0.734 | P-L2 holds |
| ocean 2 MB | agreeing | 0.682 | 870 | 123 | 0.03% | 0.713, 0.744 | P-L2 holds |
| canneal 4c 2 MB | agreeing | 1.016 | 0 | 0 | 0 | 1.016, 1.016 | P-L2 holds |
| canneal 8c | agreeing | 1.537 | 0 | 0 | 0 | 1.537, 1.537 | P-L2 holds |
| radix | agreeing | 0.990 | 15 | 0 | 0.0007% | 0.990, 0.991 | P-L2 holds |
| lunc | agreeing | 1.831 | 18 | 0 | 0.0014% | 1.832, 1.832 | P-L2 holds |
| ocean non-contiguous | agreeing | 0.663 | 879 | 233 | 0.03% | 0.692, 0.720 | P-L2 holds |
| vips | reported | 0.309 | 9 | 0 | 0.004% | 0.311, 0.314 | decides nothing |
| bodytrack | reported | 0.350 | 30 | 18 | 0.005% | 0.351, 0.352 | decides nothing |
| fmm | reported | 0.670 | 449 | 32,711 | 2.91% | 0.713, 0.756 | decides nothing |

(W_m: measured cycles held for a mutex over measured cycles, summed over
cores.)

**P-L1 holds on 3 of 4 failing spans (fluidanimate short); P-L2 on 7 of 7.
VERDICT, by the rule: H-C2 SUPPORTED. The F-C note is written next.**
No overshoot case applies: R(1) ≤ 2 on every failing span (barnes std
window 1.492, barnes-256 1.160); R(2) above 2 on those two is inside the
interval the rule reads.

## What the counts say beyond the verdict (reported, deciding nothing)

- **barnes is where the contended acquires are.** Tens of thousands in each
  failing barnes span (271,397 in barnes-256), against at most 879 anywhere
  else. The predicted correction is the right size only there.
- **fluidanimate's waits are its own.** 70 contended against 52,492 own
  waits (a core held only by its own release still in flight: a release is
  a fence and retires once the core's older stores are performed). The
  missing lock-word transfers cannot be its cause; F-C is **not** expected to
  move fluidanimate, and its under-count (and vips's, bodytrack's) stays
  open. Round 1's other leads for it remain (drift; for vips and bodytrack
  the untraced main thread).
- The own waits are large in barnes and fmm too (and in barnes std force,
  which agrees). They cost cycles (W_m), not coherence events: no other core
  touches the lock word while a core waits for its own release.
- barnes std force and window share their warm-up (51,446 contended in
  warm-up in both), as they must: the same traces up to the window.

## Next

F-C's note (pre-registered before it is built): the replay issues the
waiter's lock-word access for a contended hold, so that the holder's traced
unlock and the waiter's traced lock each find the line at the other core, as
in gem5. PLAN § 10 item 8's rule stands: **F-C enters the paper only if it is
scored at 4 cores by Fri 20 Nov**; then every Part B point is rerun on the
fixed binary under an amendment written before those reruns. Where it would go
in the code: PLAN § 10 item 8 (read 2026-11-12).
