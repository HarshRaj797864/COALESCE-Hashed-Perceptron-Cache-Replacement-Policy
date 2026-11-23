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

## Amendment 2, 2026-11-10: a tie found by the standing check, before any P11-P14 number is read

All 171 runs completed on 2026-11-07 (23:58 server time). The checks were run
alone first (`scripts/policy_score.py check`, `c88dddb`; rows v29, b3 v20,
`p2_log_rows_v1`). Every check of this design holds: C1-C4, C6 and C7. One of
`analyze_rows.py`'s standing checks (C5) failed:

- **barnes std, 2 MB a core, shared: `srrip_bias` and `srrip` share max_cycles
  111,577,821.** That check is how Hawkeye = SRRIP was caught, so the score
  stopped there.
- **Diagnosis, from the two logs (barnes is not scored, item 3 above):**
  - they are different simulations: cpu0's LLC counts differ by one miss, and
    cpu0 finishes its 100 M at cycle 103,837,130 under `srrip_bias` against
    103,837,000 under `srrip`;
  - the run ends when its last core reaches its count. That is CPU 1, at
    111,577,821 under both; CPUs 2 and 3 finish at the same cycles in both.
  - At 8 MB this span barely misses the LLC, so the two policies differ in a
    few misses, none on CPU 1's path.
- **Rule added to C5:** a shared max_cycles is a tie, not a disguised
  policy, only when the runs' LLC counters differ and the same core finishes
  last at the same cycle in each (`explained_tie`, read from the logs:
  `p2_log_rows` gains `lastcpu`, `lastcyc`, `llcmd5`). Any other shared count
  still fails. The self-test covers an explained tie and two unexplained ones
  (identical LLC counters; another last cycle).
- No run is rerun: each run is deterministic, and nothing here is a defect.
  barnes std stays unranked; P11-P14 are on canneal and ocean.

Nothing else changes.

## Amendment 3, 2026-11-14: H7, step 5 on the F-C binary (before any rerun, before any of its numbers exist)

F-C was adopted on 2026-11-14 (`lock_fix_results_2026-11-14.md`). A
contended waiter now issues one ownership request for the lock word. That
note's rule says the paper reports the F-C binary. Step 5's 171 runs (g6)
were not covered by it (its "What follows", item 3). **Owner, 2026-11-14:
"H7: rerun".** PLAN § 10 item 9, H7.

**What runs.** The 171 jobs of `policy_jobs.py`, unchanged (the server's
`~/sync_pol/JOBS` must equal its output byte for byte, md5 `ec5c7410`).
- **Binary:** `champsim_fc_a2e88e46` (`~/sync_fc/BIN`, md5 `a2e88e46...`),
  the binary of `breadth_bc_design` amendment 10, with the same guards: F-C's
  Q0, Q0m, Q0r and K0 markers, and the binary prints `SYNC LOCK WORD`.
- **Each rerun** is one g6 run: its own config
  (`~/sync_pol/cfg/<suffix>_<regime>_<policy>.json`) plus `"sync_lock_word":
  "request"` and nothing else (the config must not already set it). Its
  window (`Warmup` / `Simulation Instructions`) and its traces (its `CPU n
  runs` lines, by CPU) are read from its own log. The reference must be
  complete. Both regimes get the setting: the binary, not the regime, is
  what the paper reports. In the private regime the waiter's request goes to
  its own core's copy of the page.
- **Into** `phaseA_b3_p3_<suffix>/regime_<r>/<wl>_<n>core/<policy>/run.log`,
  with `run.log.bin` naming the binary. The 16-core jobs come first, 12 at a
  time, nice 19. A run already complete on this binary is skipped.
- The g6 rows (`phaseA_b3_p2_*`) are kept and reported as "before F-C".
  **The p3 rows become step 5 of record** once their checks hold.

**Checks before any p3 number is read.** These are C1-C7 of this design, by
`policy_score.py` with the tree prefix `phaseA_b3_p3_` (the configs from
`~/h7/cfg`), and amendment 2's tie rule, unchanged. Plus:
- **C8:** every p3 log prints `SYNC LOCK WORD: request` once, and one
  `LOCK-WORD REQUESTS` line per CPU; its `.bin` names
  `champsim_fc_a2e88e46`; its window and its traces (by CPU) equal its g6
  reference's.

