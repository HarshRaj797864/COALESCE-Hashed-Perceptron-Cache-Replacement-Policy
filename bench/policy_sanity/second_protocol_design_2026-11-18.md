# E: a second gem5 protocol, MESI_Two_Level (pre-registration, 2026-11-18)

This is the owner's decision of 2026-11-18 (PLAN § 10 item 10, E). It is
written before the gem5 build exists and before any MESI_Two_Level count of
these programs exists.

## The question

Every gem5 reference so far is MESI_Three_Level. That protocol has an open
ordering bug: gem5 #1597 and #2816, the FIFO panic, which we turn off
(`setup_gem5.sh patch-fifo`). H1 found the effect very small: one overtake
in 9.6 M messages, in barnes std's window.

The question here: **does R_g5's verdict depend on that one protocol?**
MESI_Two_Level is gem5's most-used Ruby MESI protocol, and its FIFO buffers
are stock. It runs with no patch.

## Why the gem5-rule view applies unchanged

This was read on the server on 2026-11-18, in v25.1.0.1's
`src/mem/ruby/protocol`.

- **The shared L2 controller is the same file**, `MESI_Two_Level-L2cache.sm`,
  in both protocols. R_g5's gem5 terms (`L2Cache_Controller.SS.L1_GETX` +
  `MT.L1_GETX`) and the upgrades (`SS.L1_UPGRADE`) therefore have the same
  meaning.
- **The private cache forgets holders by the same rule:**

  | event | MESI_Two_Level-L1cache.sm | MESI_Three_Level-L1cache.sm |
  |---|---|---|
  | an S line is replaced | `transition(S, L1_Replacement, I)`: silent, the L2 keeps the reader listed | `transition(SS, L1_Replacement, I)`: silent |
  | an E or M line is replaced | `transition({E, M}, L1_Replacement, M_I)`: PUTX, the L2 forgets the owner | `transition({EE, MM}, L1_Replacement, M_I)`: PUTX |

  That is the rule ChampSim's gem5-rule view models (`micro_results_2026-10-18.md`:
  priv_E 0, priv_S 4).

## The configuration

- **The one difference intended is the protocol.** MESI_Two_Level has one
  private level, where MESI_Three_Level has two.
- **The private capacity is matched.** The private L1 takes ChampSim's L2C
  capacity and ways for data, and its L1I for instructions:

  | | ChampSim | MESI_Three_Level runs | MESI_Two_Level (E) |
  |---|---|---|---|
  | data | L1D 32 kB 8-way + L2C 512 kB 8-way | L0D 32 kB + L1 512 kB 8-way | **L1D 512 kB 8-way** |
  | instructions | L1I 32 kB 8-way | L0I 32 kB 8-way | L1I 32 kB 8-way |
  | shared | LLC 2 MB 16-way | L2 2 MB 16-way, 1 bank | L2 2 MB 16-way, 1 bank |

  - **Why the private capacity:** when a holder is forgotten depends on when
    its private caches drop the line, so the capacity decides it.
  - **The runner:** `run_gem5_splash.sh` gains a new setting,
    `TWO_LEVEL_L1=l2c`. It is off by default, so no other launch changes.
    MESI_Three_Level never reads it.
- **Everything else is each original run's:**
  - program, input and binary;
  - CPU (TimingSimpleCPU) and CPU count;
  - memory, stop variable and both stops;
  - Ruby randomization off;
  - each program's own settings: `OCEAN_GRID=514` for ocean; `BINS` for
    radix and fluidanimate.
- **The gem5 build:**
  - **Where:** a new tree, `~/gem5_two`, a local clone of `~/gem5` at
    v25.1.0.1. Clean: the FIFO patch is not in git.
  - **Configuration:** `scons defconfig build/X86 build_opts/X86`, which
    must read `PROTOCOL="MESI_Two_Level"` with exactly one protocol on (else
    `setconfig` as `setup_gem5.sh rebuild`).
  - **Build:** `gem5.opt` at nice 19.
  - **Check:** the binary must embed `MESI_Two_Level_L1Cache_Controller`
    and no `MESI_Three_Level` controller.
  - `~/gem5` is not touched.

