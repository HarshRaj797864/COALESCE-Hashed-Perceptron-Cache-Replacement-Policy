# COALESCE

**Coherence-Observant Adaptive Learning for System-wide Cache Efficiency**

A coherence-aware cache replacement policy that uses a lightweight perceptron predictor to make eviction decisions based on program context, MESI coherence state, and sharing patterns across cores.

B.Tech Project — Harsh Raj (S20240010084) — Under Dr. Bheemappa Halavar

---

## Project Structure

```
COALESCE/
├── simulator/                  # ChampSim-based simulation environment
│   ├── replacement/            # Cache replacement policies
│   │   ├── coalesce/           # ★ COALESCE policy (coalesce.h, coalesce.cc)
│   │   ├── lru/                # LRU baseline
│   │   ├── srrip/              # SRRIP baseline
│   │   ├── drrip/              # DRRIP baseline
│   │   ├── ship/               # SHiP baseline
│   │   └── random/             # Random baseline
│   ├── inc/                    # Header files (cache.h with MESI extensions)
│   ├── src/                    # ChampSim core source files
│   ├── traces/                 # PARSEC canneal benchmark traces
│   ├── results/                # Simulation output logs
│   │   ├── canneal_4core_50M/  # 4-core results (all policies)
│   │   └── canneal_8core_100M/ # 8-core results (COALESCE vs SRRIP)
│   ├── bin/                    # Compiled simulator binaries
│   ├── tracer/                 # Intel PIN 3.31 multi-thread tracer
│   ├── btp_config.json         # 4-core simulation config
│   └── btp_8core_config.json   # 8-core simulation config
├── simulations/                # Phase 1 standalone C++ simulator
│   └── coalesce_final.cpp      # Event-driven simulator with 5 policies
├── latex/                      # Presentation files
│   ├── COALESCE.tex            # Mid-term review slides
│   └── latex2/end_term.tex     # End-term review slides
├── reports/                    # Project reports
├── AIM.md                      # Project aims and objectives
└── ARCHITECTURE.md             # System architecture documentation
```

---

## How to Build

### Prerequisites

- GCC 10+ with C++17 support
- Make
- Python 3 (for ChampSim's config script)

### Build the Simulator

```bash
cd simulator

# Configure with COALESCE policy (4-core)
./config.sh btp_config.json

# Build
make
```

The binary will be placed in `simulator/bin/`.

### Build for 8-Core

```bash
cd simulator
./config.sh btp_8core_config.json
make
```

---

## How to Run Simulations

### 4-Core (50M instructions per core)

```bash
cd simulator
bin/champsim_btp_test \
  --warmup-instructions 200000000 \
  --simulation-instructions 50000000 \
  traces/canneal_big0.champsimtrace \
  traces/canneal_big1.champsimtrace \
  traces/canneal_big2.champsimtrace \
  traces/canneal_big3.champsimtrace
```

### 8-Core (100M instructions per core)

```bash
cd simulator
bin/champsim_8core_coalesce \
  --warmup-instructions 1000000000 \
  --simulation-instructions 100000000 \
  traces/canneal_big0.champsimtrace \
  traces/canneal_big1.champsimtrace \
  traces/canneal_big2.champsimtrace \
  traces/canneal_big3.champsimtrace \
  traces/canneal_big4.champsimtrace \
  traces/canneal_big0.champsimtrace \
  traces/canneal_big1.champsimtrace \
  traces/canneal_big2.champsimtrace
```

Output is printed to stdout. Redirect to a file:

```bash
bin/champsim_8core_coalesce ... > results/canneal_8core_100M/coalesce_100M.txt
```

---

## Switching Replacement Policies

Edit the `"replacement"` field under `"LLC"` in the config JSON:

| Policy | Value |
|---|---|
| COALESCE | `"coalesce"` |
| LRU | `"lru"` |
| SRRIP | `"srrip"` |
| DRRIP | `"drrip"` |
| SHiP | `"ship"` |
| Random | `"random"` |

Then rebuild:

```bash
./config.sh btp_config.json
make clean && make
```

---

## Key Source Files

| File | Description |
|---|---|
| `replacement/coalesce/coalesce.h` | COALESCE data structures: weight tables, ghost buffer, Bloom filter |
| `replacement/coalesce/coalesce.cc` | Core logic: `find_victim()`, `update_replacement_state()`, perceptron prediction |
| `inc/cache.h` | Extended `cache_block` with MESI state and sharer bitmask fields |
| `simulations/coalesce_final.cpp` | Phase 1 standalone event-driven simulator |
| `btp_config.json` | 4-core, 2MB LLC (2048 sets × 16 ways) |
| `btp_8core_config.json` | 8-core, 2MB LLC (2048 sets × 16 ways) |

---

## Results Summary

| Configuration | COALESCE | Baseline | Improvement |
|---|---|---|---|
| 4-core, 50M instr | IPC 0.4996 | LRU: 0.4023 | +24.2% |
| 8-core, 100M instr | 415.9M cycles | SRRIP: ~612M cycles | 32% faster |

---

## References

1. Jiménez, D. A. *Multiperspective Reuse Prediction*, MICRO 2017
2. Sethumurugan et al. *Cost-Effective Cache Replacement Using ML*, HPCA 2021
3. Souza & Freitas. *RL-Based Cache Replacement for Multicore*, IEEE Access 2024
4. Wu et al. *Concurrency-Aware Cache Miss Cost Prediction*, GLSVLSI 2025
