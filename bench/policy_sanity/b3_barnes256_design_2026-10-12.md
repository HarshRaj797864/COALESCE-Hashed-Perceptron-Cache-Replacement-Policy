# B3, barnes with 256-body leaves — gem5 on the traced program: pre-registered

**2026-10-12.** Written and committed **before** the gem5 runs exist.

The `barnes_4t` traces are of a BARNES built with `MAX_BODIES_PER_LEAF 256`;
SPLASH-3's source, and the binary gem5 ran, use 10
(`b3_barnes_stream_2026-10-12.md`). Every barnes comparison so far divided
one program's rate by another's. This runs gem5 on the traced program.

**It is not SPLASH-3's barnes, and is reported as "barnes, 256-body
leaves" wherever it appears.** It is a lock-heavy program: a pthread mutex
about every 190 instructions, on ~85 shared mutexes. The standard barnes
needs new traces and is a separate experiment.

## The ChampSim side is already fixed

No ChampSim run is made for this. The rows were pulled on 2026-10-12, before
the mismatch was known (`phasea_rows_v16.txt`, `b3_rows_v7.txt`), LRU,
4 cores, 2 MB, 50 M + 100 M:

| tree | level | protocol events | upgrades | LLC demand accesses | LLC RFOs |
|---|---|---|---|---|---|
| `b3_v3_barnes4`, `b3_v4l0_barnes4` | 0 | 50 (0.00012 per 1,000 instructions) | 0 | 0.513 | 94 |
| `b3_v4_barnes4` | 1 | 2,566 (0.00635) | 0 | 0.510 | 2,591 |
| `b3_v5_barnes4` | 2 | 189,125 (0.4684) | 209,018 (0.5176) | 1.507 | 189,170 (0.4685) |

## What runs

**The binary** (`scripts/barnes256_gem5.sh`, steps 1–4):
- a copy of the server's `apps/barnes`, with `defs.h.in`'s one line changed
  from 10 to 256; the tree is not touched;
- the tree's own flags, static, with the stack protector and fortify off
  (the traced binary has neither).

**gem5**, as every B3 run: MESI_Three_Level, TimingSimpleCPU, 4 CPUs,
32 kB / 512 kB private, a 2 MB 16-way shared cache, the traced input
(`n16384-p4`), stopped when any thread reaches 50 M and 150 M instructions.
The window is their difference.
- No 8 MB run: at 8 MB barnes takes no shared-cache miss in ChampSim.
- No whole-program run: a step is about four times as long as the standard
  program's.

## Qualifying checks

If one fails, nothing is scored until it is explained.

- **QB, the binary.** The traced binary reads as a 256-body-leaf build
  (`loadtree` compares a leaf's body count with 0x100). The new static
  binary does too, and each force-phase function (`gravsub`, `walksub`,
  `hackgrav`, `hackwalk`, `subdivp`, `ComputeForces`, `stepsystem`) has the
  traced binary's instruction count and constants. The pipeline stops
  otherwise and launches nothing.
- **QG, the runs.** Both end at their instruction stop. Each `config.ini`
  shows the 256 binary, a 2 MB L2, 8 of 8 L0↔L1 buffers unordered and
  randomization off.
- **QS, the same stream.** `b3_stream_check.py`: per 1,000 instructions in
  the window, gem5's instructions with a load, with a store, and
  read-modify-writes are each within 5% of the trace's (319.4, 168.1,
  26.84). gem5's locked read-modify-writes are within 10% of the trace's
  10.49.

## Predictions

R_b, U and the band (0.5 to 2) are defined as in
`b3v4_coherent_private_design_2026-10-11.md`. Window 50–150 M.

**What gem5 should count, from the traces alone.** An ideal directory over
the mutex array, with no caches and no latency, counts 640–680 thousand
hand-overs in the window: 237–254 thousand store misses that find another
core, and 401–427 thousand upgrades. A real protocol takes time to hand a
line over, during which its holder keeps using it, so gem5 should count no
more than that.

- **P1, level 2, the target: 0.5 ≤ R_b ≤ 2.** Expected 0.75 to 1.6: gem5's
  `(SS+MT).L1_GETX` between 120 and 250 thousand.
- **P2, level 2, upgrades: 0.5 ≤ U ≤ 2.** Expected 0.5 to 1.05. **The low
  edge is at risk:** if gem5 counts as many upgrades as the ideal directory,
  U is 0.49 to 0.52.
- **P3, level 1: R_b < 0.5.** Expected under 0.05. A lock that hits its
  holder's copy is never handed over without the upgrade.
- **P4, level 0: R_b < 0.5.** Expected near 0.
- **P5, traffic at level 2:** ChampSim's shared-cache demand accesses per
  1,000 instructions within 2× of gem5's. **At risk on the low side:** an
  upgrade reaches gem5's shared cache and is handled in ChampSim's L1D. The
  sum of ChampSim's demand accesses and upgrades (2.02) is reported beside
  it.
- **P6, hand-overs in all** (store misses that find another core, plus
  upgrades): ChampSim's 398,143 within 2× of gem5's count.

## How each outcome is read

- **P1 and P2 hold:** at level 2 the tool reproduces a lock-heavy program's
  hand-overs within the band. With ocean and canneal that is three programs
  at 4 cores, one of them non-standard.
- **P1 fails high (R_b > 2):** ChampSim hands lock lines over more often
  than a real protocol does. Candidates: a hand-over costs no time; the core
  asks for ownership when a read-modify-write executes, long before its
  store retires.
- **P1 fails low (R_b < 0.5):** ChampSim misses hand-overs. Candidates:
  store-to-load forwarding hides read-modify-write loads from the cache
  (about 25 in 26 in this trace); a hand-over is one event per run of accesses in
  the out-of-order window where gem5's in-order core makes several.
- **P3 or P4 fails (R_b ≥ 0.5 at level 0 or 1):** it would contradict the
  reason for step 3.
- **QS fails:** the two are still not one program. Nothing is scored.

**Nothing is tuned after R is seen.** The result changes no run in flight:
the A5 rerun is canneal and ocean.

## What it cannot show

- It is one window inside the first force phase of a non-standard program.
- gem5's core is in-order and ChampSim's is out-of-order. A lock-heavy
  program is where that difference shows most.
- It says nothing about the standard barnes, whose sharing is the tree
  build and the bodies, not the locks.
