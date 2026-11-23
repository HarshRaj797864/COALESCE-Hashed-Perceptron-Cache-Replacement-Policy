# F-C, the lock fix, scored: ADOPTED (2026-11-14)

Design and fixed rules: `lock_fix_design_2026-11-12.md` (`80371bf`;
amendment 1 `e033dfc`, amendment 2 and its check record `ccba769`).
Scorer `scripts/lock_fix_score.py`, last changed `c36e4f4` (2026-11-12),
before the reruns started. Its self-test passes, and its parser reproduces
the committed rows on 14 of 14 scored logs. Score output:
`lock_fix_score_v1.txt` (this commit).

## The runs

- Check passed 2026-11-12 on `champsim_fc_a2e88e46` (Q0 8/8, Q0m 3/3, Q0r
  3/3, K0: suites 66/66 and 57/57, 57 logs identical).
- The 14 reruns started 2026-11-13 03:41 server time on the owner's word
  (`bash scripts/lockfix_all.sh go`), into `phaseA_b3_fc_*`, setting
  `sync_lock_word request`.
- **Chain ended 2026-11-13 21:01: 14 of 14 complete; Q3 holds on 14 of 14**
  (unexplained view-order violations 0).
- Pulled 2026-11-14 (`bash scripts/lockfix_all.sh pull`; logs in
  `simulator/results/lockfix/logs/`, untracked); scored the same day.
- Every rerun qualifies: complete, the setting printed once, one requests
  line per waited-acquires line, the scored log's warm-up, length and traces,
  level 2, no wrap, self-checks 0.

## The rules and what they read

R_g5 = (C / I_c) / (G / I_g); C and I_c from the rerun, G and I_g from the
gem5 rows of every earlier score (unchanged).

| span | role | R_g5 before | R_g5 F-C | traffic before -> F-C | requests (measured) | rule |
|---|---|---|---|---|---|---|
| barnes std window | failing | 0.249 | **0.954** | 0.970 -> 1.070 | 60,836 | P-F1 holds |
| barnes-256 | failing | 0.267 | **0.780** | 0.463 -> 0.583 | 271,993 | P-F1 holds |
| barnes std start | failing | 0.233 | **0.449** | 0.464 -> 0.504 | 44,246 | **P-F1 misses** |
| barnes std force | agreeing | 0.634 | 0.635 | 0.812 -> 0.815 | 15 | P-F2 holds |
| ocean 2 MB | agreeing | 0.682 | 0.712 | 0.920 -> 0.916 | 879 | P-F2 holds |
| canneal 4c 2 MB | agreeing | 1.016 | 1.018 | 1.043 -> 1.043 | 0 | P-F2 holds |
| canneal 8c | agreeing | 1.537 | 1.534 | 1.006 -> 1.006 | 0 | P-F2 holds |
| radix | agreeing | 0.990 | 0.988 | 0.996 -> 0.994 | 15 | P-F2 holds |
| lunc | agreeing | 1.831 | 1.830 | 1.109 -> 1.110 | 18 | P-F2 holds |
| ocean non-contiguous | agreeing | 0.663 | 0.701 | 0.983 -> 0.984 | 875 | P-F2 holds |
| fluidanimate | reported | 0.398 | 0.400 | 0.769 -> 0.769 | 68 | decides nothing |
| vips | reported | 0.309 | 0.308 | 0.947 -> 0.947 | 6 | decides nothing |
| bodytrack | reported | 0.350 | 0.352 | 0.566 -> 0.569 | 30 | decides nothing |
| fmm | reported | 0.670 | 0.725 | 0.771 -> 0.773 | 448 | decides nothing |

- **P-F1: 2 of 3** (barnes std window, barnes-256 in the band; barnes std
  start 0.449, below it).
- **P-F2: 7 of 7.**
- **P-F3: 12 of 12** spans whose traffic was in the band stay in it.
  barnes-256 (0.463 -> 0.583) and barnes std start (0.464 -> 0.504) move into
  the band; that is reported, not part of P-F3.
- **VERDICT (the rule fixed beforehand): F-C ADOPTED.** K0-K4 held (build
  and check records).

## Reported, deciding nothing

- **Requests equal the contended waited acquires in every span**, measured
  and warm-up alike: one request per contended acquire, as built.
- **Cycles** against the lock-wait reruns move by -0.20% to +0.47%
  (barnes-256 the largest).
- **Upgrades:** U_g5 unchanged within 0.01 wherever it is scored.
- **Events added per request** (rerun C minus scored C, over measured
  requests; approximate, since it includes the small timing shifts): barnes
  std window 0.563, barnes-256 0.574, barnes std start 0.564. That is about
  half of the lock-wait note's k = 1 to 2. That note predicted [0.614, 0.994]
  for barnes std start from k = 1 to 2; with about 0.56 it reads 0.449. Why
  a request adds about 0.56 gem5-rule events, not 1, is **not diagnosed**.
  Candidates, untested: the waiter's request finds the line already listed
  for the waiter, or the holder's copy already dropped (gem5-rule view
  forgets it). ocean 0.96, ocean non-contiguous 1.34 and fmm 1.30 are
  inflated by timing shifts on few requests.
- **fluidanimate stays at 0.400**, as the design expected (68 contended
  acquires). Its under-count stays open and is not from lock waits (H-C2's
  P-L1 missed there). vips and bodytrack do not move either.

## What follows, by the note's rule

1. **Every Part B ChampSim run is rerun on `champsim_fc_a2e88e46` with
   `sync_lock_word request`**, under an amendment written before those
   reruns. Traces, gem5 runs and counter runs are unchanged. The g6 runs of
   Part B that exist by then are kept and reported as "before F-C"; the F-C
   runs are the ones scored.
2. **The paper reports the F-C binary**, states the change (a contended
   waiter issues one ownership request for the lock word), and states the
   open under-counts: fluidanimate and vips (not from lock waits), barnes
   std start (0.449).
3. **Not covered by the note, so a decision for the plan:** step 5's
   policy runs (171, on g6). canneal's measured spans issue no request (only
   3 and 7 in warm-up), so its rows would be all but unchanged. ocean issues
   879 requests and moves R_g5 by 4%. Either they are rerun on F-C, or the
   paper states that the case study ran on the binary before F-C, with this
   table as the size of the difference.
