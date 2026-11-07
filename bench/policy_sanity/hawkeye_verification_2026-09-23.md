# Hawkeye port — verified line by line against the reference artifact

**2026-09-23.** Until now the Hawkeye rewrite was supported by *behaviour* —
A4 shows it distinct from SRRIP on every discriminating trace and ordered
correctly against SHiP and Mockingjay — and by the rewrite's own claim to fix
thirteen deviations. It had never been read against the artifact it ports.

## Method

The reference named in the rewrite plan, fetched fresh:
`github.com/hyerania/Belady-Cache-Replacement`, commit **`f960a5d355f0`**
(2019-04-25): `hawkeye_algorithm.cc`, `hawkeye_predictor.h`, `optgen.h`,
`helper_function.h`. Every function compared against `hawkeye.{h,cc}`.

This was deliberately **not** done from memory, and that mattered: recalled from
memory, the artifact clears the prefetch bit *before* its writeback early-return.
It does not — `hawkeye_algorithm.cc:123` returns first, exactly as the port does.
Checking against recollection would have reported a deviation that does not
exist.

## The thirteen defects the rewrite claimed to fix — all confirmed fixed

| # | aspect | artifact | port | verdict |
|---|---|---|---|---|
| H1 | insertion hook | one hook, hit and fill | `replacement_cache_fill` + `update_replacement_state` → `handle_access`, with `if (!hit) return;` | equivalent |
| H2 | eviction detraining | `GetVictimInSet:95-102`, only on the `>=` path, only in sampled sets | same | ✓ |
| H3 | ageing | on miss, friendly only, guarded by `isMaxVal` (`:244-258`) | same, including the set-0 / age / set-0 sequence | ✓ |
| H4 | hit behaviour | friendly → RRIP 0, no ageing | same | ✓ |
| H5 | victim selection | MAXRRIP scan, else last max via `>=` (`:77-91`) | same | ✓ |
| H6 | writebacks | return before any state change (`:123`) | same, same order | ✓ |
| H7 | OPTgen capacity | `LLC_WAYS - 2` (`:58`) | `NUM_WAY - 2` | ✓ |
| H8 | predictor | 2048 entries, max 31, lazy init 16, friendly if ≥ 16 | pre-filled to 16 | equivalent (get / increase / decrease each checked) |
| H9 | predictor count | demand + prefetch | same | ✓ |
| H10 | PC hash | 32-round CRC, poly `0xEDB88320` | identical | ✓ |
| H11 | sampler | 2800 entries, 8 per set, 350 sets; tag `CRC(paddr>>12)%256`, set `(paddr>>6)%350`; explicit LRU | same | ✓ |
| H12 | timer | per set, wraps at 1024, wrap detected before OPTgen | same | ✓ |
| H13 | multi-core | one global predictor pair, shared | members of the single LLC module | ✓ |

`OPTgen::is_cache`, `set_access`, `set_prefetch` and `update_cache_history` are
statement-for-statement identical.

**Deliberate adaptations, each confirmed harmless:**

- The prefetch-interval test is `5 * NUM_CPUS`; the artifact's is `5*NUM_CORE`
  with `NUM_CORE` hard-defined to 1 (`:8`). The port generalises to the real core
  count. Inert here: both configs run no LLC prefetcher.
- `uint64_t` where the artifact uses `unsigned int` for `current_time` and the
  OPTgen walk; values never exceed 2048.
- `assign` where OPTgen used `resize`; equivalent for a single initialisation.
- The artifact's `HISTORY` carries an unused `address` field; dropped.
- A guard for caches under 64 sets, where the artifact's shift would be negative.

## Finding: it samples 32 sets at 2 MB, not 64

The artifact's comment says `SAMPLED_SET` samples *"64 sets for each core"*; the
port's comment said "64 sampled sets"; the rewrite plan said it "yields the
intended 64 sampled sets at every core count". All three are wrong.

The formula compares bits `[0,6)` with bits `[log2(sets)-6, log2(sets))`. At
2048 sets the second field starts at bit 5, so the fields **overlap at bit 5**
and only 32 sets satisfy it. Counted exactly with the artifact's formula:

| LLC sets | our geometry | sampled sets |
|---|---|---|
| 2048 | 2 MB fixed, any core count | **32** |
| 8192 | 4c scaled | 128 |
| 16384 | 8c scaled | 256 |
| 32768 | 16c scaled | 512 |

The port **reproduces the artifact's behaviour exactly** — the reference samples
32 sets at its own 2048-set default — so the formula is deliberately unchanged
and only the comment is corrected. Changing it would make Hawkeye diverge from the
published artifact.

What it means for this project: Hawkeye's training rate differs **16x** across
the geometries we run, and at 2 MB fixed the same 32 sets serve 4, 8 or 16 cores
of interleaved traffic. That is a confound for any cross-geometry comparison of
Hawkeye in particular, and belongs in the methodology section.

## Finding: CRC2's own LLC is 2 MB per core

`hawkeye_algorithm.cc:9` is `#define LLC_SETS NUM_CORE*2048`. The configuration
Hawkeye was designed, tuned and published under scales the LLC at 2 MB per core
— exactly this project's "scaled" geometry. That is an argument for the scaled
geometry when the question is whether the *baselines* are being run fairly, set
against the finding that at 16 cores it leaves replacement almost nothing to
decide.

## What remains unverified

The reference is a course-project reimplementation, not the authors' own
release. It `#include`s `champsim_crc2.h` and every constant matches Table 1 of
the CRC2 paper, and the plan flagged this provenance when the rewrite was made.
A comparison against the official CRC2 submission would be stronger still. The
runtime side is covered by A4: distinct from SRRIP, and ordered correctly against
SHiP and Mockingjay.
