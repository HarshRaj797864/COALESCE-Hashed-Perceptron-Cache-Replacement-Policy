# Matched B3 windows: pre-registration (2026-11-17)

Written before any code for it exists and before any number it defines has
been computed. This is the owner's decision of 2026-11-14 ("matched B3
windows, own note"; `v2_located_results_2026-11-14.md`, "What follows",
item 2).

## The question

B3 compares two event rates, each per 1,000 instructions:

- gem5's store-time sharing events (SS + MT L1_GETX) between its two stops;
- ChampSim's gem5-rule events over ChampSim's measured phase.

gem5 stops when its *first* worker reaches the stop. So its window holds
each thread's instructions from wherever that thread was at the low stop to
wherever it was at the high stop. ChampSim's measured phase holds each
core's instructions from its warm-up end (~50 M) for at least 100 M.

The located windows (amendment 12 of `breadth_bc_design`) put gem5's
per-CPU positions on the traces. At the high stop some threads lag by tens
of M: fluidanimate_16 by 43, barnes_16 by 29, volrend_16 by 36-40, lunc_16
by 18. **Does that placement move R_g5?** This note measures it. It does
not replace R_g5.

## The measure, R_g5m (matched)

- **gem5's side is unchanged:** its events and instructions between its
  stops, exactly as R_g5 has them. gem5's L2 transition counters cannot be
  split by requester without ProtocolTrace (H6(b)), so nothing on that side
  changes.
- **ChampSim's side:** the gem5-rule RFO events (the R_g5 numerator,
  `cache.cc` `dir_on_llc_request`, `g5_others != 0`) are counted by the
  requesting core's **position** when the LLC accepts the RFO.
  - Position is that core's `num_retired`, counted from its trace's start
    and including sync records, i.e. the trace's record index.
  - A store's RFO leaves after the store retires, so the position runs at
    most a few thousand instructions ahead of the store's own index. With
    bins of 100,000, this matters only at a window's edges.
