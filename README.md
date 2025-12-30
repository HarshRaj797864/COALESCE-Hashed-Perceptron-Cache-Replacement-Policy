
# MESI Directory-Based Coherence Simulator

A simple C++ simulator that models **directory-based MESI cache coherence** for a small multicore system.  
This project was developed as **Task 2 (Foundation Phase)** of an RL-based cache replacement project targeting **ChampSim**.

The goal is not performance accuracy, but **correct architectural modeling** of coherence metadata that will later be used as **features for a Reinforcement Learning agent**.

---

## What This Project Does (Task 2)

- Models MESI state transitions for cache lines
- Simulates directory-based coherence (not bus snooping)
- Tracks which cores share a cache line
- Generates synthetic read/write traffic across multiple cores
- Extracts coherence metadata (MESI state, sharer count)

This simulator is intentionally **standalone** to validate logic before integration into ChampSim.

---

## Background

### MESI Cache Coherence Protocol

MESI is a hardware-level protocol used to maintain consistency across private caches in a shared-memory multicore system.

Each cache line can be in one of four states:

- **Modified (M)**  
  Cache holds the only up-to-date copy. Memory is stale.

- **Exclusive (E)**  
  Cache holds the only copy and matches memory. Can transition to Modified on write.

- **Shared (S)**  
  Multiple caches hold the same clean copy. Reads allowed, writes require invalidation.

- **Invalid (I)**  
  Cache line is not valid.

### Why Directory-Based Coherence

Bus snooping does not scale with core count.  
Directory-based coherence replaces broadcast with **targeted messages**.

A **Directory**:
- Tracks the state of each cache line
- Knows exactly which cores have a copy
- Sends invalidations only to relevant cores

---

## Sharer Tracking

Each cache line maintains a **Sharer List**.

- Logical model: which cores currently hold the line
- Hardware model: **Bitmask (Bit-Vector)**

Example for 4 cores:
```

Bitmask: 1001
Meaning: Core 0 and Core 3 share the line

```

From this, we derive:

- **Sharer Count** = number of bits set  
  This indicates how *popular* a cache line is.

---

## Current Design Decision (Important)

- The simulator currently uses `std::set<int>` to track sharers.
- This was chosen for **clarity and correctness** during early development.

**Planned optimization for ChampSim integration:**
- Replace `std::set` with a **bitmask / bit-vector**
- Lower memory overhead
- Faster state updates
- Closer to real hardware implementation

This separation allows rapid prototyping without locking into premature low-level optimizations.

---

## Synthetic Traffic Generation

- Simulates **4 cores** (configurable)
- Random Read / Write memory accesses
- Triggers MESI state transitions
- Exercises invalidations and sharer updates

Each access conceptually looks like:
```

(core_id, address, access_type)

````

---

## Why This Matters for Reinforcement Learning

Traditional cache replacement (LRU) ignores coherence behavior.

This simulator enables extraction of **coherence-aware features** for an RL agent:

**Planned RL State Inputs:**
1. MESI State
2. Sharer Count
3. Access frequency (future extension)

**Intuition:**
- High sharer count → widely shared data → should be kept
- Low sharer count → private or cold data → eviction candidate

This project validates that such features can be computed correctly.

---

## Usage

Compile:
```bash
g++ mesi_sim.cpp -o mesi_sim
````

Run:

```bash
./mesi_sim
```

---

## Project Context

* Course/Research Project: RL-based Cache Replacement
* Simulator: ChampSim (integration in later phase)
* Current Phase: Foundation / Feature Validation

This module focuses on **architecture decisions and correctness**, not final performance numbers.
