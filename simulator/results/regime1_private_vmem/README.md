# Regime 1 — Private VMEM (default ChampSim)

Each CPU has its own physical address space. Two cores accessing the same
virtual address get **different** physical pages — by construction of
`VirtualMemory::va_to_pa` keying on `(cpu_num, vaddr)`.

Consequence: **sharer_count = 1 always**, `LLC COHERENCE INVALIDATIONS = 0`
on every run in this regime. The +20×sharer bias and the A.1/A.2
invalidation hook are inert. COALESCE's wins here come from **PC + MESI
state perceptron prediction under multi-program LLC capacity pressure**.

This is the empirically-verified default behavior of ChampSim, not a bug.

## Headline numbers (canneal)

| cores | sim/core | COALESCE max cycles | best baseline | Δ |
|---|---|---|---|---|
| 4 | 50 M | 0.4996 IPC headline | SHiP 0.5090 (COALESCE 4th of 5; weakness A1) | −1.8 % |
| 8 | 100 M | 415,157,549 | SRRIP 619,411,244 | **+33.0 %** |
| 16 | 100 M | 921,717,448 | LRU 1,175,413,203 / RRIP family ~1,347 M | **+21.6 % / +31.6 %** |

The 8-core headline result is what the paper leads with.

## Sub-directory provenance

| Directory | Sim config | Notes |
|---|---|---|
| `canneal/4core_50M_v0/` | SAMPLING_MODULO=16, GHOST_CAPACITY=256, no Bloom reset | Original V0 design. All 5 policies + random. |
| `canneal/8core_100M_v0/` | V0 | COALESCE + SRRIP only — the original "33 %" result. |
| `canneal/8core_100M_v2/` | SAMPLING_MODULO=32, GHOST_CAPACITY=128, Bloom reset enabled | V2 config — same as production builds today. All 5 policies. Sharer histogram instrumented. |
| `canneal/16core_100M_v2/` | V2 | All 5 policies. `logs/` has the 50M warmup + 100M sim runs. `smoke/` has a short validation run. |

Older COALESCE runs (V0) and the current V2 produce the same headline
number within 0.2 %, confirming the 3.6× metadata-storage shrink cost
nothing on canneal.
