# COALESCE: a multi-threaded, coherence-aware ChampSim, validated against gem5

[ChampSim](https://github.com/ChampSim/ChampSim) is a trace-driven simulator
widely used for cache replacement and prefetching research. By design it
models **multi-programmed** workloads: each core runs its own trace in its own
address space, so no two cores ever touch the same cache line. Its own paper
states this ("each core is assumed not to interact with any other core's
execution"). So a multi-core experiment in stock ChampSim measures cores that
compete for cache space but never share data, and it cannot show how a
replacement policy behaves when threads do share data.

This repository extends ChampSim so that **the threads of one parallel program
share memory, keep their private caches coherent, and replay their
synchronisation**. It then checks the result against gem5's full MESI
protocol, program by program, with pre-registered pass/fail rules.

- **The tool is the main contribution:** shared memory, coherence state,
  coherent private caches and synchronised replay, plus the gem5 comparison
  that measures how far to trust it.
- **COALESCE** (Coherence-Observant Adaptive Learning for System-wide Cache
  Efficiency) is a coherence-aware perceptron LLC replacement policy. It is
  the experiment run on the tool: does coherence state help predict which
  line to evict?

> **Status (November 2026): work in progress.** The simulator agrees with
> gem5 on seven program spans and reads low on five; those are under
> diagnosis (see [Validation](#validation-against-gem5)). Policy results are
> being rerun on the finished simulator. **No claim is made yet that COALESCE
> beats the baselines.**

---

## Contents

- [What the extension adds](#what-the-extension-adds)
- [Validation against gem5](#validation-against-gem5)
- [The COALESCE policy](#the-coalesce-policy)
- [Building](#building)
- [Running](#running)
- [Tracing a multi-threaded program](#tracing-a-multi-threaded-program)
- [Checks to run before trusting a build](#checks-to-run-before-trusting-a-build)
- [How the work is done](#how-the-work-is-done)
- [Repository layout](#repository-layout)
- [Credits and licence](#credits-and-licence)

---

## What the extension adds

Everything below is built on ChampSim `develop` (at `f9ed890e`) and keeps
stock ChampSim's behaviour available: `--regime private` is the unmodified
simulator.

| Feature | What it does | Where | Setting |
|---|---|---|---|
| **Shared virtual memory** | Cores running threads of one program share one address space, so the same virtual address maps to the same physical page on every core. | `src/vmem.cc`, `inc/vmem.h` | `--regime shared` (`private` = stock ChampSim) |
| **Coherence state on cache blocks** | Every block carries a MESI state and a sharer mask, so the LLC knows a line is shared or modified, and by whom. | `inc/block.h`, `src/cache.cc` | always on |
| **Sharer directory** | Tracks which cores hold each line, independent of whether the (non-inclusive) LLC still holds it. | `src/sharer_directory.cc` | always on in the shared regime |
| **Coherent private caches** | Level 1: a store miss (RFO) accepted at the LLC invalidates other cores' private copies. Level 2: also the *upgrade*, where a store that hits a private copy takes ownership when another core holds the line. | `src/cache.cc` | `--private-coherence 0\|1\|2` (default 0; every evaluation run uses **2**) |
| **Atomics as ownership requests** | The load half of a read-modify-write (`lock cmpxchg`, `xchg`, ...) is issued as an ownership request, as real hardware and gem5 do. | `src/ooo_cpu.cc` | always on |
| **Synchronised replay** | The tracer records each `pthread` mutex, condition variable, barrier and thread creation. On replay, a core waits at a recorded event until the event it depends on has happened. A release is a fence, and a barrier departure waits for every arrival. A mutex stays exclusive, but **which waiting thread gets it next is decided by simulated timing**, not by the order Pin happened to record. | `src/sync_replay.cc`, `inc/sync_replay.h` | traces with sync records; `--sync-mutex-order timing\|recorded` |
| **gem5-rule view** | Records-only counters that apply gem5's MESI_Three_Level rule for when a core stops being listed as a holder, so the two simulators can be compared on the same definition. | `src/sharer_directory.cc` | printed in every log |
| **Invalidation latency** | An optional extra delay on each invalidation. | `src/cache.cc` | `--coherence-latency N` (default 0) |
| **Multi-threaded Pin tracer** | One trace per thread, with sync records. Also skip/length per thread, and CPUID answered from a file (to trace a program as it would run on gem5's CPU). | `tracer/pin/champsim_tracer.cpp` | `-sync 1`, `-skip_instr`, `-max_instr`, `-cpuid FILE`, `-start0` |

Paths in the table are under `simulator/`. Each log prints its coherence
counters: invalidations, ownership events that find another core, upgrades,
and a self-check that must read 0.

## Validation against gem5

**The measure.** For each program, ChampSim and gem5 run the same threads
over the same instruction window. gem5 uses its timing simple CPU and Ruby's
MESI_Three_Level protocol, with a cache hierarchy that matches ChampSim's at
all three levels (private L1s, private L2, shared 2 MB LLC). The primary
measure is

> **R_g5** = (store misses that find the line held by another core, per
> 1,000 instructions, in ChampSim) ÷ (the same in gem5)

It passes when it lies in the pre-registered band **0.5–2**. A program is
only scored if both simulators executed the same instruction stream
(checked from the traces and gem5's own counts). It must also be
*discriminating*, meaning gem5 sees at least 500 such events; otherwise
there is nothing to disagree about.

**Where it stands** (4 cores, 2 MB LLC unless stated; programs from
SPLASH-3 and PARSEC):

| Program (span) | Role | R_g5 | Result |
|---|---|---:|---|
| canneal (PARSEC) | development | 1.016 | agrees |
| canneal, 8 cores | check | 1.537 | agrees |
| ocean, contiguous | development | 0.682 (8 MB LLC: 0.768) | agrees |
| barnes, force phase | development | 0.634 | agrees |
| radix | held out | 0.990 | agrees |
| LU, non-contiguous | held out | 1.831 | agrees |
| ocean, non-contiguous | reported apart (a layout of a development program) | 0.663 | agrees |
| barnes, start / whole window | development | 0.233 / 0.249 | **reads low** |
| barnes, 256-body leaves | development | 0.267 | **reads low** |
| fluidanimate (PARSEC) | held out | 0.398 | **reads low** |
| vips (PARSEC) | held out | 0.309 | **reads low** |

- **Not scored**, because the same-stream or set-up checks failed:
  - fft, volrend, fmm;
  - bodytrack, whose untraced main thread does over 1% of the work;
  - streamcluster, being re-traced.
- **Not discriminating** (fewer than 500 sharing events in gem5): LU
  contiguous, raytrace, water-nsquared, facesim.

**What the failures have in common.** Four of the five spans that read
low are lock-heavy: in ChampSim, barnes and fluidanimate spend 2.8–65% of
their cycles waiting for a mutex. The agreeing spans spend under 0.05%,
except barnes's force phase (10.9%). vips is the exception: it hardly waits
(0.075%), and its candidate causes are its untraced main thread and drift
between its threads. For the lock-heavy spans, the leading hypothesis, now
under test:
- In gem5, a thread waiting for a lock keeps attacking the lock word, so
  the word's cache line moves between cores about three times per contended
  acquire.
- In the replay, the waiting thread is held silently, so the line moves
  once.

A records-only counter of contended acquires is being built to test whether
this accounts for the gap, before any fix is designed.

**Also measured, and stated as limits:**
- **Speed: no claim.** On standard barnes at 4 cores, the tool is 1.43× gem5's
  O3 + Ruby, short of the 2× set in advance. gem5's in-order core is faster
  than ChampSim. The extension itself costs 3%.
- Atomics are issued as ownership requests, but a read-modify-write is not
  modelled as one indivisible operation.
- The LLC has 16 MSHRs, and page tables are per core.
- The LLC's own MESI bits follow simpler rules than the sharer directory.

## The COALESCE policy

COALESCE is a hashed-perceptron LLC replacement policy whose features include
the line's coherence state.

- **Votes.** Two 2,048-entry tables of 8-bit weights vote on each candidate
  way, both keyed on the PC that allocated the line:
  - one table is indexed by the PC with the line's **MESI state**;
  - the other by the PC with its **sharer count**.
- **Coherence bias.** When the vote is positive (predicted reuse), it is
  raised by +40 for a MODIFIED line and by +20 × sharers for a line with
  two or more sharers.
- **Victim.** The way with the lowest vote is evicted.
- **Training**, on 1 set in 32:
  - a hit trains the allocating PC up;
  - an eviction trains it down and leaves a ghost entry;
  - a miss that hits a ghost trains the evicted line's PC up five times
    (rescue).

Code: `simulator/replacement/coalesce/`. Ablations: `coalesce_no_mesi`,
`coalesce_no_sharer`.

**Baselines**, all selectable with `--policy`:
- LRU, SRRIP, DRRIP, SHiP and Random, unchanged from upstream ChampSim;
- Hawkeye and Mockingjay, ported from the authors' artifacts and checked
  line by line;
- `srrip_bias`, SRRIP with a fixed coherence insertion bias, to separate
  "uses coherence state" from "learns".

Every replacement module was audited in September 2026. Nine of eleven had a
defect that compiled, ran and gave plausible numbers: for example, a policy
that was never told about fills, or a `find_victim` that was silently never
called. All were fixed, and three guards (below) now stop those classes from
returning.

**Status:** the policy's design is frozen until the gem5 validation is
settled. Earlier measurements on the pre-synchronised simulator showed it
fastest in one configuration and behind in others; the final rankings are
being rerun on the finished tool. No performance claim is made here.

## Building

Requirements: Linux, GCC 10+, Make, Python 3, and the vcpkg packages (CLI11,
LZMA, Bzip2, fmt).

```bash
cd simulator
git submodule update --init        # vcpkg
vcpkg/bootstrap-vcpkg.sh
vcpkg/vcpkg install
make -j"$(nproc)"                  # -> bin/champsim, with every policy built in
```

There is one binary; the policy, core count and coherence settings come from
a runtime configuration file, generated by `scripts/make_config.py`.

## Running

```bash
cd simulator
# 4 cores, threads sharing memory, coherent private caches (level 2), LRU
scripts/make_config.py --policy lru --cores 4 --regime shared --private-coherence 2 -o cfg.json

bin/champsim --config cfg.json \
  --warmup-instructions 50000000 --simulation-instructions 100000000 \
  traces/ocean4/raw0.champsimtrace.xz traces/ocean4/raw1.champsimtrace.xz \
  traces/ocean4/raw2.champsimtrace.xz traces/ocean4/raw3.champsimtrace.xz
```

Other options of `make_config.py`:
- `--policy` (any of the eleven above);
- `--llc-per-core-mb 2` (scale the LLC with the core count);
- `--regime private` (stock ChampSim);
- `--sync-mutex-order recorded`, `--coherence-latency N`, `--llc-mshr N`.

Points that are easy to get wrong:
- **Give each core a different thread of one parallel run.** Never repeat a
  trace across cores: duplicated traces alias by construction and
  manufacture sharing.
- **A shared run must show sharing.** It prints non-zero `VMEM ALIASED FILLS`
  and `LLC COHERENCE INVALIDATIONS`. A private run prints zero
  invalidations.
- **Multi-core logs print the cache statistics twice.** Read the "Region of
  Interest" block; summing the whole log doubles every LLC counter.
- **A trace shorter than warm-up plus simulation silently restarts from its
  beginning.** Check that the log never says `Reached end of trace`.

Traces are not included in the repository (they are tens of GB).

## Tracing a multi-threaded program

The tracer needs Intel Pin (tested with 3.31).

```bash
cd simulator/tracer/pin
make PIN_ROOT=/path/to/pin obj-intel64/champsim_tracer.so
/path/to/pin/pin -t obj-intel64/champsim_tracer.so -o raw -sync 1 -max_instr 215000000 -- ./OCEAN -n514 -p4
# -> raw0.champsimtrace (the main thread), raw1.champsimtrace, ... one per thread
```

- `-sync 1` writes the synchronisation records that the replay needs.
  Without it the threads run free and drift apart by millions of
  instructions.
- `-skip_instr` skips a serial set-up phase.
- `-cpuid FILE` makes the traced program see the same CPU as gem5's, so
  glibc picks the same string and maths routines.
- `scripts/sync_anchor.py` and `scripts/sync_cut.py` align the main
  thread's trace with the workers' start, keeping the sync records valid.

## Checks to run before trusting a build

```bash
bench/policy_sanity/check_include_path.sh      # headers come from this tree
bench/policy_sanity/check_fill_hook.sh         # every policy is told about fills
bench/policy_sanity/check_signatures.sh        # every find_victim is actually called
bench/policy_sanity/check_coherence_exact.sh   # coherence counters hit hand-computed counts exactly, levels 0-2 (~25 min)
```

`check_coherence_exact.sh` runs small traces whose coherence events can be
counted by hand: ping-pong, upgrades, write-backs, barriers, mutex hand-overs,
condition variables. It requires every counter to match exactly. A non-zero
counter only proves a code path runs; these tests check that it counts the
right thing.

## How the work is done

- **Pre-registered.** Each experiment starts as a design note in
  `bench/policy_sanity/` (`*_design_*.md`). The note states the predictions
  and the pass/fail rules, and is committed before any number exists. A
  dated results note follows, and reports failures as failures.
- **No tuning to a result.** A failed check is diagnosed; the code is never
  adjusted until a check passes.
- **Raw rows are committed.** Rows such as `bench/policy_sanity/*_rows_*.txt`
  are committed, and every reported number is re-derived from them by a
  script (`scripts/b3_score.py`, `scripts/heldout2_score.py`, ...).
- **Results that turned out wrong stay recorded as wrong.** Two examples:
  - a "barnes" trace set that was in fact built with 256-body tree leaves;
  - a cross-regime ranking effect that disappeared once LLC size was
    controlled.

  Their notes say so.

## Repository layout

```
simulator/                   ChampSim develop @ f9ed890e, with the extension
├── inc/  src/               core, caches, vmem overlay, sharer directory, synchronised replay
├── replacement/             coalesce (+ two ablations), hawkeye, mockingjay, srrip_bias,
│                            lru, srrip, drrip, ship, random
├── scripts/make_config.py   generates every runtime configuration
├── tracer/pin/              the multi-threaded Pin tracer
├── tracer/stream_count/     Pin counter for the same-stream check against gem5
└── test/                    upstream unit tests (+ shared-VMEM tests 801, 803)
scripts/                     experiment runners, scoring and checking scripts
bench/policy_sanity/         guards, exact coherence tests, dated design and results notes, raw rows
bench/*.c                    micro-programs with hand-known coherence counts
latex/hip/                   an earlier paper submission (superseded by the results above)
```

## Credits and licence

**Author:** Harsh Raj, IIIT Sri City. **Advisor:** Dr. Bheemappa Halavar.
B.Tech project, IIIT Sri City.

The simulator is derived from [ChampSim](https://github.com/ChampSim/ChampSim)
(Apache License 2.0, see `simulator/LICENSE`). The validation uses
[gem5](https://www.gem5.org/), PARSEC 3.0 and SPLASH-3, none of which is
redistributed here. No separate licence has yet been chosen for the rest of
this repository.
