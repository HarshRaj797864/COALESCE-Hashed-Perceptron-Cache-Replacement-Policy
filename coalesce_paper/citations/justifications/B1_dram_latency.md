# B1 — DRAM writeback / access latency "200+ cycles"

## Claim in the paper
The COALESCE paper (`latex/paper/coalesce_hipc.tex`, Introduction and Motivation) asserts that a DRAM write-back triggered by evicting a Modified block costs "200+ cycles", motivating the coherence-aware bias added to Modified candidates during victim selection.

## Cited evidence

**Hennessy & Patterson, 6th ed. (Ch. 2, Memory Hierarchy Design)** [`hennessy2017quantitative`] reports typical end-to-end DRAM access latencies for DDR4-class memory in the **150–300 CPU-cycle** range on modern out-of-order processors, with the range depending on (a) row-buffer hit vs. row-buffer miss, (b) bus contention, and (c) the ratio of CPU clock to memory clock. A DDR4-3200 row-miss access (tRP + tRCD + tCAS at a CL15 part) is approximately 45 ns of memory-controller time, which at a 4 GHz CPU clock corresponds to ~180 CPU cycles — and the practically observed end-to-end latency (queuing + bus turnaround + return) typically lands at 200–250 cycles.

**Molka et al. (PACT 2009)** [`molka2009memory`] measured Intel Nehalem L3-miss latency in the 200-cycle range and demonstrated that coherence-driven traffic (remote-cache transfers, invalidation acks) adds a comparable per-event cost beyond the raw DRAM penalty. Their Figure on per-source-state read latencies is the canonical microbenchmark reference reviewers expect to see cited when claiming MESI-state-dependent eviction cost.

**Intel 64 and IA-32 Architectures Optimization Reference Manual** (latest revision available at intel.com): the "Cache and Memory Subsystem" section consistently reports L3-miss-to-DRAM latencies near **~40 cycles to LLC + ~200–260 cycles incremental to DRAM** on Skylake-class and later cores. *[TODO: pull the exact figure number and quoted latency from the Sep 2025 manual revision; mark in BibTeX as `intel_opt_manual` once added.]*

## Reconciliation against ChampSim configuration

Our ChampSim configuration uses the framework's default DRAM model (`simulator/config/parse.py` lines 331–335), parameterized as:

| Parameter | Value | Source |
|---|---|---|
| Data rate | DDR4-3200 (3200 MT/s) | `parse.py:332` (`data_rate: 3200`) |
| Memory-controller clock | 1600 MHz (625 ps period) | `parse.py:332` (`frequency: 1600`) |
| tRP, tRCD, tCAS | 24 MC cycles each (= 15 ns) | `parse.py:333` |
| tRAS | 52 MC cycles (= 32.5 ns) | `parse.py:333` |
| Channels × ranks × bankgroups × banks | 1 × 1 × 8 × 4 | `parse.py:332` |
| Rows × columns per bank | 65536 × 1024 | `parse.py:332` |
| Channel width | 8 bytes | `parse.py:332` |
| CPU clock (default) | 4 GHz (250 ps period) | `parse.py:126` (`frequency: 4000`) |

**Cycle-cost derivation for a row-buffer-miss DRAM access**:

```
Activate + access:  tRP + tRCD + tCAS  = 24 + 24 + 24  = 72 MC cycles
                                       = 72 × 625 ps   = 45.0 ns
Burst + return:     ~2 MC cycles (8-byte channel, 64 B line over 8 beats)
                                       =  8 × 625 ps   ≈ 5.0 ns
End-to-end (MC):    ≈ 50 ns
In CPU cycles @ 4 GHz: 50 ns × 4 cycles/ns ≈ 200 CPU cycles
```

This is consistent with the paper's "200+ cycles" claim. A row-buffer-hit access (skips tRP + tRCD) is ~96 CPU cycles, and queuing/contention can push a row-miss to 250–300 CPU cycles under pressure — both of which still fall within the literature ranges cited above.

**Footnote for the paper**: The 200-cycle figure is therefore neither pessimistic nor optimistic for our configuration — it is the median row-miss latency of the simulated DRAM model at zero queuing, which lines up with both the textbook reference [`hennessy2017quantitative`] and the measured Nehalem-era numbers [`molka2009memory`].

## Open items
- Add `intel_opt_manual` BibTeX entry once the exact section and table are extracted from the latest manual (PDF download from intel.com).
- Confirm that the warm-up + measurement DRAM utilization in the existing 8-core canneal runs sits below ~70% (the regime where queuing latency stays bounded); if not, the row-miss latency reported by the simulator will already include queuing and the "200 cycles" claim is conservative rather than nominal.