## The runs

- **What runs:** the four programs at both of their B3 stops, 8 runs:

  | program | original runs (`~/gem5_b3/...`) | stops |
  |---|---|---|
  | ocean 4c, 2 MB | `l2_2MB_mi{150,50}M/ocean_4c` | 150 M, 50 M (MAXINSTS) |
  | canneal 4c, 2 MB | `canneal/l2_2MB_mi{150,50}M/canneal_4c` | 150 M, 50 M (WORKER_MAXINSTS) |
  | radix | `heldout/radix/l2_2MB_mi{930,830}M/radix_4c` | 930 M, 830 M (WORKER_MAXINSTS) |
  | fluidanimate | `heldout2/fluidanimate/l2_2MB_mi{150,50}M/fluidanimate_4c` | 150 M, 50 M (WORKER_MAXINSTS) |

- **Scheduling:** 8 at a time (all eight), nice 19.
- **Time limit:** 168 h each.
- **Output:** `~/gem5_b3/e2/<program>/l2_2MB_mi<stop>M/<tag>`; state in
  `~/e2`.
- **QL0, each run's configuration (`config.ini`):**
  - Every section outside `system.ruby` must equal the original's. Lines
    that name a `system.ruby` port are the only exception.
  - The new run has `system.ruby.l1_cntrl<N>.L1Dcache` and `.L1Icache` and
    no `l0_cntrl`.
  - The new L1D's size and ways must equal the original's
    `l1_cntrl<N>.cache`; the new L1I's must equal the original's L0 icache.
  - The L2's size, ways and replacement policy must equal the original's.
  - Randomization must be false.
  - **A failure ends the run and stops further launches.**
- **QL1, the micro program, is the rule check.**
  - **What runs:** the static micro binary built as C's QC1b builds it, on
    the 10 cases at ROUNDS 4 and 8.
  - **Configuration:** 4 CPUs, private L1D 8 kB 8-way and L1I 32 kB, L2
    256 kB 16-way. This is the capacity of the MESI_Three_Level micro runs'
    L1.
  - **What is compared:** for each case, Δ = r8 − r4 of G (SS + MT
    L1_GETX) and of U (SS.L1_UPGRADE).
  - **Holds if,** on every case, Δ equals the MESI_Three_Level Δ of C's
    QC1b runs (`~/ld/g5micro`, the same micro source) within 1, for G and
    for U.
  - **The two cases that test the rule are named:** priv_E (Δ G about 0)
    and priv_S (Δ G about 4).
  - **Reported only:** the hand counts beside each Δ.
- **QEND:** each run ended at its stop, with one statistics dump.
- **Scoring order:** the eight runs may start once the build passes. No
  ratio is read until QL1 holds and both stops of a program have ended.

## What is computed (fixed now)

- **gem5 (MESI_Two_Level) per KI** in each program's window (short stop to
  long stop), exactly as the B3 gem5 rows: G, U, and L2 demand accesses.
- **R_g5^two** = ChampSim's scored F-C rate (unchanged; `lock_fix_score`'s
  spans: ocean 2 MB, canneal 4c, radix, fluidanimate) ÷ gem5 MESI_Two_Level's.
- Beside it: R_g5 against MESI_Three_Level (of record), U and traffic
  likewise.
- **gem5 against gem5:** G_two ÷ G_three per KI, per program. This is the
  reference's own sensitivity to the protocol.

## Predictions and reading

- **P-E1:** R_g5^two lies in [0.5, 2] for ocean, canneal 4c and radix (3 of
  3).
- **P-E2:** R_g5^two < 0.5 for fluidanimate. Its gap is ChampSim's (K2: a
  line passes back and forth within a burst in gem5), not
  MESI_Three_Level's.
- **P-E3, reported with H2's spread:** G_two ÷ G_three lies in [0.5, 2] on
  all four.
