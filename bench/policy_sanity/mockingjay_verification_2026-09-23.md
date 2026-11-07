# Mockingjay port — verified line by line against the authors' artifact

**2026-09-23.** Same method as `hawkeye_verification_2026-09-23.md`. The port
names the authors' own release, `github.com/ishanashah/Mockingjay`, file
`mockingjay.llc_repl`, and cites artifact line numbers throughout. Fetched fresh.
The code file was last changed **2021-12-21** (commit `3f8a23c71f6a`; the
repository head `daa47f03c113` is a licence update), so the port's line
citations refer to the same text — the first one checked, lines 49-56 as the
3-round `CRC_HASH`, is exact.

## Equivalent, statement for statement

| artifact | port | verdict |
|---|---|---|
| constants and derived widths (`:7-25`) — `LOG2_SAMPLED_SETS`, `INF_RD`, `INF_ETR`, `MAX_RD`, `SAMPLED_CACHE_TAG_BITS`, `PC_SIGNATURE_BITS`, `FLEXMIN_PENALTY` | computed at construction from the real geometry | ✓ |
| `is_sampled_set` (`:44-48`) | identical | ✓ |
| `CRC_HASH`, 3 rounds (`:50-57`) | identical | ✓ |
| `get_pc_signature` (`:59-82`) | identical, including the 2-bit core field — see below | ✓ |
| sampled-cache index and tag (`:84-94`) | identical | ✓ |
| `search_sampled_cache`, `detrain` (`:96-118`) | identical, plus guards | ✓ |
| initialisation (`:122-138`) | identical | ✓ |
| `find_victim`: largest `|Etr|`, ties to negative, bypass rule (`:144-174`) | identical; `WRITE` maps to `WRITEBACK` | ✓ |
| `temporal_difference` with its int truncation to a step of 0 or 1 (`:177-191`) | identical | ✓ |
| timestamps (`:193-205`) | identical | ✓ |
| update: writeback early-return, signature, sampled-set training with the `FLEXMIN` penalty, LRU displacement with detrain, once-per-8 ageing, Etr assignment (`:209-309`) | identical | ✓ |

The port's additions are guards that never fire in normal operation:
`find()` where the artifact uses `operator[]` on `sampled_cache` (which would
insert a null pointer for an unallocated index — the index is always allocated,
because it is derived from the same set bits as `set`), `way < 0` in `detrain`,
and `way < NUM_WAY` on the writeback path, where the artifact already forbids a
writeback from bypassing.

Type differences are inert: `rdp` keyed on `uint64_t` where the artifact uses
`uint32_t`, but signatures are at most `PC_SIGNATURE_BITS` (11 at 2 MB) wide.

Not in the artifact, handled as a demand access: `access_type::TRANSLATION`,
which the CRC2-era simulator did not have.

## Finding: the core field is 2 bits, sized for CRC2's 4 cores

Artifact `:76-77`, reproduced exactly by the port:

```cpp
pc = pc << 2;
pc = pc | core;
```

Two bits hold the core ID. Counting, over real accesses only — our configs run
no LLC prefetcher, so the prefetch bit is always 0:

| cores | accesses whose signature equals another core's at the same PC |
|---|---|
| 4 | **0%** — the artifact's design point |
| 8 | **0%** — but only because cores 4-7 set bit 2, the prefetch bit, which nothing else uses here. Enabling an LLC prefetcher would break it. |
| 16 | **50.3%** — at every odd PC, cores `[0,8] [1,9] [2,10] [3,11] [4,12] [5,13] [6,14] [7,15]` are indistinguishable; at even PCs, core `c+8` lands on core `c`'s signature for `pc+1` |

So at 16 cores Mockingjay's per-core reuse-distance separation is **halved**. It
is a faithful copy of the artifact, not a porting slip — but the artifact was
written for 4 cores ("unified singlecore and multicore mockingjay", its own
commit `6f5f942`), and the Hawkeye port already generalises the equivalent
CRC2-era constant (`5*NUM_CORE` to `5*NUM_CPUS`).

### Decision, 2026-09-23: keep it artifact-literal

The owner chose to keep the 2-bit field exactly as the authors wrote it rather
than widen it to `ceil(log2(NUM_CPUS))` bits. No code change and no re-runs. The
methodology must therefore state that **at 16 cores, pairs of cores share
Mockingjay's reuse-distance predictions at every odd PC**, and that 8 cores are
unaffected only because no LLC prefetcher is configured.

## The ocean 8c segfault — not root-caused

rc=139 on `phaseA` ocean 8c shared, 2026-09-17. What can be established locally:

- The version in force then, `dd41d5a`, already had every past-the-end guard the
  current code has (`if (!hit)`, `way < NUM_WAY` on both write paths). A missing
  guard does not explain it.
- That run, `random` and `srrip_bias` on the same config all stopped at
  essentially the same point (~62.81M instructions consumed by the fastest core,
  `wrap_diagnosis_2026-09-21.txt`). `random` cannot plausibly segfault in policy
  code, which points at one external event for all three — against which stands
  the specific rc=139.
- All three ran on the pre-regeneration 45.3M-record ocean traces, and wrapped.
- Since `eddcb19` (09-19) every index is `.at()`, so an out-of-bounds access now
  aborts with a message instead of corrupting memory. No Mockingjay run has
  failed since, and ocean is out of every planned experiment.

The server's driver log for that run would settle the external-event question.
