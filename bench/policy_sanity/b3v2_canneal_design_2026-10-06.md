# B3 v2 on canneal — the comparison, pre-registered

**2026-10-06.** Written and committed **before** any canneal run exists
in either simulator, on the sharer-directory binary or under gem5. The
counter, configs and criteria are those of `b3v2_design_2026-10-05.md`. The
only changes are the ones canneal forces, stated below with their reasons.

## Why canneal

Ocean agreed (`b3v2_ocean4_2026-10-06.md`: R_b 1.26 at 2 MB, 1.35 at 8 MB).
But ocean shares little: 23× less than canneal. Canneal carries the
cross-regime result (`a5_crossregime_2026-10-01.md`). A tool validated only on
a low-sharing workload has not been validated where it matters.

## What runs

**gem5 v25.1.0.1, MESI_Three_Level.** Configured as for ocean:
- L0 32 kB, L1 512 kB, L2 2 MB or 8 MB 16-way;
- TimingSimpleCPU;
- `randomization=false`, patch-fifo.

The binary and the run:
- **The binary** is a static canneal built from the traced code
  (`scripts/build_canneal_static.sh`):
  - the PARSEC build directory's binary is byte-identical to the traced one;
  - all five rebuilt objects have machine code identical to that build's;
  - the objects are linked with `-static`;
  - md5 `f675a03ae694b7341e92be15a2e72999`.
- **Arguments:** the traces' own, `4 15000 2000 100000.nets 128`.
- **5 CPUs.** cpu0 runs the main thread, which loads the netlist, spawns
  the 4 workers and joins them. The `canneal_4t` traces skip it (thread 0).
  cpu1–cpu4 run the workers, i.e. traces `canneal1..4`.
- **Stops:** the run stops when the first worker reaches 50 M, 100 M and
  150 M instructions: `max_insts_any_thread` on cpu1–cpu4 only, set through
  `--param`. Six runs: {2 MB, 8 MB} × {50 M, 100 M, 150 M}.

**ChampSim:** LRU, canneal 4c (`canneal_4t/canneal1..4`), both regimes, on
`bin/champsim` (the sharer-directory code, `acb76b2`):
- `b3_v2_canneal4`: fixed 2 MB, paired with gem5's 2 MB;
- `b3_v2_canneal4_scaled`: 2 MB per core, 8 MB in all, paired with gem5's
  8 MB.

## The window

Instructions 50 M–150 M of the workers. ChampSim measures each worker's own
50–150 M. gem5 gives stats(150 M) − stats(50 M), both stopped on the first
worker, as for ocean.

**Changed from ocean, because of the loader.** The main thread runs about
**4.0 G instructions before any worker starts**: valgrind lackey on the
static binary with 0 anneal steps counted 4,019,311,964 in all. gem5's
0–50 M span is therefore mostly loader. It cannot serve as the steadiness
check, as ocean's first span did. So:
- **Steadiness** is gem5's rate over **50–100 M against 100–150 M**, both
  inside the window. This is why the 100 M runs exist.
- **The loader is idle during the window**, blocked in `pthread_join`. cpu0's
  instructions in the window are reported. If they exceed 0.1% of the
  window's, the rate is also computed over cpu1–cpu4 only, both are stated,
  and the verdict uses cpu1–cpu4, which is what ChampSim counts.

## Pre-registered criteria

R = ChampSim rate / gem5 `(SS+MT).L1_GETX` rate, events per 1,000
instructions, over the window, at each LLC size.

- **Primary: 0.5 ≤ R_b ≤ 2 at 2 MB and at 8 MB**, where R_b uses the protocol
  view. Each size is scored separately; nothing is pooled with ocean or
  barnes.
- **Secondary, as registered for v2: R_b ≤ 1 ≤ R_a.** Scored and reported.
  It failed on ocean, where presence ran far below gem5, and it is expected
  to fail here too.
- **Secondary, new, informed by ocean: R_a < R_b at both sizes.** Presence
  falls below the protocol view because private copies are evicted before
  another core stores.
- **Window check:** if gem5's rate over 50–100 M and 100–150 M differs by
  more than 2×, the verdict is stated per span.
- **Hierarchy check:** if shared-cache demand accesses per KI differ by more
  than 2× between the simulators, the verdict says R's interpretation is
  weakened.
- **Nothing is tuned after R is seen**: not the counter, not the configs,
  not the window. A fix is a new pre-registered comparison.

## Qualifying checks

**ChampSim:**
- both trees pass `analyze_rows.py check`;
- the self-check reads 0 mismatches and 12 private caches registered;
- the private regime reads exactly 0 for (a) and (b);
- **every pre-existing column** of the v2 LRU canneal 4c rows matches the
  `phaseA` (fixed 2 MB) and `phaseA_scaled` LRU canneal 4c rows exactly
  (`analyze_rows.py same`), so the directory changed nothing on canneal
  either. Those rows ran on `bin/champsim_phaseA_20260923`. A mismatch
  stops the scoring until it is explained.

**gem5:** each run's `config.ini` and `run.log` show:
- `CANNEAL` with the five arguments above, and 5 CPUs;
- the L2 size;
- `ordered=false` on all 10 L0↔L1 buffers, and `randomization=false`;
- `max_insts_any_thread` = the stop on cpu1–cpu4 and 0 on cpu0;
- an exit on "a thread reached the max instruction count".

The per-worker instruction counts at each stop are reported.

## Known differences, untuned

These are the six of `b3_design_2026-10-04.md`, of which two are sharper
here:
- **Thread interleaving.** canneal's result depends on it. Native routing
  costs were 8.0578e7 (dynamic), 8.0530e7 (static) and 8.0506e7 (the traced
  run). gem5's interleaving is a fourth.
- **Binaries.** Same program code; libc and libstdc++ linkage differs. The
  workers spend their time in canneal's own code.

The other four: the core model, tree pseudo-LRU, and the two counter effects
of `b3v2_design_2026-10-05.md`.

## Cost

Each gem5 run is the loader plus up to 600 M worker instructions. gem5
measured about 110 K instructions/s on ocean: the n514 whole-program run,
1.38 G instructions in 12,607 s. So each run should take roughly 11–13 h. The six run concurrently, alongside
four ChampSim jobs of about 3 h each.
