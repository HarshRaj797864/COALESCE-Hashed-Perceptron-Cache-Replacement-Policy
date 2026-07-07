# COALESCE: Coherence-Aware Perceptron Cache Replacement for Multithreaded Workloads

COALESCE is a last-level cache (LLC) replacement policy that uses cache
coherence state as a first-class eviction signal. It is implemented as a
[ChampSim](https://github.com/ChampSim/ChampSim) replacement module and
evaluated under a **shared-virtual-memory overlay** that restores genuine
inter-core data sharing to the simulator — enabling, to our knowledge, the
first evaluation of learned LLC replacement under true multithreaded sharing.

This repository accompanies the paper *COALESCE: Coherence-Aware Perceptron
Cache Replacement for Multithreaded Workloads* (Harsh Raj, Bheemappa Halavar;
IIIT Sri City).

## Why this exists

Learned replacement policies (Hawkeye, Mockingjay, …) are evaluated almost
exclusively on **multi-programmed** workloads — independent programs that
share cache *capacity* but never share *data*. ChampSim's default per-CPU
address spaces make genuine sharing impossible, so every multi-core
evaluation built on it is multi-programmed by construction. We extend
ChampSim with a shared-VMEM overlay that maps identical virtual addresses
across participating cores to the same physical page, exposing real
coherence invalidations and sharer counts to the replacement policy. Under
this regime, the multi-programmed state of the art degrades sharply, and a
coherence-state-aware retention bias recovers most of the lost performance on
write-heavy irregular workloads.

## Repository layout

```
simulator/
├── inc/                     # headers (block.h: MESI_State + sharer_mask)
├── src/                     # ChampSim core + shared-VMEM overlay (vmem.h/.cc)
├── replacement/
│   ├── coalesce/            # the COALESCE policy
│   ├── coalesce_no_sharer/  # ablation: sharer axis removed
│   ├── coalesce_no_mesi/    # ablation: MESI axis removed
│   ├── lru/ srrip/ drrip/ ship/  # heuristic baselines
│   ├── hawkeye/ mockingjay/ # learned baselines (our reimplementations)
│   └── random/
├── btp_config.json          # 4-core config (LLC 2 MB, 2048 sets × 16 ways)
└── btp_8core_config.json    # 8-core config
bench/                       # overlay-validation scripts
latex/hip/                   # paper source + figures
```

## The shared-VMEM overlay (the methodological contribution)

The overlay lives in `simulator/inc/vmem.h` / `simulator/src/vmem.cc`. A
config's `virtual_memory.vmem_shared_cpus` lists the cores that share an
address space; identical virtual addresses from those cores alias onto one
physical page (`set_shared_cpus()`), so the LLC observes real cross-core
sharing, MESI transitions, and coherence invalidations. Setting the list
empty reproduces default ChampSim (per-CPU private memory).

Validation: on a 100%-read workload the overlay reports *exactly zero* LLC
invalidations, while on write-heavy workloads invalidations scale with core
count — confirming the recorded coherence activity reflects genuine sharing,
not an artefact.

## How COALESCE works

Two hashed-perceptron tables vote on each candidate way using the block's
program counter, MESI state, and sharer count. On top of the learned vote,
a coherence bias is added only to blocks the perceptron already favours
(`+40` for MODIFIED lines, `+20 × sharers` for shared lines); the lowest-vote
way is evicted. Training is confined to sampled sets, with a Bloom-filter
ghost-tag rescue path for wrongly-evicted contexts. See the paper for the
full design and a mechanism decomposition of which components carry the
policy.

## Build & run

```bash
cd simulator
./config.sh btp_8core_config.json    # or btp_config.json for 4-core
make                                  # → bin/champsim_*

bin/champsim_8core_coalesce_shared_v2 \
  --warmup-instructions 50000000 --simulation-instructions 100000000 \
  traces/<trace0..N>.champsimtrace
```

Switch policy via the `"replacement"` field under `"LLC"` in the config JSON
(`coalesce | coalesce_no_sharer | coalesce_no_mesi | lru | srrip | drrip |
ship | hawkeye | mockingjay | random`), then `./config.sh <cfg> && make`.

**Dependencies:** GCC 10+, Make, Python 3, vcpkg-installed CLI11/LZMA/Bzip2/fmt.
Traces (PARSEC / SPLASH-3, captured with Intel Pin) are not included; the
configs and replay scripts reproduce the reported results from them.

## Citing

If you use the overlay or policies, please cite the paper (bibliographic
details to follow at publication).

## License

Baseline simulator code inherits ChampSim's license; the COALESCE modules and
shared-VMEM overlay are released for research use.