A failed check is fixed and the affected runs rerun before any number is
read, as before.

**Predictions** (from `lock_fix_results_2026-11-14.md`: canneal's measured
spans issue no request, 3 and 7 in warm-up; ocean issues 879 in the B3
span):
- **P-H7a:** every canneal run's max_cycles lies within ±0.5% of its g6 row's
  (all 99 canneal jobs: 4 and 8 cores in both regimes, 16 cores shared,
  both sizes, and the MSHR set).
- **P-H7b:** P11-P14 read the same verdicts on p3 as on p2: P11 FAILS (2 of
  4), P12 HOLDS, P13 HOLDS, P14 HOLDS.
- **Reported, no prediction:** every run's change in max_cycles (p3 against
  p2) and its measured lock-word requests; for each of the 19 trees and each
  regime, Kendall τ between the p2 and p3 orders; COALESCE's place and gaps
  on p3. Once H3 is scored, each change is shown beside that class's δ
  (`h3_statistics_design_2026-11-14.md`). No verdict rests on it.

**How the outcomes are read.** The p3 rows replace the p2 rows as step 5's
result in the paper whatever P-H7a and P-H7b read: F-C is the tool. Both
predictions test how far the change reaches.
- **If P-H7a fails**, the canneal runs outside ±0.5% are diagnosed from
  their logs, starting from the requests made in warm-up. The paper states
  the difference.
- **If P-H7b fails**, the paper reports the F-C verdicts and states that the
  g6 verdicts differed.
- **barnes std** runs and is checked, and stays unranked (amendment 1, item
  3): barnes std start still reads 0.449 on F-C.
- H3's noise floor was measured on g6 (canneal 8c). It is carried over to
  p3 only if P-H7a holds for canneal 8c's eight H3 configurations.

**Scoring**, after `bash scripts/h7_all.sh pull` and `scripts/pull_results.sh`
(rows vN, b3 vK), every command with `POLICY_TREE=phaseA_b3_p3_`:
- `policy_score.py logrows simulator/results/h7/logs simulator/results/h7/cfg
  > bench/policy_sanity/p3_log_rows_v1.txt`
