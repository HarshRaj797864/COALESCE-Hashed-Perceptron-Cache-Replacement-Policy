# ChampSim Configuration Used in COALESCE Evaluation

> **Status**: Day 1 skeleton — populated from `simulator/btp_config.json`, `simulator/btp_8core_config.json`, and `simulator/config/parse.py` (ChampSim defaults). Items marked `[TODO]` need verification before paper submission.

## Version
- ChampSim git commit: `[TODO: run "cd simulator && git log -1 --oneline" once we know which upstream commit this branch was forked from]`
- Branch / fork status: this is a modified ChampSim with COALESCE-specific extensions to `block.h` (MESI_State enum, `sharer_mask`) and the new `replacement/coalesce/` module.
- Build flags: vcpkg-installed CLI11, LZMA, Bzip2, fmt; `make` with framework defaults — `[TODO: confirm -O3 -DNDEBUG by inspecting the generated Makefile]`

## Core (ChampSim defaults via `simulator/config/parse.py`)
- CPU clock frequency: **4 GHz** (250 ps period) — `parse.py:126`
- ROB size, LSQ entries, branch predictor: ChampSim defaults — `[TODO: dump the full core config after a build and paste here]`

## L1 caches (from `btp_config.json` / `btp_8core_config.json`)
- L1I: 64 sets × 8 ways × 64 B = **32 KB**, 4-cycle access, LRU replacement, no prefetcher
- L1D: 64 sets × 8 ways × 64 B = **32 KB**, 4-cycle access, LRU replacement, no prefetcher

## L2 cache
- L2C: 1024 sets × 8 ways × 64 B = **512 KB per core**, 10-cycle access, LRU replacement, no prefetcher

## L3 / LLC (the policy under test)
- All configs: **2 MB** total (2048 sets × 16 ways × 64 B), **20-cycle** access, no prefetcher
- 4-core config (`btp_config.json`): shared 2 MB LLC, COALESCE replacement
- 8-core config (`btp_8core_config.json`): shared 2 MB LLC, COALESCE replacement
- Replacement options exposed: `coalesce | lru | srrip | drrip | ship | random` (subdirectories under `simulator/replacement/`)

> *Note (weakness flag)*: 2 MB shared LLC for 8 cores is **256 KB per core**, which is small by 2026-era standards (typical commercial 8-core parts have 8–16 MB LLC). This is consistent with the LLC-size-sensitivity sweep in Phase 2C — the small LLC is part of *why* COALESCE wins at 8-core canneal (high LLC pressure exposes coherence-aware behaviour). For the paper's external validity, report results across 1 / 2 / 4 / 8 MB LLC sizes so readers can extrapolate.

## DRAM (ChampSim defaults via `simulator/config/parse.py:331–335`)
- DRAM model: **DDR4-3200** (`data_rate = 3200`)
- Memory-controller clock: **1600 MHz** (625 ps period)
- Channels × ranks × bankgroups × banks: **1 × 1 × 8 × 4**
- Rows × columns per bank: **65536 × 1024**
- Channel width: **8 bytes** (so a 64 B line is an 8-beat burst)
- Read / write queue: 64 / 64 entries per channel
- **tRP = tRCD = tCAS = 24 MC cycles** (= 15 ns each)
- **tRAS = 52 MC cycles** (= 32.5 ns)
- Refresh period: 32 µs, 8192 refreshes/period
- Derived row-buffer-miss latency: ≈ 72 MC cycles = 45 ns ≈ **180 CPU cycles** at 4 GHz (+ bus turnaround / queuing → ~200 cycles end-to-end)
- See `coalesce_paper/citations/justifications/B1_dram_latency.md` for the full derivation and citations.

## Warmup / measurement
- 4-core (`btp_config.json` runs): **200 M warmup instructions per core**, **50 M measurement instructions per core**
- 8-core (`btp_8core_config.json` runs): **1 B warmup instructions per core**, **100 M measurement instructions per core**
- (Per `README.md` build/run examples and the run logs under `simulator/results/canneal_*/`)

## Coherence (COALESCE extension)
- Directory-style MESI added on top of ChampSim's stock LLC. Block-level state is encoded in `simulator/inc/block.h`:
  - `enum MESI_State { INVALID, SHARED, EXCLUSIVE, MODIFIED }` (2 bits)
  - `uint8_t sharer_mask` — bitmask of sharing cores (supports up to 8 cores at this width)
- Sharer count used by the perceptron is `popcount(sharer_mask)` decoded inline (`coalesce.cc:107–110, 130–132, 150–153`).
- See [`COHERENCE_HOOK_AUDIT.md`](COHERENCE_HOOK_AUDIT.md) for the audit of which coherence events reach the COALESCE training path.

## COALESCE storage (V2 config, 2026-05-21)
- `PERCEPTRON_TABLE_SIZE = 2048` (2 tables × 8-bit signed weights = 4 KB total)
- `BLOOM_SIZE = 1024` bits (128 B per sampled set)
- `BLOOM_RESET_THRESHOLD = 150` (added 2026-05-21 to bound FP rate)
- `GHOST_CAPACITY = 128` entries × 32-bit packed = 512 B per sampled set
- `SAMPLING_MODULO = 32` → 64 sampled sets out of 2048
- **Total metadata**: 4 KB weights + 64 × (128 B + 512 B) = 4 KB + ~40 KB ghost ≈ **44 KB total** (~2.1 % of 2 MB LLC)

## Workload
- PARSEC `canneal` (Bienia et al., PACT 2008) traces, generated via Intel PIN 3.31 with the MT-Sync tracer in `simulator/tracer/`.
- Trace files: `simulator/traces/canneal_big{0..4}.champsimtrace` (306 MB each, gitignored).
- *[TODO: document the exact PARSEC commit / input size used for trace generation, and whether `fluidanimate` and `dedup` traces exist yet on the experimental server.]*

## Open items to lock before paper submission
1. ChampSim upstream commit / version string for reproducibility.
2. Exact ROB / LSQ / branch-predictor parameters (dump from a build run).
3. Confirm `-O3 -DNDEBUG` in the actual compile.
4. Determine whether the coherence-event hook covers invalidations or only writebacks; if writeback-only, frame that explicitly as a limitation in the paper.
5. PARSEC version and input-size documentation.
