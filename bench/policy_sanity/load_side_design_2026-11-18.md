# C: load-side communication against gem5 (pre-registration, 2026-11-18)

This is the owner's decision of 2026-11-18 (PLAN § 10 item 10, C). It is
written before the counter exists and before any ChampSim load-side count
has been made.

## What is added

A records-only counter at the LLC: **a load that reaches the LLC while the
gem5-rule view lists another core as the line's only holder, and holds it
exclusive (E or M).** This is the load-side analog of R_g5's store event: a
consumer reads a line that one other core owns.

- **Where:** `CACHE::dir_on_llc_request`. The lookup the directory already
  makes for every request gains one flag, read before the request changes
  the view:

  > `g5_excl_others = g5_excl && (g5 & ~me) != 0`

- **ChampSim lines (one per cache, as the other coherence counters):**
  - `COHERENCE DIR LOAD GEM5-RULE OWNER EVENTS`: requests of type LOAD. That
    covers data loads and instruction fetches; the B3 configurations have no
    prefetchers.
  - `COHERENCE DIR OTHER-READ GEM5-RULE OWNER EVENTS`: any other read
    (TRANSLATION). Reported only. Expected near 0: page tables are per core.
- **The event log** (`COHERENCE_EVENT_LOG`) writes the flag as a 14th field
  on `L` lines only (0 or 1). Every reader takes 12 fields or more, so
  older logs and readers are unaffected.
- **Nothing simulated changes.** Every existing line of every log must be
  identical (QC0).

## gem5's side

- **`system.ruby.L2Cache_Controller.MT.L1_GETS`:** a GETS arriving at the
  shared L2 while one private cache (the per-core "L1" of MESI_Three_Level)
  holds the line exclusive.
- **Instruction fetches are included on both sides.** Read on the server
  on 2026-11-18: MESI_Three_Level's private cache issues only GETS and
  GETX/UPGRADE to the L2 (`MESI_Three_Level-L1cache.sm`; no GET_INSTR), so
  an instruction miss is a GETS. As in ChampSim's view, the first reader of
  any line is granted it exclusive.
- **Window:** the difference of the two stops, as for every B3 count.
- **Reported only:** the owner side, `L1Cache_Controller.EE.Fwd_GETS` (clean)
  and `MM.Fwd_GETS` (modified). Their window share says how many of these
  loads would be HITM on hardware (D).
- **Known differences, stated and not corrected:**
  - In a race (its PUTX in flight), gem5 may count the owner's own GETS.
  - If gem5's SE-mode page walks reach Ruby, they are GETS too. ChampSim's
    LOAD counter excludes translations.

**R_ld** = (ChampSim LOAD owner events per KI) / (gem5 MT.L1_GETS per KI),
on each span's measured window exactly as R_g5.

## Disclosed before writing

While I checked gem5 micro run times on 2026-11-18, four existing gem5
`MT.L1_GETS` values printed on the screen. All are from runs of the micro
binary as it was before Q16 changed `coherence_micro.c`:

| run | MT.L1_GETS |
|---|---|
| readers r4 | 7 |
| priv_S r4 | 6 |
| control r0 | 1 |
| readers r4 at 16 CPUs | 10 |

No ChampSim count exists. QC1b below does not use these runs.

## Checks

### QC0: every existing line unchanged

On the server, against the F-C binary (`champsim_fc_a2e88e46`), with the two
new lines removed before comparing; each new line must be present:

- Q0: canneal 4c, both regimes, levels 0 and 2, LRU and Hawkeye.
- Q0m: the F-C spans barnes std force, ocean 4c, canneal 4c.
- K0: the exact suite with both binaries; both PASS; every log equal line
  for line.

### QC1: the hand counts (micro program)

A load event per round happens, in both simulators:

| case | load events per round | why |
|---|---|---|
| readers | 1 | B's load finds A exclusive; C finds A and B shared |
| upgrade | 1 | B's load finds A exclusive |
| priv_S | 1 | C's load finds A exclusive |
| pp_lock, pp_store, pp_rmw, ctl, priv_E, llc_out, offchip | 0 | no load finds another core's exclusive copy |

- **QC1a, ChampSim, exact:**
  - The micro harness at 4 threads, level 2, 4 rounds, timed form, the 10
    cases and the control.
  - The new binary and h2's tracer, with the event logs kept.
  - On the test lines, the `L` events of type LOAD with the flag 1 must
    equal 4 × the per-round count on every case, exactly.
  - The control has 0 on its test lines.
  - Judged by `bench/ld_micro_judge.py`.
- **QC1b, gem5, within 1:**
  - gem5 on the micro, 4 CPUs, the 10 cases at ROUNDS 4 and at ROUNDS 8,
    from one fresh binary in a new directory (`~/micro_ld`).
  - For every case, (MT.L1_GETS at r8) − (at r4) must lie within 1 of 4 ×
    the per-round count.
  - The difference cancels the constant background, such as code and
    read-only globals that a second core reads once.
- **Reported, deciding nothing:** ChampSim's global LLC counter on the
  micro logs, beside the test-line count.

