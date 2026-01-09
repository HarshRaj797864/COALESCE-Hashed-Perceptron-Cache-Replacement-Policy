
# RL-Integrated Multicore Cache System (Prototype)

This repository contains **standalone C++ prototypes** developed as part of a project on **reinforcement learning–based cache replacement** for multicore processors, targeting future integration with **ChampSim**.

The work focuses on **foundational validation**, not final performance optimization.

---

## Project Overview

The project is divided into two core components:

1. **Directory-Based MESI Coherence Simulator**  
   - Validates coherence state transitions
   - Tracks sharer information explicitly
   - Extracts coherence-related metadata

2. **RL-Based Cache Replacement Simulator**  
   - Uses tabular Q-learning
   - Learns cache insertion vs bypass decisions
   - Differentiates streaming and looping access patterns

Both modules are implemented as **standalone simulators** to reduce integration risk before modifying ChampSim.

---

## Repository Structure

```

.
├── mesi_sim.cpp        # Directory-based MESI coherence simulator
├── rl_cache_sim.cpp    # RL-based cache replacement simulator
├── README.md           # Project documentation
└── report/             # Project report and screenshots (if applicable)

```

---

## Module 1: Directory-Based MESI Coherence Simulator

### What This Module Does

- Models a **directory-based MESI protocol**
- Simulates read (`GetS`) and write (`GetM`) requests
- Tracks which cores share each cache line
- Prints detailed debug information for verification

### Key Features

- 4-core synthetic multicore system
- Centralized directory
- MESI states: Modified, Exclusive, Shared, Invalid
- Explicit sharer tracking per cache line
- Randomized synthetic workload generation

This simulator focuses on **correctness and clarity**, not timing accuracy.

---

### Sharer Tracking

Each cache line maintains a **sharer list**, representing which cores currently hold a copy.

- Current implementation: `std::set<int>`
- Hardware-equivalent representation: **bitmask / bit-vector**

Example (4-core system):

```

Bitmask: 1001
Meaning: Core 0 and Core 3 share the line

````

From this, the simulator derives:

- **Sharer Count** – number of active sharers  
  This will be used as a feature for reinforcement learning.

---

### Design Decision

The use of `std::set` was chosen intentionally for:
- Readability
- Debugging clarity
- Correctness verification

**Planned optimization (ChampSim integration):**
- Replace `std::set` with a bitmask
- Lower memory overhead
- Faster updates
- Closer to real hardware behavior

---

## Module 2: RL-Based Cache Replacement Simulator

### Objective

To evaluate whether a **simple reinforcement learning agent** can learn better cache insertion decisions than fixed heuristics such as LRU.

The agent learns to:
- Cache reuse-heavy (looping) data
- Bypass streaming data that causes cache pollution

---

### RL Formulation

- **Learning algorithm:** Tabular Q-learning
- **State:** Program Counter (PC), hashed into a fixed-size table
- **Actions:**
  - Cache (insert line)
  - Bypass (do not insert)
- **Policy:** Epsilon-greedy

---

### Reward Design

| Event | Reward |
|------|--------|
| Cache hit (reuse) | +10 |
| Cache bypass | +0.5 |
| Cache insert cost | −0.1 |

This reward structure encourages reuse-aware cache behavior while discouraging pollution.

---

### Experimental Setup

- Small set-associative cache (intentionally constrained)
- Synthetic mixed workload:
  - Looping accesses (high reuse)
  - Streaming accesses (no reuse)
- Multiple training epochs

---

### Key Observations

- The agent learns to favor **CACHE** for looping PCs
- The agent learns to favor **BYPASS** for streaming PCs
- Cache hit rate improves during early training
- Minor fluctuations occur due to exploration (ε-greedy policy)

These results validate that even lightweight RL can capture useful cache behavior.

---

## Relationship to ChampSim

ChampSim is a **trace-based microarchitectural simulator** used for realistic cache evaluation.

Key characteristics:
- Uses instruction traces (IP, branch outcome, memory addresses)
- Models timing and cache hierarchy
- Does not execute real instructions or store data values

In ChampSim, users modify **policy components**, not the CPU core:
- Cache replacement
- Prefetching
- Branch prediction

---

### Planned ChampSim Integration

In later phases, this project will:
- Port the RL agent into `replacement.cc`
- Expose coherence-derived features (e.g., sharer count)
- Compare RL-based replacement against baseline LRU
- Evaluate using SPEC CPU 2006 traces

---

## How to Build and Run

### MESI Coherence Simulator

```bash
g++ mesi_sim.cpp -o mesi_sim
./mesi_sim
````

---

### RL Cache Replacement Simulator

```bash
g++ rl_cache_sim.cpp -o rl_cache_sim
./rl_cache_sim
```

---

## Project Scope and Status

* **Current Phase:** Foundation / Prototyping
* **Focus:** Correctness, learning behavior, architectural understanding
* **Not yet implemented:**

  * ChampSim RL integration
  * Timing-aware learning
  * Multi-step reward modeling

---

## Key Takeaway

This repository demonstrates that:

* Coherence metadata can be extracted correctly
* Reinforcement learning can distinguish memory access patterns
* A staged prototyping approach reduces full-system integration risk

The work lays a solid foundation for coherence-aware, learning-based cache replacement in realistic multicore simulators.

---

```