- **The reading:**
  - If P-E1 holds, the paper says R_g5's verdicts on these three programs
    hold against a second gem5 protocol that needs no FIFO patch.
  - If P-E1 fails on a program, that program's agreement is stated as
    sensitive to the reference protocol, with both numbers. Nothing is
    re-tuned.
  - P-E2 failing (fluidanimate in the band under MESI_Two_Level) would put
    the fluidanimate gap on MESI_Three_Level. That case is reported and
    diagnosed, never scored as an agreement after the fact.
  - The reference of record stays MESI_Three_Level, whose hierarchy matches
    ChampSim's level for level.

## Tools

- `scripts/e2_all.sh` (laptop: `check`, `go`, `status`, `pull`) and
  `scripts/e2_server.sh` (server: build, guards, QL1, the chain with QL0 and
  QEND).
- `scripts/e2_check.py`: QL0, QL1, and `selftest`. It imports
  `hset_check.py`'s config.ini reader and QEND.
- Scored by `scripts/e2_score.py`, written before any ratio is read: the B3
  gem5 rows and the F-C rows.

## Tooling record (2026-11-18, before launch)

- **`run_gem5_splash.sh`** gains `TWO_LEVEL_L1=l2c`, read only under
  MESI_Two_Level. Every existing launch is unchanged.
- **`scripts/e2_check.py`:**
  - The self-test holds 10 of 10 on synthetic config.ini and stats files.
    It covers QL0 passing; a missing tree mapping, L1D 32 kB, another stop,
    randomization on, another L2 policy and a MESI_Three_Level run each
    failing; and QL1 holding, failing on priv_S and failing on a missing
    run.
  - **A bug was found while writing it and fixed before any use.** The
    `~/gem5` → `~/gem5_two` path mapping was a plain string replace, which
    also rewrote `~/gem5_b3/...` output paths. It now matches only the whole
    path. The self-test has a case for it, and the old mapping fails that
    case.
- **`scripts/e2_server.sh` (server: `guards`, `go`, `status`, `list`,
  `stop [runs]`) and `scripts/e2_all.sh` (laptop).**
  - The driver builds, then starts QL1's micro runs. QL1 waits for C's micro
    binary and is judged once C's MESI_Three_Level micro runs have ended.
  - Then the 8 runs: at most 8 at once, QL0 on each, QEND as each ends.
- **Read on the server, 2026-11-18:**
  - `~/gem5` is at v25.1.0.1 (`c8222cc6`).
  - `build_opts/X86` reads `PROTOCOL="MESI_Two_Level"` with only
    `RUBY_PROTOCOL_MESI_Two_Level=y`.
  - scons is in `~/.gem5-venv`.
  - 55 GB of disk free; 121 GB of memory available.
- **No stand-in rehearsal** (the owner asked for as little laptop load as
  possible). The protection is the server's guards, and QL0 on every run:
  a failure ends that run and stops all launching.

## Scorer (2026-11-18, before any MESI_Two_Level run of the four programs has ended)

- **`scripts/e2_score.py`** (`selftest`, `rows`, `score`): self-test 14 of 14.
- **Gates:**
  - QL1: `QL1_PASSED` pulled, then rejudged on the laptop with `e2_check.ql1` against C's MESI_Three_Level micro runs (`simulator/results/ld/g5micro/gem5`).
  - Per program: both stops `ENDED-AT-STOP`, both `ql0.txt` ending in `QL0 PASS`.
  - ChampSim's and MESI_Three_Level's per-KI rates, recomputed, equal the scored `panel_rows_v1` row to 6 decimals. On the existing files this holds on 4 of 4.
    - A first tolerance on the ratio itself (1e-5 relative) failed on fluidanimate at 1.12e-5. That is the panel file's 6-decimal rounding of a 0.045 rate, so the check now compares the rates at that rounding.
- **Computation:**
  - The MESI_Two_Level window is read by `b3_score.gem5_rows` and `b3_score.window`, exactly as every earlier B3 gem5 row.
  - The ratios come from `lock_fix_score.ratios` with the F-C rerun's counts.
