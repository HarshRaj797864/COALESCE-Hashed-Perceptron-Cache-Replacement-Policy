# Steps 2 and 3 scored: mutex order by timing (m2) and the gem5-rule view (g2). 2026-10-27

Pull of 2026-10-27 (`phasea_rows_v23.txt`, `b3_rows_v14.txt`; gem5 rows
regenerated and identical to `gem5_b3_rows_v3.txt`). Pre-registrations:
`sync_mutex_design_2026-10-19.md` (P1-P4), `b3_g5rule_design_2026-10-19.md`
(Q3, P5-P7). Scored with
`b3_score.py score ... m2 m2@std m2@leaf256 m2@held m2@e8` and the same for
`g2`. Nothing was tuned.

## Qualifying checks

- **m2, Q3 (no deadlock): holds.** 12 of 12 complete, 0 `SYNC DEADLOCK`, no
  trace reached its end. The traces are from the fixed tracer (8 of 8, QS
  held, locks recorded on every thread). barnes std force:
  `SYNC MUTEX ORDER: timing (1316 mutexes; ordered acquires 16; releases of a
  mutex not held 1)`.
- **g2, Q0m 2 of 2; Q0-full: 12 of 12 identical to m2** apart from the new
  lines. The view changes no behaviour.
- **g2, Q3 (VIEW-ORDER VIOLATIONS = 0): FAILS in 9 of 12 runs.**

  | run | violations |
  |---|---|
  | ocean 2 MB, ocean 8 MB, water-nsquared | 0 |
  | canneal 8c | 1 |
  | canneal 4c 2 MB, 8 MB | 2, 2 |
  | barnes-256 | 13 |
  | radix | 21 |
  | barnes std window / start / force | 23 / 24 / 32 |
  | fmm | 57 |

  In every run the view's event total is at most the bounded view's ("subset
  yes"). Likely cause, **from reading `sharer_directory.cc`, not yet
  confirmed by a run:** `dir_private_ownership_hit`, when no other core is
  listed, makes the requester the gem5-rule view's exclusive owner but leaves
  the protocol and bounded views as they were. A core whose L2 wrote the line
  back (removing it from those two views) while its L1D kept a copy then
  appears in the gem5-rule view only. gem5 would list that core, so the view
  is probably right and the design's invariant ("each view only forgets more")
  missed this path. By the design's rule, **Q fails: fixed before anything
  goes to the server**; this gates step 4 and step 5 on the g5 binary.
- **Cause CONFIRMED the same day** (amendment 2 of `b3_g5rule_design`,
  `7bf54fe`, written before the code). A new exact case, `silent_own`, builds
  the path by hand: an L1D copy kept while the L2C writes the line back, then a
  store. It met every pre-registered count at levels 0, 1 and 2 on its first
  run. At level 2 the gem5-rule view counts the next core's store miss (2)
  where the protocol view counts none (0), with 4 silent re-listings and 2
  violating lines left, both explained. The fix changes no view's rule, only
  records; Q3 now asks that the unexplained violations read 0.

## P1, drift (median core spread, from the heartbeats; s2 -> m2)

| run | s2 | m2 | needed |
|---|---|---|---|
| barnes std force | 6.08 M | **6.57 M** | < 4 M: **fails** |
| barnes-256, 140-150 M bin | 30.13 M | **21.89 M** | < 20 M: **fails** |
| ocean 2 MB / scaled | 0.94 / 1.21 | 1.39 / 1.38 | within 1 M: holds |
| canneal 4c / 8c | 0.85 / 0.87 | 0.78 / 0.70 | holds |
| radix | 0.95 | 0.92 | holds |

Reported: barnes std start 1.02 -> 0.57, window 6.96 -> 6.49; water 6.36 ->
6.24; fmm 15.62 -> 14.41.

Reading, pre-registered: **P1 fails on barnes while the barrier programs
hold: lock order is not the whole cause. Examine the per-core rates (IPC)
before scoring barnes. ocean, canneal and radix are scored.**

Per-core IPC, m2:
- barnes std force: 1.146 / 1.145 / 1.182 / 1.152 (within 3%);
- barnes std window: 0.986 / 0.878 / 1.181 / 0.874. gem5's window has the
  same order (instructions per core 96.2 / 104.3 / 112.1 / 89.4 M): core 2
  fastest, core 3 slowest;
- barnes-256: 1.023 / 1.041 / 0.991 / 1.026.

No core runs much slower than the others inside the measured spans, so
a per-core speed gap does not explain the force span's 6.57 M. Where it
comes from is not established.

## The stream check, m2 traces

Same verdicts as the older traces: canneal, canneal 8c, barnes std force and
window, radix and water-nsquared are the same stream. Known misses:
- ocean stores 1.088 (the known ocean caveat of 2026-10-12: its store rate
  was already below gem5's);
- barnes-256 stores 1.070 (1.058 before; the sync records add about 1%);
- fmm fails as before;
- barnes std start is not established (thread 0's serial start was not
  pulled).

## P2-P4 (m2, protocol view)

| | R_b | R_a | R_bounded | prediction |
|---|---|---|---|---|
| ocean 2 MB | 1.089 | 0.586 | 0.682 | **P2 holds** (R_a, R_bounded >= 0.5; were 0.08 / 0.09) |
| ocean 8 MB | 1.086 | 0.570 | 0.771 | reported |
| canneal 4c 2 MB / 8 MB | 1.259 / 1.137 | | 1.020 / 1.029 | **P3 holds** |
| canneal 8c | 1.718 | | 1.537 | **P3 holds** |
| radix | 43.29 | 0.990 | 0.990 | **P4 holds** (R_b > 2) |
| barnes std force / start | 0.741 / 0.250 | | 0.639 / 0.234 | not scored (P1) |

**The synchronised replay fixed ocean's residency gap:** the bounded view
gave ocean 0.091 on drifting threads. It now gives 0.682.

## P5-P7 (g2, the gem5-rule view), subject to the Q3 fix

| | R_g5 | prediction |
|---|---|---|
| radix | **0.990** (protocol 43.29) | **P5 holds** |
| ocean 2 MB / 8 MB | **0.682 / 0.768** | **P6 holds** |
| canneal 4c 2 MB / 8 MB | 1.016 / 0.927 | P7 holds |
| canneal 8c | 1.537 | P7 holds |
| barnes std force | 0.634 | P7 holds |
| barnes std start | **0.233** | **P7 fails** |
| barnes-256 | **0.267** | **P7 fails** |
| water-nsquared | 1.062 | reported (414 gem5 events < 500: not discriminating) |
| fmm | 0.670 | reported (not the same stream) |
| barnes std window | 0.249 | reported |

U_g5 (upgrades): ocean 1.025 / 0.952, barnes std window 1.566, water 0.948,
fmm 0.701.

The design's readings cover "P5-P7 hold", "P5 holds, P6 fails" and "P5
fails". **"P5 and P6 hold, P7 fails on barnes" was not foreseen.** barnes
fails in the protocol view too (0.250 / 0.267), so the miss comes from the
replay, not from the gem5 rule. It belongs with P1's barnes failure.

## barnes across the replays (reported; the mutex design's one ablation)

| | no sync (x2 / v5) | s2 (recorded order) | m2 (timing order) |
|---|---|---|---|
| bstd start R_b | 0.810 | 0.227 | 0.250 |
| bstd force R_b | 0.689 | 0.806 | 0.741 |
| barnes-256 R_b | 0.634 | 0.532 | 0.267 |
| barnes-256 U | 0.478 (v5) | 0.503 (bounded) | 0.842 |
| barnes-256 hand-overs, store misses + upgrades, / gem5 | | 0.578 | 0.730 |
| RMW issued per KI (bstd start / force / window) | 3.04 / 1.19 / 1.69 | 4.99 / 2.49 / 3.45 | 5.01 / 2.43 / 3.47 |

Under the timing order, barnes-256's lock hand-overs move from store misses
to upgrades: R_b halves and U rises. Total ownership transfers come closer to
gem5's (0.578 -> 0.730 of gem5). The replays issue about twice the RMW loads
per KI of the unsynchronised ones; a release is a fence, so fewer RMW loads
are forwarded from the store queue. **None of this is a scored measure.**
The primary measure stays R_b / R_g5, and it fails for barnes start and
barnes-256.

## What follows

1. ~~Confirm the view-order cause locally, fix it, pre-register the fix~~
   Done (above). On the server: `scripts/syncg6_all.sh` (build, Q0 and Q0m
   against the g5 binary, 12 reruns, Q0-full, Q3). **Step 4 and step 5 run on
   that binary** once its Q0 and Q0m pass.
2. barnes: find where the start span's drift and hand-over split come from,
   before scoring it. It is the one program family that does not agree.
3. ~~The owner decides whether R_g5 becomes the primary B3 measure.~~
   **DECIDED by the owner, 2026-10-27, before step 4 is scored: R_g5 is the
   primary measure**; R_b is reported beside it. P5 and P6 hold; P7 fails
   only on barnes, which fails in both views.