- `policy_score.py fccompare ROWS B3ROWS p3_log_rows_v1.txt
  simulator/results/policy/qt simulator/results/policy/logs
  simulator/results/h7/logs`: C1-C7 on the p3 trees (as `check`, with
  amendment 2's tie rule), then C8 from the p2 and p3 logs. Only if every
  check holds does it print the reported table, P-H7a and P-H7b.
- Then `policy_score.py score ROWS B3ROWS p3_log_rows_v1.txt
  simulator/results/policy/qt`: P11-P14 and the rankings on p3.

Nothing else changes: policies, configurations, lengths, traces, P11-P14 and
their thresholds.

**H7 build and rehearsal record (2026-11-14, before any launch).**
- `scripts/h7_server.sh` (`guards`, `chain`, `status`, `list`, `stop`) and
  `scripts/h7_all.sh` (`go`, `guards`, `status`, `list`, `pull`, `stop`);
  `policy_score.py` gains `POLICY_TREE` (default `phaseA_b3_p2_`) and
  `fccompare`.
- **The scorer is unchanged where it existed.** On rows v29, b3 v20 and
  `p2_log_rows_v1.txt`, `score` prints byte for byte what the committed
  scorer prints, and `logrows` reproduces `p2_log_rows_v1.txt` byte for
  byte. Its self-test passes. `verdicts()` reproduces step 5's scored
  verdicts (P11 2 of 4, P12, P13, P14).
- **fccompare on made-up p3 data** (the 171 p2 logs with the lock-word
  lines added; canneal max_cycles +0.1%):
  - C1-C8 hold, P-H7a and P-H7b HOLD, and amendment 2's tie is explained on
    the p3 tree.
  - Nine faults were each stopped before any number printed: no `SYNC LOCK
    WORD` line, a missing requests line, a wrong `.bin`, another window,
    another trace on one CPU, a missing CPU line, an absent p3 log, a p2 log
    printing the setting, and a missing p3 row (C1).
  - Without `POLICY_TREE` it refuses. A canneal run moved +1% is marked
    OUTSIDE and P-H7a reads FAILS, still scored.
- **The runner against a stand-in server** (scratchpad `h7reh/`: step 5's
  171 real logs and configs, 36 stand-in traces, a stand-in F-C binary that
  refuses a config without the setting):
  - The guards pass clean. Seven faults are each refused alone: binary md5,
    K0 marker, BIN, a short JOBS, a JOBS other than step 5's, an incomplete
    reference, a missing config. No chain starts after a failed guard.
  - Stopped mid-flight (12 running), no stand-in run is left behind.
  - The full chain: 169 complete. A config that already sets the setting,
    and an aborted run, each FAILED with their cause.
  - Fixed and relaunched: only those two ran (169 "complete already").
    Relaunched again: nothing runs.
  - The 171 configs equal the references' apart from `sync_lock_word`.
    `logrows` reads 171 complete, LLC MSHRs 16 x 162 and 64 x 9.
    `fccompare` on the outputs: C1-C8 hold.
  - One runner defect, fixed: the driver log's request totals summed the
    wrong fields (always 0). The scorer reads the logs, not that line.

**H7 launch record.** `bash scripts/h7_all.sh go` (laptop 18:54, server
2026-11-14 13:24:41), from `a043546`. Uploaded `~/h7/h7_server.sh` (md5
d80ef59b) and `~/h7/JOBS` (ec5c7410). Guards passed: `champsim_fc_a2e88e46`,
md5 a2e88e46; F-C's Q0 / Q0m / Q0r / K0 markers present; JOBS equal to step
5's; 171 references complete, 171 configs; 81 GB free. The chain started 171
reruns, 12 at a time, with 12 running 30 s later. Load about 103 on 48 cores.
Next: `bash scripts/h7_all.sh status`, then `pull` and the scoring above.

## Amendment 4, 2026-11-17: a cut-off for H7, before any p3 number is read

**Why.** On 2026-11-17, 2 of H7's 171 reruns were complete; the 16-core jobs
run first and take about 60 h each under the server's load (about 386 on 48
cores). The results freeze is planned for Tue 8 Dec. No p3 number has been
read.

**The rule.**
- **Cut-off: Sat 2026-12-05 23:59 server time.**
- **If all 171 p3 runs have completed by then, and C1-C8 hold**,
  amendment 3 applies unchanged: the p3 rows are step 5 of record.
- **Otherwise, step 5 of record stays the p2 (g6) rows** as scored
  2026-11-10 (`policy_results_2026-11-10.md`). The completed p3 runs are
  reported as a partial check, labelled "partial, F-C":
  - C1-C8 on the completed runs;
  - each completed run's change in max_cycles against its p2 row;
  - P-H7a on the completed canneal runs (stated as "k of 99");
  - Kendall τ between p2 and p3 only for trees whose runs are all
    complete.
  - P-H7b is not read: it needs every tree.
- The paper then says step 5 ran on the binary before the lock fix,
  that the lock fix issues no measured request on canneal (its 4-core
  rerun: 0 measured, 3 / 7 in warm-up), and the partial check's result.

**Not decided here.** Whether H7's remaining runs are stopped early to give
their cores to Part B's reruns is the owner's decision. If they are stopped,
the rule above applies as if the cut-off had passed.

## Amendment 5, 2026-11-23: H7 resumes after the 22 Nov reboot with a 5 GB disk guard (before any p3 number is read)

- **State:** H7 had 27 of 171 complete when /home filled and the server
  rebooted (22 Nov).
- **The owner's decision (2026-11-23):** H7 resumes. Its runner's disk
  guard is 5 GB (was 20: it writes logs only), and nothing else changes.
- **Amendment 4's cut-off stands:** step 5 of record stays p2 unless all
  171 p3 runs complete.
- C0f now takes its L = 0 rows from H7's p3 runs (C0f amendment 1).
- See `relaunch_2026-11-24.md`.