## The runs

- **The 14 spans of the F-C set**, each rerun with its F-C rerun's config,
  warm-up, length and traces, on the new binary, into
  `phaseA_b3_ld_<suffix>`. Same as `mw`'s chain: 4 at a time, nice 19.
- **QC2, after each run:** its log equals its reference (the scored F-C
  rerun) apart from the new lines and time stamps.
- **The runs may start once QC0 holds.** Nothing is scored unless QC1a and
  QC1b hold.
- **If QC1b fails,** gem5's MT.L1_GETS is not counting what is assumed: C is
  not scored and the difference is diagnosed.

## Predictions and reading (fixed now)

- **P-C1:** on the 8 scored spans that agree on R_g5 (barnes std window,
  barnes std force, barnes-256, ocean 2 MB, canneal 4c 2 MB, canneal 8c,
  radix, lunc), R_ld lies in [0.5, 2] on at least 6.
- **P-C2:** on the 11 scored spans, the load-side rates have Spearman ρ ≥
  0.7 with permutation p < 0.05, and ρ ≥ 0.7 one per program (`panel_stats`'
  sets and method). Then the paper may say "ChampSim orders programs by
  load-side communication as gem5 does".
- **P-C3, direction only:** R_ld < 1 for fluidanimate and for vips. Their
  store-side gap (K2) means fewer hand-offs, so consumers should also find
  fewer exclusive owners.
- **The reading:**
  - R_ld is reported beside R_g5. It changes no existing verdict, and it
    does not replace R_g5 as the primary measure.
  - If P-C1 fails, the paper says load-side communication is not validated,
    with the numbers.
  - gem5's clean / modified share is reported for D.
- **Part B's spans** may join later under an amendment written first.

## Tools

- `scripts/ld_all.sh` (laptop: upload, `check`, `go`, `status`, `pull`) and
  `scripts/ld_server.sh` (server: `mw_server.sh`'s skeleton; the micro checks
  added).
- `bench/ld_micro_judge.py`: QC1a from the kept event logs; QC1b from the
  gem5 stats.
- `scripts/ld_score.py`: R_ld per span, P-C1 to P-C3, through
  `lock_fix_score`'s parser and windows and `panel_stats`' statistics.

## Build record (2026-11-18, laptop)

- **The change:** `sharer_directory.h/.cc` (the flag), `cache_stats.h`,
  `cache.cc` (count, ROI copy, event-log field), `cache.h`,
  `plain_printer.cc`. It compiles clean (`make`, rc 0).
- **Smoke test.** This is a build check, not a result: canneal_4t, no sync
  records, 0.2 M + 0.5 M, LRU, shared, level 2, with the event log. It is
  not a scored configuration.
  - The LLC prints both lines: LOAD 756, OTHER-READ 0.
  - The event log's measured `L` lines of type LOAD with the flag 1 number
    756, equal to the counter.
  - Every `L` line has 14 fields; the other kinds keep 12 or 13.
- QC0 and QC1 run on the server.

## Tooling record (2026-11-18, before launch)

- **Server side:** `scripts/ld_server.sh` (`check`, `chain`, `status`,
  `qc2`, `stop`); laptop side: `scripts/ld_all.sh`.
- **QC1b's gem5 command line** is `micro_server.sh`'s, at 4 CPUs. One static
  binary is built in `~/ld/g5micro`, and its runs are in
  `~/ld/g5micro/gem5/<case>_r{4,8}`.
- **QC1a** runs the micro harness from `~/ld_build` with h2's tracer
  (02ff8f48) and the frozen new binary. Event logs are kept.
- **Judge:** `bench/ld_micro_judge.py`; its self-test holds 4 of 4 on
  synthetic inputs.
- **Runs list:** `ld_runs_v1.txt`, 14 lines. A read-only check of each
  reference on the server: complete, `SYNC LOCK WORD: request`, config
  present.
- **Operational, decided before launch:** 7 runs at a time (two waves), not
  4, because the server is at load about 360. Nothing in the reading depends
  on it.

## Scorer (2026-11-18, before any rerun exists and before any ratio was read)

- `scripts/ld_score.py` (`selftest`, `rows`, `score`).
- **Its gates:**
  - the five markers (Q0, Q0m, K0, QC1a, QC1b) pulled to `simulator/results/ld/`;
  - each rerun's QC2, recomputed on the laptop against its F-C reference (new lines removed, `(Simulation time: ...)` masked);
  - the reference qualifying by `lock_fix_score.qualify`;
  - gem5's window instructions from `stats.txt` equal to `gem5_b3_rows_v6`.
- **R_ld:** gem5's `MT.L1_GETS` is read from each stop's `stats.txt`, the long stop minus the short.
- **P-C2:** `panel_stats.summary` on the per-KI rates, with the 11 scored spans and one span per program.
- **Self-test:** 17 of 17.
- **Checked on all 14 spans before any ChampSim count exists:** the gem5 reader finds `MT.L1_GETS` > 0, and its window instructions equal the rows. No gem5 load-side value was printed.
