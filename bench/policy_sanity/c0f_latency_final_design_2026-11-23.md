# C0f: the invalidation latency on the final binary (pre-registration, 2026-11-23)

Written and committed before any C0f run exists. The owner asked on
2026-11-23 for every weakness to be tackled ("finish / start everything").

## Why

- **The case study ranks policies by cycles.** The tool charges no time for
  an invalidation or an upgrade (paper, limitation i).
- **C0 measured this** (`c0_latency_design_2026-10-14.md`,
  `c0_results_2026-10-17.md`). At 20, 50 and 100 cycles per event, the
  orders held: canneal 4c and 8c τ +1.00, ocean +0.93.
  - That was on `champsim_b3v4_69ebdcce`, before synchronized replay, the
    gem5-rule view and the lock rule (F-C).
  - The paper can therefore only cite it as "an earlier version".
- **A reviewer will ask** whether rankings made by cycles survive a cost for
  coherence on the tool the paper reports. C0f answers that on the final
  binary.

## What runs

- **Binary:** `champsim_fc_a2e88e46`, the final binary (F-C), unchanged.
  - Its `coherence_latency` setting is C0's own (`e620494`, 2026-10-14,
    older than F-C).
  - At L > 0, a request that must take its line from other cores waits L
    cycles before its tag check (C0's design, "What changes").
- **Jobs:** step 5's 27 jobs at a fixed 2 MB in the shared setting:
  `canneal4`, `canneal8` and `ocean4`, regime `shared`, 9 policies each.
  These are the lines of `policy_jobs.py` (md5 `ec5c7410`) with suffix in
  {canneal4, canneal8, ocean4} and regime shared. This is C0's scope, with
  step 5's nine policies.
- **Each job runs twice:**
  - **L = 0:** its step 5 config plus `"sync_lock_word": "request"`. This
    is exactly H7's config.
  - **L = 100:** the same, plus `"coherence_latency": 100`, the largest C0
    tested.
  - Same window and traces as the job's step 5 reference (its log's `CPU n
    runs` lines). 54 runs.
- **Trees:** `phaseA_b3_c0f0_<suffix>` and `phaseA_b3_c0f100_<suffix>`.
- **Scheduling:** 8 at a time, nice 19, the 8-core jobs first. Detached,
  on the owner's word.
- **Cut-off:** runs not complete by Sat 5 Dec 23:59 server time are
  reported as not run. A configuration missing any of its 18 runs is not
  scored.

## Checks (before anything is read)

- **QF0, L = 0 is H7:** where H7's `phaseA_b3_p3_` run of the same job is
  complete, the two logs are equal apart from wall-clock lines.
  - The config is identical and both runs are deterministic.
  - Reported as n of m; any difference stops the scoring.
- **QF1, the latency acts:**
  - Every L = 100 log prints `COHERENCE INVALIDATION LATENCY (CYCLES):
    100`, and every L = 0 log prints no such line.
  - The summed `COHERENCE LATENCY WAITS` is non-zero in every L = 100 run.
- **QF2:** every run complete, with no SYNC DEADLOCK, no end of trace, and
  zero unexplained view-order violations.

## Predictions

- **P1, the order holds:** for canneal 4c, canneal 8c and ocean 4c, Kendall
  τ between the order at L = 100 and at L = 0 is at least +0.89. That is at
  most two discordant pairs of the 36.
  - Ties in max_cycles are ordered by name, as in step 5.
  - H3's noise ceiling, if scored by then, is reported beside τ. It changes
    no verdict.
- **P2, the cost is small and nearly uniform:** at L = 100, the spread of
  the rise in max_cycles across the nine policies is under 1 percentage
  point, on each configuration.
- **P3:** for LRU, max_cycles at L = 100 is at least its value at L = 0, on
  each configuration.

## Reading (fixed now)

- **P1 holds on all three:** limitation (i) cites the final binary.
  "Charging 100 cycles for every invalidation and upgrade leaves the order
  (τ …), as a lower bound (stores that do not wait at retirement)."
- **P1 fails anywhere:** the case study states that its order depends on
  the cost of coherence, which pairs move, and by how much. COALESCE's
  rank at L = 100 is reported either way.
- **P2 or P3 fails:** reported with sizes. Neither voids P1.
- **Not done:** tuning L, or adding L values, after a τ is seen.

## Tools

- `scripts/c0f_server.sh`: a copy of H7's runner. Its job list holds both
  latencies, and its config is H7's plus the latency key at L > 0.
- `scripts/c0f_all.sh`: `go` (owner's word), `guards`, `status`, `list`,
  `pull`, `stop`.
- `scripts/c0f_score.py`: QF0-QF2 from pulled logs and H7's pulled logs,
  then P1-P3 from the rows (`phasea_rows`, through `policy_score.order`).

## Build and rehearsal record (2026-11-23, before any C0f run)

- **Checked in the source:**
  - `main.cc:226` prints `COHERENCE INVALIDATION LATENCY (CYCLES): L` only
    when L > 0.
  - `plain_printer.cc:148` prints `<cache> COHERENCE LATENCY WAITS: n`
    only when L > 0.
  - The `coherence_latency` key is read by `legacy_environment.cc:663` and
    needs `private_coherence` 2 (`sharer_directory.cc:162`).
  - F-C's full md5 is the one in H7's guard (`a2e88e46788e…`).
- **The 27 jobs:** `policy_jobs.py`'s lines with suffix canneal4, canneal8
  or ocean4 and regime shared, md5 `96258bb9`. The runner and the wrapper
  both check it.
- **Scorer:** `c0f_score.py` self-test 15 of 15.
  - On step 5's real rows, renamed as both latencies, it reads τ +1.000 and
    a rise of 0 on all three configurations.
  - Its orders equal step 5's published ones (COALESCE 4th at canneal 4c,
    1st at 8c, 6th at ocean 4c).
- **Rehearsed against a stand-in server** (a stand-in binary that prints the
  lines read; real `policy_jobs.py` and `make_config.py` configs):
  - The chain ran 54 of 54, with the 8-core jobs first.
  - All 54 configs are equal to their reference plus exactly
    `sync_lock_word` (and `coherence_latency` 100 at L = 100).
  - QF0 holds 2 of 2 on wall-clock-only differences and catches one
    differing log. QF1 and QF2 hold.
  - **Guards refuse:** a wrong binary md5, a missing F-C marker, an edited
    JOBS, an incomplete reference, a missing step 5 config, and a binary
    without the latency line.
  - **Relaunch:** a relaunch after completion does nothing. One removed run
    is rerun alone.
  - A reference config that already sets the latency fails that run only.

## Amendment 1, 2026-11-23: L = 0 from H7, three controls; disk guard 5 GB (before any C0f run)

- **What changes:**
  - C0f runs all 27 jobs at L = 100, and at L = 0 only LRU in each
    configuration (`L0_SET`; 3 runs).
  - The other L = 0 rows are H7's p3 runs, which are this design's L = 0
    runs by construction.
- **QF0** requires each control to equal H7's p3 log.
- **QF0c is new:** every job's L = 0 config must equal H7's, and its L = 100
  config must be that plus `coherence_latency` 100.
- `L0_SET=all` restores the 54 runs.
- **Unchanged:** P1-P3, the cut-off and the reading.
- Built and rehearsed as recorded in `relaunch_2026-11-24.md` § 5:
  self-test 22/22.
