# COALESCE: Coherence-Aware Learning for Scalable Cache Efficiency

This repository contains **standalone systems research prototypes** developed for **Project COALESCE**, a study on designing a **coherence-aware, hardware-friendly learning-based cache replacement policy** for multicore processors.

The project follows a **Systems-First AI** philosophy:  
instead of large models or heavy metadata, COALESCE explores **Hashed Perceptron learning**, **Ghost Buffers**, and **coherence-derived features** that are feasible under **Last-Level Cache (LLC) hardware constraints**.

This repository serves as a **logic validation and experimentation ground** prior to integration with a full microarchitectural simulator.

---

## 🚀 Project Status: Phase 2 — COALESCE Architecture

**Current Focus:**  
Validating a **Hashed Perceptron–based cache replacement policy** augmented with **Ghost Buffers** to distinguish *streaming* versus *reusing* memory access patterns with minimal storage overhead.

---

## 📂 Repository Structure

The project is intentionally developed in **incremental stages** to reduce architectural risk:

```text
.
├── src/
│   ├── coalesce_sim.cpp    # Phase 2: Hashed Perceptron + Ghost Buffer simulator
│   ├── mesi_sim.cpp        # Phase 1: Directory-based MESI coherence simulator
│   └── rl_cache_sim.cpp    # Phase 1: Tabular Q-learning cache simulator
├── docs/                   # Architecture notes and design documentation
└── README.md               # Project overview
````

---

## 🧠 Phase 2: The COALESCE Engine

**Primary File:** `coalesce_sim.cpp`

This simulator implements the **COALESCE policy**, combining **learning-based prediction** with **coherence awareness** while respecting realistic hardware limits.

The goal is not peak ML accuracy, but **predictable, low-cost decisions** suitable for cache controllers.

---

### Core Architectural Components

#### 1. Hashed Perceptron Learning Engine

* Replaces large Q-tables with a **single-layer perceptron**.
* Program Counter (PC) values are mapped to weights via **hash functions**.
* Supports bounded, saturating integer weights to model hardware registers.

**Decision Rule:**

* `weight > threshold` → **Cache**
* `weight ≤ threshold` → **Bypass**

This enables fast inference with constant-time updates.

---

#### 2. Ghost Buffers (Bloom Filters)

* Lightweight structures that track **recently evicted cache lines**.
* Used to identify **zero-reuse streaming behavior** without storing data.
* Prevents cache pollution caused by scans and one-time accesses.

Ghost Buffers allow COALESCE to reason about *reuse* rather than just *recency*.

---

#### 3. Adaptive Hashing

* Dual hashing is used to reduce weight collisions.
* Improves convergence stability under limited perceptron table size.
* Mimics realistic constraints on hardware storage budgets.

---

### Standalone Validation Results

The simulator evaluates mixed workloads consisting of looping and streaming access patterns.

**Observed Behavior:**

* **Looping PCs:** Weights converge to strong positive saturation → **Cache**
* **Streaming PCs:** Weights converge to negative saturation → **Bypass**
* **Result:**

  * ~97% bypass rate for streaming data
  * Cache capacity preserved for high-reuse lines

This demonstrates that **simple linear learning + minimal metadata** is sufficient for effective cache decisions.

---

## 🏗️ Phase 1: Foundational Prototypes

Phase 1 simulators were built to validate individual subsystems before combining them in COALESCE.

---

### A. Directory-Based MESI Coherence Simulator

**File:** `mesi_sim.cpp`

* Models a 4-core system with a centralized directory.
* Explicitly tracks sharers per cache line.
* Validates MESI state transitions and invalidation behavior.

**Key Insight:**
Sharer count is a strong signal of contention and reuse, making it a valuable **learning feature** for cache policies.

---

### B. Tabular Q-Learning Cache Simulator

**File:** `rl_cache_sim.cpp`

* Implements a basic epsilon-greedy Q-learning agent.
* Learns cache vs. bypass decisions from hit/miss rewards.
* Serves as a conceptual baseline for learning-driven caching.

**Outcome:**
Confirmed that learning-based policies can converge, motivating the move to a **more hardware-feasible perceptron model**.

---

## 🔬 Relationship to ChampSim

This repository is **not** a performance benchmark by itself.
Instead, it functions as a **pre-integration validation layer** for ChampSim.

### Planned Integration Path (Phase 3)

| Component      | Standalone Prototype | ChampSim Target         |
| -------------- | -------------------- | ----------------------- |
| Input          | Synthetic traces     | SPEC CPU / GAP          |
| Coherence Info | Explicit tracking    | Directory bitvectors    |
| Learning Logic | C++ perceptron       | Replacement module      |
| Metadata       | Ghost buffers        | Tag-adjacent structures |

Only logic proven stable and useful here will be ported to ChampSim.

---

## 🛠️ Build & Run

### Run COALESCE (Phase 2)

```bash
g++ coalesce_sim.cpp -o coalesce_sim
./coalesce_sim
```

**Expected Output:**
Verbose logs showing perceptron weight updates, hash behavior, and cache/bypass decisions.

---

### Run Phase 1 Simulators

```bash
g++ mesi_sim.cpp -o mesi_sim
./mesi_sim
```

---

## 🎯 Research Direction

COALESCE explores the intersection of:

* Cache coherence
* Lightweight machine learning
* Hardware-aware systems design

The long-term objective is a **scalable, interpretable, and implementable** learning-based cache replacement policy suitable for modern multicore processors.

```