- **The matched window of core c** is the located window of the thread it
  replays:
  - `[rec_lo_t - base_t, rec_hi_t - base_t)`, from the counter's grid
    (`v2_located.py`, LOCPT rows) for each of the three gem5-CPUID counter
    runs.
  - `base_t` is the counter's window start for that thread (its WIN lo)
    minus the ChampSim run's warm-up instructions (from the run's log).
    This maps the counter's record index to the replayed trace's (thread
    0 cut at its anchor; radix's skip).
  - Core c's thread is read from the run log's `CPU c runs ...` line.
- **R_g5m** = (1000 x matched events / matched instructions) / (gem5's
  events per 1,000 instructions).
  - Matched events: the sum over cores of the events in the bins whose
    start lies in core c's matched window.
  - Matched instructions: the sum over cores of the windows' lengths.
  - One value per counter run; reported as the range over the three, as v2
    is.
- **Coverage:** every core's matched window must lie inside that core's
  measured span (its position at the measured phase's start and end). A
  window is clipped to the span. If any core is clipped by more than
  1,000,000, R_g5m is **not computed** for that key (reported with the
  reason).

## The instrument (records only)

- The environment variable `COHERENCE_POSITION_BINS=B` (B = 100000),
  read like `COHERENCE_EVENT_LOG`. No config key, so a run's config is
  byte for byte its reference's.
- With it set, the run also prints:
  - `B3 POSITION BINS: B instructions`;
  - per core: `CPU c MEASURED POSITIONS: from X to Y` (its `num_retired`
    at the measured phase's start, and at the phase's end, i.e. when the
    last core finishes, as the instruction totals are);
  - per core: `CPU c GEM5-RULE RFO EVENTS BY POSITION: k:n ...` (bin
    index:count, non-empty bins, every phase).
- Without it, nothing is printed and nothing is recorded.
- The binary: the F-C sources plus this instrument, built in its own tree
  (`~/mw_build`), frozen as `champsim_mw_<md5>`.

## Checks (each must hold before anything is read)

- **QM0, unset = the F-C binary.** As F-C's check, with the instrument off:
  - Q0: canneal 4c without sync records, LRU and Hawkeye, both regimes,
    levels 0 and 2; 1 M + 2 M.
  - Q0m: barnes std force, ocean 4, canneal 4 with their F-C configs.
  - K0: the exact suite with both binaries.
  - Every line equal, and no new line.
- **QM1, set = unset apart from the new lines.** The Q0m spans with the
  instrument on:
  - every other line equal;
  - summed over the cores, the bins whose start lies in each core's
    measured span come within 0.5% (or 10 events) of the existing measured
    counter, `LLC COHERENCE DIR RFO GEM5-RULE EVENTS`. That counter is
    per cache, not per core, so the test is on the total.
- **QM2, the full-length identity.** Each matched rerun prints every line
  of its reference run (the scored F-C rerun of the same key) apart from
  the new lines and the time stamps.

## Scope (fixed now)

- **Keys:** those with gem5-CPUID counter runs, so a located window exists:
  - Part B's keys;
  - set 2's fluidanimate_4 and vips_4, oceannc_4 (reported apart, as
    always);
  - streamcluster_4 (h2's count).
- **Set 1** (ocean, canneal, radix, barnes std, barnes-256, lunc 4c) has
  no gem5-CPUID counter runs and is out of scope. It is stated as such,
  with gem5's per-CPU spread at its stops reported from `gem5_percpu_v3`
  (no ratio). canneal_16 (v1) likewise.
- **Step 1 (laptop, minutes, no ratio):** for every in-scope key, the
  largest |lag| of a core's matched window against its measured span's
  first 100 M, at either end, from the located windows (Part B: the
  committed `partB_v2loc_rows_v1.txt`; set 2 and streamcluster_4: a new
  `matched_loc_set2_v1.txt` by the same tool).
  - **A key is rerun only if that lag exceeds 5,000,000.**
  - Below it, the windows differ by under 5% of their length; R_g5m is not
    computed and the lag is reported.
- **A key is rerun only if it passes every check of its procedure** at the
  launch (PENDING allowed only for its own ChampSim run). A key that fails
  a check is not scored, so it is not matched either (fmm and fft today).
- **Runs:** each its scored F-C rerun's config, traces and window, with
  the instrument on, into `phaseA_b3_mw_<tag>_<suffix>`; 4 at a time, nice
  19; 4-core keys first, then 8, then 16.
- **Cut-off:** a run not complete by **Sat 5 Dec 23:59 server time** is
  reported as not run (amendment 11's date).

## The reading (fixed now)

- **R_g5 stays the primary B3 measure** (owner, 2026-10-27). Every P
  prediction stays on R_g5.
- R_g5m is reported beside R_g5 for each matched key.
- A key whose R_g5 and R_g5m fall on different sides of a band edge (0.5
  or 2) is stated **placement-sensitive** in the paper, as lunc is stated
  sensitive to gem5's L2 policy.
- **fluidanimate and vips:** their R_g5m is reported with K2. If it enters
  the band, the paper says that part of the gap is placement. K2's readings
  are unchanged.
- Nothing above is chosen again after a number exists: B, the 5 M
  threshold, the 1 M clipping limit and the band.

## Tools

- C++: `sharer_directory.h/.cc` (the bins and the positions),
  `cache.cc` (one call where the R_g5 counter increments), `ooo_cpu.cc`
  (the core's position each cycle and at the phase edges, only when on),
  `main.cc` (the print).
- `scripts/matched_b3.py`: `lag` (step 1), `score` (R_g5m from a run's log,
  the LOCPT and WIN rows and the gem5 rows), `selftest`.
- Server: `scripts/mw_server.sh` / `scripts/mw_all.sh`, copies of K2's
  runner (`check` = build, guards, QM0, QM1; `chain` = the runs, then QM2).

## Build record (2026-11-17, laptop; before any server check, run or ratio)

- **C++:**
  - `sharer_directory.h/.cc`: `position_bins`, `note_position`,
    `note_phase_position`, `count_g5_rfo_at_position`,
    `print_position_bins`.
  - `cache.cc`: one call, inside the `g5_others != 0` branch of
    `dir_on_llc_request`, where R_g5's counter increments.
  - `ooo_cpu.cc`: `num_retired` each cycle at `operate`'s start. Also the
    measured span: `begin_phase` and `end_phase`, the latter overwritten
    as `end_instrs` is.
  - `main.cc`: the print, after the sync lines.
  - Every addition runs only when `COHERENCE_POSITION_BINS` is set.
  - Laptop build md5 9ced3f69.
- **Found while building (it changes the design's wording, not its
  measure):** `instr_id` cannot serve as a position. It comes from one
  static counter shared by every trace reader (`tracereader.cc:27`), so it
  interleaves the cores. Position is therefore the core's own
  `num_retired`, as the note already defines it.
- **Local sanity** (one hand-counted case; nothing scored): the exact
  suite's `pingpong` at level 2 with `COHERENCE_POSITION_BINS=1000`
  passes. CPU 0's span runs from 0 to 4,040,003, equal to its `Simulation
  complete` instructions. The bins inside the spans sum to 150, equal to
  the gem5-rule counter (150).
- **`scripts/matched_b3.py`**: `loc2`, `lag`, `score`, `selftest`
  (**10 hold, 0 fail**: parsing, QM1's sum, a window ending early, a
  window clipped by 2 M, the lag rule both ways, R_g5m and R_g5 by hand,
  a placement-sensitive case).
- **Step 1 (no ratio).**
  - `matched_b3.py loc2 simulator/results/heldout2/count/runs
    gem5_percpu_v3.txt > matched_loc_set2_v1.txt`: 48 LOCPT rows for 4
    programs x 4 threads x 3 runs, no LOCNOT.
  - `matched_b3.py lag` on it with `h2_count_rows_v1`, and on
    `partB_v2loc_rows_v1` with `partB_count_rows_v1`, gives
    `matched_lag_v1.txt`.
  - **set 2 and streamcluster_4:**

    | key | largest lag | rerun? |
    |---|---|---|
    | fluidanimate | 7.6 M (end) | yes |
    | streamcluster | 9.7 M | yes |
    | vips | 1.1 M | no: placement cannot be vips's gap |
    | oceannc | 2.0 M | no |

  - **Part B, over 5 M (21 keys):**
    - barnes_16;
    - fft_4 / 8 / 16;
    - fluidanimate_8 / 16;
    - fmm_4 / 8 / 16;
    - lunc_8 / 16;
    - raytrace_8 / 16;
    - streamcluster_8 / 16;
    - volrend_4 / 8 / 16;
    - waternsq_8 / 16.
  - **Part B, at or under 5 M:** barnes_8, bodytrack_8 / 16, ocean_8 /
    16, oceannc_8 / 16, radix_8, vips_8 / 16. radix_16 is not located
    (its gem5 run had not ended).
  - Every lag is gem5's threads behind its leading one: ends -0.1 to -68 M.
  - Of these, a key is rerun only once it passes every check (fft and fmm
    fail today) and its F-C rerun, the reference, has completed.
- **Server:** `scripts/mw_server.sh` and `scripts/mw_all.sh`, copies of
  K2's runner.
  - `check` runs the build, guards, Q0, Q0m and K0 with the instrument off
    (QM0), then QM1.
  - `go RUNSFILE` uploads the runs list (label | reference tree | workload |
    F-C config | new tree) and starts the chain. Each run is checked by
    QM2.
- **First runs list:** fluidanimate_4 alone. Its F-C rerun is
  `phaseA_b3_fc_h2_fluidanimate4`, with config `~/sync_fc/cfg/fluidanimate.json`.
  streamcluster_4 waits for its F-C rerun (Part B's chain), and the Part B
  keys wait for theirs and for their checks.

## Caveat found 2026-11-17 (the fmm diagnosis; changes no measure or rule)

- **Thread numbers by lock arrival.** Most SPLASH-3 programs number their
  threads in the order they take a lock, not at creation
  (`fmm_gem5_results_2026-11-17.md`, "Beyond fmm"). So gem5's CPU k and
  the trace's thread k need not do the same work.
- **What that means here.** A matched window places gem5's CPU k on the
  trace's thread k. In those programs it is exact only where the roles do
  equal work. How unequal they are is not measured.
- **Where it is exact.** fluidanimate and streamcluster fix their ids at
  creation, so the first runs list (fluidanimate_4) and streamcluster_4
  are exact in this respect.
- **What the paper states.** For every SPLASH-3 key's R_g5m: "thread
  numbers are assigned by lock arrival; the placement assumes roles of
  equal work".

## Amendment 1 (2026-11-18): QM1's sum, after it failed; written before any revised check was computed

- **What failed.** The server check (binary `champsim_mw_61d97f20`):
  - Q0, Q0m and K0 hold (QM0).
  - QM1's other-lines identity holds on all three spans.
  - **QM1's sum fails on 2 of 3.** Bins starting in the spans hold
    17,235 against the counter's 17,720 (barnes std force) and 1,593
    against 1,654 (canneal 4). ocean 4 holds (33 = 33).
- **Cause: the check, not the instrument.**
  - The spans are exact. Each core's MEASURED POSITIONS start at its
    `Warmup complete` instructions and end after its `Simulation complete`
    instructions; e.g. canneal CPU 1: 1,072,824 + 2,006,192 = 3,079,016.
  - QM1 counts only bins whose start lies in a span. On QM1's 2 M spans,
    the bin that straddles a span's start leaves out 1.3-4.6% of each
    core's positions (canneal CPU 3: span from 1,007,305; its bin 10
    starts at 1,000,000 and is dropped).
  - The tolerance of 0.5% cannot be met at B = 100,000 on 2 M spans. For
    R_g5m's 100 M windows this edge is at most 0.1% per edge.
  - The pingpong sanity check passed at B = 1,000.
- **The revised QM1.** It replaces the sum alone; QM1 passes only if both
  parts hold.
  - (a) **At B = 100,000 (the runs' value), a bound.** Per core:
    - lower = events in bins starting at or after the span's start;
    - upper = events in bins that overlap the span.
    - Summed over cores: lower - 10 <= counter <= upper + 10.
    - The 10 allows for events at the boundary cycle.
    - It checks that the bins and the spans account for the counter
      exactly, up to the one bin each core straddles.
  - (b) **At B = 1,000, the original test unchanged.** The same three
    spans rerun with `COHERENCE_POSITION_BINS=1000`:
    - every other line equal to the run with it off;
    - bins starting in the spans within 0.5% or 10 of the counter;
    - and (a)'s bound.
- **Also applied to QM2** (each full-length run): (a) at B = 100,000.
  Its 100 M spans need no change to the 0.5% test, but (a) is exact.
- **Nothing else changes.** Not B for the runs, not R_g5m's rule (bins
  starting in the window), not the binary.
- The failing numbers above were seen before this amendment. The revised
  test's numbers were not.

## Check record (2026-11-18, server, `champsim_mw_61d97f20`)

- **QM0 holds:** Q0, Q0m and K0 with the instrument off.
- **QM1 (amendment 1) holds on 6 of 6.** Every other line is equal on
  every span, at both B. The counts:

  | span | B | bins starting in the spans | bins overlapping them | the counter |
  |---|---|---|---|---|
  | barnes std force | 100,000 (bound) | 17,235 | 18,366 | 17,720 |
  | barnes std force | 1,000 (sum) | 17,713 | 17,721 | 17,720 |
  | ocean 4 | 100,000 (bound) | 33 | 33 | 33 |
  | ocean 4 | 1,000 (sum) | 33 | 33 | 33 |
  | canneal 4 | 100,000 (bound) | 1,593 | 1,671 | 1,654 |
  | canneal 4 | 1,000 (sum) | 1,650 | 1,654 | 1,654 |

- `go` started with `matched_runs_v1.txt` (fluidanimate_4) under the
  standing word.
