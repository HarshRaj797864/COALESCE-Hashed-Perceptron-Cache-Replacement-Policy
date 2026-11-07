# Step 5: the replacement-policy runs on the final tool. Pre-registered 2026-10-19, before any run

Why: every policy result so far (A5 and its level-2 rerun, A6) ran on traces
whose threads drifted 8-19 M instructions apart (`drift_finding_2026-10-18.md`).
The final tool replays the program's synchronisation, with mutex order by
simulated timing. These runs are the policy evaluation of record for the
paper. COALESCE is the case study.

**Owner's decisions, 2026-10-19:**
- **COALESCE is arm B**, the documented design with all four fixes;
- **barnes std is added** as a second shared workload;
- **16 cores are included**, for canneal, in the shared regime.

## What runs

- **Binary:** `champsim_g5_034cd735`, the final tool. It replays
  synchronisation with mutex order by timing, uses private-cache coherence
  level 2, and has the gem5-rule counters; it passed Q0, Q0b and Q0m. If
  scoring steps 2 and 3 changes the tool, these rerun on the changed one.
- **Policies (9):** lru, srrip, drrip, ship, hawkeye, mockingjay, random,
  srrip_bias, coalesce (arm B).
- **Traces:** the synchronised traces in `traces/sync_mx/` (traced
  2026-10-19 with the fixed tracer): canneal 4 and 8 workers, barnes std
  (thread 0 cut at its parallel start), ocean 4 threads. **canneal 16
  workers** is traced the same way (`canneal 16 15000 2000 100000.nets
  128`, threads 1-16), into the same directory.
- **The configurations** (50 M + 100 M a core; LRU-family geometry as in
  `make_config.py`):

  | workload | cores | LLC | regimes | jobs |
  |---|---|---|---|---|
  | canneal | 4, 8 | fixed 2 MB, and 2 MB per core | shared, private | 2 x 2 x 2 x 9 = 72 |
  | barnes std | 4 | fixed, per core | shared, private | 36 |
  | ocean (control) | 4 | fixed, per core | shared, private | 36 |
  | canneal | 16 | fixed, per core | shared | 18 |
  | canneal, 64 LLC MSHRs | 4 | fixed | shared | 9 |

  171 jobs, the 16-core ones first. Trees `phaseA_b3_p2_<workload><cores>[_scaled|_mshr64]`,
  `regime_<r>/<workload>_<n>core/<policy>/run.log`.
- **Ranking metric**, as before: `max_cycles` across cores, lower is better,
  with the gap to the adjacent policy and to LRU. Kendall τ over the 9
  policies.

## Checks before anything is scored

- **Every run completes.** None reaches a trace end. Self-check,
  stale-holders and view-order violations are 0. The log prints level 2 and
  `SYNC MUTEX ORDER: timing` wherever the trace has mutex records.
- **The regime flag is honoured:** the private regime shows 0 aliased fills
  and 0 coherence invalidations; the shared regime shows non-zero aliased
  fills (CLAUDE.md's standing check).
- **QT** for canneal 16: 16 traces, each at least 172.5 M instructions.

## Predictions

From the level-2 A5 rerun on drifting traces: at one LLC size, sharing kept
the order (τ +0.64 to +0.86), and the best gain over LRU was 2-3% private
against 13-14% shared at 8 and 16 cores.

- **P11, sharing keeps the order at one size:** for canneal (4, 8 cores) and
  barnes std, at each LLC size, the shared and private rankings agree with τ
  at least +0.5.
- **P12, sharing raises the stakes:** for canneal at fixed 2 MB, the best
  policy's gain over LRU is larger in the shared regime than in the private,
  at every core count with both regimes (4, 8).
- **P13, the control:** ocean's shared and private rankings agree with τ at
  least +0.7, at both sizes.
- **P14, MSHRs:** canneal 4c fixed shared with 64 LLC MSHRs ranks the 9
  policies with τ at least +0.7 against the same run with 16.
- **Reported, no prediction:**
  - the ranking on synchronised traces against the level-2 A5 rerun on
    drifting traces (canneal 4/8/16c, ocean 4c), i.e. does replaying
    synchronisation change the policy conclusions;
  - COALESCE's place and its gaps to its neighbours and to LRU (the case
    study; its architecture stays frozen);
  - 16 cores (shared only, so no P11 there).

## How the outcomes are read

- **P11-P13 hold:** the A5 conclusion (sharing keeps the order but raises the
  stakes) stands on the final tool, now on two shared workloads.
- **P11 fails on a workload:** sharing reorders policies there at one LLC
  size. That is the claim A5 first made and then withdrew; it is reported
  with the size control beside it.
- **P14 fails:** the 16-MSHR choice matters to the ranking, and the paper
  states it beside every ranking.
- **Nothing is rerun to change an outcome.** A failed check (above) is
  fixed, and the affected runs rerun, before any number is read.

Nothing is tuned after a number is seen.

## Amendment 1, 2026-11-02: before any step 5 run, and before the streamfix counts are read

The owner set the first three items on 2026-10-27, to be written before
launch. The fourth follows from `stream_fix_design_2026-11-02.md` (F2). It is
written before any of that design's counts have been pulled or seen.

1. **Binary: `champsim_g6_1e3060c1`** (amendment 2 of
   `b3_g5rule_design_2026-10-19.md`). It is the "changed tool" this design's
   binary clause anticipated, and step 4 ran on it.
   - It passed Q0 and Q0m against `champsim_g5_034cd735`.
   - Q0-full: its 12 B3 reruns print what g2 printed, apart from the new
     lines.
   - Q3 holds in 12 of 12.
   - It adds records only (the view-order split). The `pol` variant of
     `sync_server.sh` already runs it: it reads `~/sync_g6/BIN` and requires
     that binary's Q0 and Q0m.
2. **The view-order check is Q3's:** `VIEW-ORDER VIOLATIONS UNEXPLAINED` is 0
   in every run. Raw violations explained by silent re-listing are allowed.
3. **barnes std runs, but is not scored.** Its 36 runs are made, but no P11
   verdict and no ranking is drawn from them as a result until barnes agrees
   with gem5. Under synchronised replay it fails B3: drift P1, and R
   0.23-0.27 in both views (`sync_mx_g5_results_2026-10-27.md`). It is
   reported as not validated. P11 is then scored on canneal 4 and 8 alone.
4. **The traces must stand under F2** of `stream_fix_design_2026-11-02.md`.
   A workload's traces stand if F2 does not hold. If F2 holds, they stand
   only if its program's v2 differs by under 2% on every rate between the two
   CPUIDs. That is F2's rule for the earlier programs, read from
   `stream_check2.py check`.
   - Programs: canneal (its 4- and 8-worker rows), ocean, and barnes std
     (all three spans).
   - **canneal 16** is traced with the CPUID canneal's other traces use.
   - A workload whose traces do not stand is traced again under gem5's
     CPUID before its runs count. Runs on its old traces are not scored.
   - **Step 5 is launched only after the streamfix pull is scored.** It does
     not wait for step 4's retrace: none of step 5's workloads is among the
     programs F2 retraces.

Nothing else changes: policies, configurations, lengths, predictions
P11-P14, and how outcomes are read.
