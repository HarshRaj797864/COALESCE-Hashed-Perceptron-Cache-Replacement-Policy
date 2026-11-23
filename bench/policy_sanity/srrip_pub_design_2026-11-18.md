# The published SRRIP row (pre-registration, 2026-11-18)

This is the owner's decision of 2026-11-18 (PLAN § 10 item 10): "add the
published row". Background is in `srrip_insertion_diagnosis_2026-11-11.md`.
Upstream ChampSim's `srrip` never runs its insertion: `replacement_cache_fill`
is empty, so every filled line keeps the victim's RRPV, 3. The published
policy inserts at 2 (Jaleel et al., ISCA 2010, SRRIP-HP with M = 2).

Written before the module exists and before any run of it.

## The module: `replacement/srrip_pub`

- **A copy of upstream's `srrip`** (set helper, victim search, hit
  promotion to 0), with one change: `replacement_cache_fill` calls
  `update(way, false)`, which leaves the filled line at RRPV 2.
- **For QS1 only, it counts its fills** and the RRPV each is left at,
  printed once by `replacement_final_stats` as `SRRIP_PUB FILLS: <n> LEFT AT
  RRPV 2: <k>`. This matches the 2026-11-11 probe's count.
- **Upstream's `srrip` is not touched.** It stays the baseline of record:
  "as ChampSim ships it".
- `make_config.py` accepts `srrip_pub`.

## The binary and its checks

- **Built from main in its own tree** (`~/sp_build`), with the three policy
  guards, and frozen as `bin/champsim_sp_<md5>`.
- **QS0: the new binary reproduces step 5's binary with upstream's SRRIP.**
  - Three step-5 SRRIP configs (canneal 4c fixed shared, ocean 4c 2 MB a
    core shared, barnes std 4c fixed private), each with its traces, at 1 M
    + 2 M.
  - Each runs on the new binary and on `champsim_g6_1e3060c1`.
  - Every line must be equal once the lines added since g6 are removed from
    the new log: `MUTEX WAITED ACQUIRES`, `LOCK-WORD REQUESTS`, `GEM5-RULE
    OWNER EVENTS`.
  - The g6 log holds none of those lines.
- **QS1, every srrip_pub run:**
  - complete;
  - one `SRRIP_PUB FILLS` line with k = n > 0;
  - unexplained view-order violations 0.

## The runs

- **What runs:** the 19 step-5 SRRIP jobs (`~/sync_pol/JOBS`, policy
  `srrip`).
- **Each run:** its step-5 config with `LLC.replacement` changed from
  `srrip` to `srrip_pub` (nothing else; checked by script), its warm-up,
  length and traces.
- **Output:** `phaseA_b3_sp_<suffix>/regime_<r>/<wl>_<n>core/srrip_pub/run.log`.
- **Scheduling:** 7 at a time, nice 19, 16 cores first.

## What is reported (fixed now)

- **Step 5's verdicts (P11-P14) and rankings of record are unchanged.** They
  use ChampSim's SRRIP. The published row is reported beside them.
- **For each of the 19 configurations:**
  - max cycles of srrip_pub, srrip and LRU;
  - srrip_pub against srrip and against LRU, in %;
  - LLC misses.
- **Sensitivity, reported:** each tree's ranking with srrip_pub in srrip's
  place, and Kendall τ against the ranking of record. The same for P11's
  shared-against-private τ. Then a sentence on whether any verdict would
  change.
- **Expectations from the probe** (20 M + 50 M; reported, not gating):
  - ocean 4c, 2 MB a core, shared: srrip_pub within 5% of LRU.
  - canneal 4c: srrip_pub within 2% of srrip.
- **The reference is step 5 of record, which is p2 (g6) under amendment 4.**
  If H7's 171 runs all complete and p3 becomes the record, the row is
  reported against p2. The difference between p2 and p3 is stated.

## Tools

- `scripts/sp_all.sh` (laptop: `check`, `go`, `status`, `pull`) and
  `scripts/sp_server.sh` (the build, QS0, then the chain with QS1).
- Scored by `scripts/sp_score.py` from the pulled logs and step 5's rows.

## Build record (2026-11-18, laptop, before any server run)

- **The module:** `replacement/srrip_pub/srrip_pub.{h,cc}`. It is upstream's
  `srrip.cc` with the types renamed, plus the fill hook and the
  `SRRIP_PUB FILLS` line. A `diff` against upstream's file, with the names
  mapped back, shows only those lines. `make_config.py` lists `srrip_pub`.
- **Checks:** it compiles (rc 0), and the three policy guards pass.
- **Smoke test.** This is a build check, not a result: canneal_4t, 0.2 M +
  0.5 M, shared, level 2. Of 17,371 fills, all were left at RRPV 2.
- **The runner's pieces, tested on synthetic inputs:**
  - the config rewrite changes only `LLC.replacement`, and refuses a
    config that is not srrip;
  - QS1 holds on the smoke log, and fails when the two counts differ.
- **The g6 binary's md5 was read on the server:**
  `1e3060c1760b4b3b18e5728a9dfb75ed`.
- **The lines printed since g6, read in the code:**
  - always printed, removed by QS0: `MUTEX WAITED ACQUIRES`, `GEM5-RULE
    OWNER EVENTS`;
  - printed only when a setting or variable is on, and step 5's configs set
    none of them: `RMW LOADS AS RFO: off`, `SYNC LOCK WORD`, `LOCK-WORD
    REQUESTS`, `SYNC LEAD LIMIT`, `B3 POSITION BINS`.

## Scorer (2026-11-18, before any srrip_pub run exists and before any of its numbers was read)

- **`scripts/sp_score.py`** (`selftest`, `parser`, `score`): self-test 18 of 18.
- **The parser:** it reads a log as `run_phase_a.sh`'s rows do: max cycles, instructions, and the Region of Interest's LLC TOTAL access and hit.
  - It reproduces the committed `phasea_rows_v30` rows of step 5's 19 srrip logs exactly (19 of 19).
  - It is checked again before every score.
- **Gates:**
  - QS0 recorded as passed.
  - QS1 recomputed per run: complete; one `SRRIP_PUB FILLS` line, with n > 0 and every fill at RRPV 2; unexplained 0.
  - No trace wrap.
  - Warm-up, length, CPU count and traces equal to the reference's.
  - The pulled config's `LLC.replacement` reads `srrip_pub`.
- **Sensitivity:** step 5's own `order`, `tau` and `verdicts`, on the rows with srrip's numbers replaced by srrip_pub's.
  - barnes std is not ranked, as step 5 does not rank it.
  - 15 (tree, regime) rankings, plus P11's four τ and the P11-P14 verdicts.
