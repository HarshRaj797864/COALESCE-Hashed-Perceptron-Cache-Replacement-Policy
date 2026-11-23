# D: a hardware direction check on an Intel i7 (pre-registration, part 1, 2026-11-18)

This is the owner's decision of 2026-11-18 (PLAN § 10 item 10, D). It lifts the
no-hardware rule for this check only.

- **Where:** a student's Intel i7 machine, with sudo, from about 22 Nov.
- **How it is read:** by ranking and order of magnitude only, never a band.
- **When this was written:** before the machine's model is known, and before
  any hardware count exists.
- **Part 2,** an amendment, will name the events. It is written once the model
  is known (`lscpu`), and before QH runs.

## The question

Do real cores order the programs by store-time sharing as ChampSim and gem5
do, and within an order of magnitude of them?

No published simulator-against-HITM comparison reports an error level
(`reports/Validating a multithreaded cache simulator.md`, "Hardware counters
can anchor direction, never a band"). So only direction is asked.

## What is counted, and what cannot be

- **The quantity:** ChampSim's store-time event is a store miss (an RFO) that
  finds the line held by another core.
- **Its hardware counterpart:** the offcore-response (OCR) matrix, per thread,
  user mode, counting only.
  - **The event:** the demand RFO that hits the L3 and whose snoop finds the
    line *modified* in another core (HITM).
  - **Its clean twin:** the snoop found a clean copy (HIT_NO_FWD, or the
    model's name for it).
  - **H_hw** = their sum per thousand user-mode instructions.
- **Loads, for C (reported only):** the retired-load event "L3 hit, cross-core
  snoop, modified" (`MEM_LOAD_L3_HIT_RETIRED.XSNP_HITM`, or `XSNP_FWD` on
  newer cores).
- **Not counted, stated in the paper:**
  - **Upgrades:** a store to a shared copy. There is no per-thread counter.
    The nearest is privileged and socket-wide.
  - **Prefetch RFOs:** DEMAND_RFO excludes them, and ChampSim's B3 runs have no
    prefetcher.
- **Rule for choosing an event (part 2 applies it):**
  - The event's description in Intel's perfmon file for the model must read
    "demand RFO … L3 hit … snoop … modified / HITM, other core".
  - Its encoding comes from `perf list` on the machine.
  - Nothing is chosen by its values. QH below decides whether it is used at all.

## The machine (recorded first, before any count)

- **What is recorded:** `lscpu`; `/proc/cpuinfo`'s model, stepping and
  microcode; the kernel; `perf --version`; `perf list` (saved whole);
  `cat /proc/sys/kernel/perf_event_paranoid`; SMT state; cache sizes; the
  governor; the C library version.
- **Hybrid parts (Alder Lake and later):**
  - Only P-cores are used.
  - Events are requested on the `cpu_core` PMU.
- **Threads:** 4 workers, on 4 distinct physical cores, with each core's SMT
  sibling left idle. `taskset -c` uses one logical CPU per physical core.
  Under SMT, at-retirement events can be corrupted (HSM30), and siblings share
  L1 and L2.
- **Load:** the machine is otherwise idle. The governor is set to performance
  where allowed. It is recorded, not required.

## QH: the micro program, before any program is counted

- **The program:** `bench/coherence_micro.c`, built natively as for gem5, with
  `-DBARRIER_STEPS`. A barrier orders each step, whatever the timing.
- **Only the cases whose counts do not depend on cache sizes are used.** The
  FLUSH and SWEEP cases (priv_E, priv_S, llc_out, offchip) assume the
  simulators' small caches.

| case | RFO finding M in another core, per round | RFO finding a clean copy, per round | why |
|---|---|---|---|
| pp_store | 3 | 0 | A, B, A, B store to X_j: the first store finds no holder; the next three find the other core's M copy |
| pp_lock | 3 | 0 | the same, with locked increments |
| pp_rmw | 3 | 0 | the same, with plain read-modify-writes |
| ctl | 0 | 1 | A loads (E); B stores and finds A's clean copy |
| readers | 0 | 1 | A, B, C load (shared); D's store finds clean copies |

- **Measuring the barrier's own traffic:** each case runs at ROUNDS 20,000 and
  40,000, 5 times each.
- **The per-round count:** (median at 40,000 − median at 20,000) / 20,000, minus
  the same slope of a barrier-only run with the same number of steps a round.
  - **This needs two new cases:** `none4` (4 steps, no operation; the control
    for pp_store, pp_lock, pp_rmw and readers) and `none3` (3 steps; for ctl).
  - They are added to `coherence_micro.c` under new names. Every existing
    case's step table and code path stays the same, which is checked as in
    "Tools".
- **QH holds if all three hold:**
  - pp_store, pp_lock and pp_rmw each read 3 ± 1 HITM RFOs a round;
  - ctl and readers read 0 ± 1 HITM RFOs a round;
  - the contrast, pp_store's HITM slope minus readers' (both 4 steps; was
    ctl's, corrected 2026-11-23), is at least 2, and ctl reads 1 ± 0.5
    clean-snoop RFOs a round.
  - The contrast does not depend on a shift in the barrier's own traffic
    that the case's operations may cause.
- **If QH fails:**
  - The event does not count what is assumed. No program is counted with it.
  - The paper states the hardware check as attempted, with QH's numbers.
  - A second event may be tried only under a new amendment, written before it
    runs.

## The programs

- **One configuration per program, the 4-thread inputs of the scored spans:**
  - ocean (contiguous, 514 grid, as gem5);
  - canneal (the scored input);
  - radix (the held-out input);
  - barnes (standard, 10-body leaves);
  - LU non-contiguous (`-n1024 -p4`, as scored);
  - fluidanimate and vips (set 2's inputs).
- **Not included:**
  - barnes-256 is not the standard program.
  - streamcluster, bodytrack and fmm are not on the final binary's panel.
  - canneal at 8 cores needs 8 physical P-cores. It is added only if the
    machine has them.
- **Builds:** the binaries are built from the same sources and flags as the
  traced (dynamic) ones, and the same `-DMAX_BODIES_PER_LEAF` and constants
  are checked (`check_barnes_build.sh`'s idea, applied locally).
- **What is counted: the parallel phase, user mode.**
  - An `LD_PRELOAD` shim enables the counters (`perf stat --control fifo:...
    --delay=-1`) when thread 0 returns from its last `pthread_create`. That is
    the anchor the traces were cut at (`sync_anchor.py`).
  - Counting runs to the program's end.
  - **This differs from the simulators' 50-150 M window,** and the difference
    is stated. The comparison is per KI, across programs, by rank.
- **Repeats:** 10 runs each, in an order shuffled once with a fixed seed. The
  highest and lowest are dropped, and the median and range are reported.

## Readings (fixed now)

**Rates:**

- H_hw = (HITM + clean-snoop demand RFOs) per KI user instructions.
- C_cs = ChampSim's gem5-rule store-time events per KI (the F-C rows,
  `panel_rows_v1`, one span per program: barnes force for barnes, canneal
  4c).
- G_g5 = gem5's SS + MT L1_GETX per KI.

**Predictions:**

- **P-D1 (rank):** Spearman ρ(H_hw, C_cs) ≥ 0.7 over the 7 programs, with a
  permutation p < 0.05 (`panel_stats.perm_p`).
- **P-D2 (order of magnitude):** H_hw / C_cs lies in [0.1, 10] on at least 6
  of the 7 programs.
- **Reported:**
  - ρ(H_hw, G_g5);
  - each program's H_hw / C_cs and H_hw / G_g5;
  - the HITM share of H_hw;
  - the load-side XSNP rate against C's R_ld rows, if C is scored.

**What the paper says:**

- If P-D1 holds: "on an Intel <model>, real cores order the programs by
  store-time sharing as ChampSim does (ρ …)", with the window difference and
  the missing upgrades stated.
- If it fails: the numbers, and no claim.
- **Never:** a band, an error percentage, or "validated against hardware".

## Tools (to be written before 22 Nov; nothing runs before part 2)

- `bench/coherence_micro.c`: the `none4` and `none3` cases (new names only).
  The other cases are checked two ways:
  - every existing case's step table, printed by a test build, is equal
    before and after;
  - the disassembly of `worker`, `chase` and `reads` is equal before and
    after.
- `scripts/hw_anchor_shim.c`: the `LD_PRELOAD` shim. It counts
  `pthread_create` returns on thread 0 and writes `enable` to perf's control
  FIFO after the N-th, with N = the program's worker count.
- `scripts/hw_run.sh`: records the machine, runs QH, then the programs if QH
  holds. It writes one directory of plain-text results, which are brought
  back as they are.
- `scripts/hw_score.py`: QH, then P-D1 and P-D2. Written and self-tested
  before any hardware count is read.

## Needed from the owner

- The i7's exact model (`lscpu` output).
- Whether it can be left idle for about a day.
- Sudo, for `perf_event_paranoid` ≤ 0 (offcore events need ≤ 0, or
  CAP_PERFMON / CAP_SYS_ADMIN).
- Its owner's consent to run benchmark programs on it.

## Corrections before any code or count (2026-11-18, same sitting)

- **One `none` case became `none4` and `none3`.** A barrier-only control must
  have the case's number of steps: under `BARRIER_STEPS` each step ends at a
  barrier, and the barrier makes HITMs of its own.
- **QH's tolerances were widened from ± 0.5 to ± 1 HITM a round, and a
  contrast was added (pp_store − ctl ≥ 2).** A barrier's own HITMs may
  shift a little when the case's operations change which thread arrives
  last.
- **Both changes were made before any code was written or any count
  existed.**

## Build record, part 1 (2026-11-18)

- **The two new cases were written and checked on the laptop:** two `else if`
  lines in `schedule()`, before `else return -1`.
  - **Step tables:** a test build printed `schedule()`'s table for the 11
    existing case names and an unknown one. Before and after are equal (12 of
    12).
  - **Code:** `worker` and `main` are equal before and after, once addresses
    are masked, under `-O2`, `-O2 -DBARRIER_STEPS`, `-O2 -DBARRIER_STEPS
    -static` and `-O2 -DM5OPS -static`.
    - Unmasked, `worker` differs only in addresses, because `schedule()` grew.
  - `chase` and `reads` are inlined.
- **The change is held back, not committed.** `scripts/ld_all.sh go` refuses
  while the laptop's `bench/coherence_micro.c` differs from the copy C
  uploaded. It is committed once C's runs have started (a 15-line patch).

## Build record, part 1b (2026-11-23; before any hardware count, before part 2)

- **The binaries are the traced ones, not rebuilt.** `scripts/hw_bundle.sh
  pull` copies the seven binaries the traces were recorded from, and their
  inputs, from the server: 11 files, each equal to the server's md5. This is
  closer to "the same code as traced" than a rebuild.
- **The anchor N is thread 0's create count in the traced run** (the
  tracers' "thread 0 calls: … create N"): 3 for the SPLASH-3 programs at
  `-p4`, 4 for canneal and fluidanimate, 6 for vips.
  - The shim counts every `pthread_create` of the process, not only thread
    0's. It now prints `HW_ANCHOR total creates K` at exit.
  - `hw_score.py` rejects a run whose K differs from its N, because the
    anchor must be the last create. Self-test 19 of 19.
  - **On the laptop:** ocean, canneal, barnes, radix and LU-NC each enabled
    after create N, with total creates = N.
- **The libraries, fixed now.** fluidanimate and vips need GLIBC 2.38
  (GLIBCXX 3.4.32), so they do not start on a C library at 2.35 (the
  laptop's).
  - **Every program therefore runs on the libraries it was traced with:**
    the server's loader, libc, libm, libstdc++, libgcc_s, libdl and
    libpthread, in the bundle's `libs/`.
  - `hw_run.sh` invokes them through that loader (`libs/ld-linux-x86-64.so.2
    --library-path libs`) and records the loader line in `progs/LOADER`.
  - The shim is linked `--as-needed`.
- **Stdin:** barnes reads its input from stdin. PROGS has a stdin field,
  and directories are resolved against the bundle.
- **The `none4` / `none3` cases** are inserted by `hw_bundle.sh make` into
  the bundle's copy, after the `s16` line, exactly as checked in part 1.
  This holds while C's runs need the tree's file unchanged.
- **Rehearsed on the laptop with a stand-in perf** (it answers the control
  FIFO and writes counts from planted rates), using the laptop's libraries
  in `libs/`:
  - `progs` ran 70 runs; loader, preload, anchors and stdin all work;
  - `hw_score.py progs` recovers the planted rates exactly;
  - without fluidanimate and vips it gives no verdict, as written.
  - Not yet run with the server's libraries: fluidanimate and vips, and
    vips under an explicitly invoked loader.

## Correction 2 (2026-11-23; found in the QH rehearsal, before any hardware count)

- **The contrast now compares pp_store with readers, not with ctl.**
  - ctl has 3 steps a round and pp_store 4. Their raw slopes therefore
    differ by one barrier step's own HITMs, whatever the event counts.
  - The rehearsal planted 6 barrier HITMs a step and 3 for the operations.
    pp_store − ctl read 9, and would pass on barrier traffic alone.
  - readers has 4 steps, like pp_store, and no HITM of its own. With the
    same planted counts, pp_store − readers reads 3.
- **The QH rehearsal on the unpacked bundle (stand-in perf):**
  - 70 of 70 runs of the real micro program, built `-DBARRIER_STEPS` with
    `none4` / `none3`;
  - the judge recovers the planted per-round counts exactly, and QH
    holds;
  - self-test 20 of 20, including a case in which one barrier step's HITMs
    alone would have passed the old contrast.

## Correction 3, and part 2 staged (2026-11-23; before the model is known, before any count)

- **What Intel's event files say:** Intel's perfmon files, P-core files
  only, read 2026-11-23. The extract, with each source file's md5, is
  `hw_perfmon_candidates_v1.txt`.
  - **The HITM event** (demand RFO, L3 hit, snoop HITM in another core) is
    documented on every client i7 generation, Haswell to Lunar Lake.
  - **The clean twin** (demand RFO, L3 hit, snoop hit with no forward) is
    documented only for Haswell, Broadwell, Skylake to Comet Lake, Ice Lake
    and Rocket Lake.
  - It is **not** documented for Tiger Lake, Alder / Raptor Lake, Meteor
    Lake, Arrow Lake or Lunar Lake. The rule allows only documented events,
    so no encoding is built by analogy.
- **The rule for a model without the twin (HITM-only), fixed now:**
  - **QH** drops the clean-snoop condition (ctl 1 ± 0.5). The HITM
    conditions and the contrast stay as written.
  - **H_hw** is the HITM rate alone. P-D1 and P-D2 are unchanged, against
    C_cs.
  - **Reported beside them:** ρ and the ratios of HITM RFOs against gem5's
    MT.L1_GETX (a store finding another core owning the line). These come
    from `hw_gem5_mt_rows_v1.txt`, read as the panel reads gem5
    (`hw_score.py g5mt`). Its MT + SS equals the panel's gem5 rate.
  - In gem5, MT is 97-100% of the store-time events on these spans. The
    paper states that HITM leaves out clean holders.
- **Part 2, once `lscpu` gives family 6 and the model number:**
  - Look up the model's row in the extract's model-ID list.
  - Take the HITM event, and the twin where documented. The load event is
    `XSNP_HITM`, or `XSNP_FWD` where that file names the HITM response so.
  - Confirm each name in the machine's `perf list` (on hybrid parts, under
    `cpu_core`), and write EVENTS.
  - **If a name is missing from `perf list`,** that event is not used. If
    the HITM event is missing, D stops, and the paper says the check could
    not be run on that model.
- **Scorer:** `hw_score.py` judges HITM-only QH and H_hw; self-test 24 of 24.
