# Our policies index unchecked; upstream's do not

**2026-09-19**, found while investigating a SIGSEGV in `mockingjay` on
`ocean 8c shared` (rc=139 after 621 minutes, 1 failure in 44 runs).

| policy | `.at()` | bare `[]` | author |
|---|---|---|---|
| lru | 2 | 0 | upstream |
| srrip | 3 | 0 | upstream |
| drrip | 1 | 0 | upstream |
| ship | 1 | 0 | upstream |
| random | 0 | 0 | upstream |
| hawkeye | 0 | **3** | ours |
| **mockingjay** | 0 | **28** | ours |
| coalesce | 0 | **8** | ours |
| coalesce_no_mesi | 0 | **8** | ours |
| coalesce_no_sharer | 0 | **8** | ours |
| srrip_bias | 1 | 1 | ours |

The split is exact: every policy upstream wrote uses bounds-checked `.at()`,
every policy we rewrote uses bare `operator[]`.

## Why it matters

`std::vector::at()` throws `std::out_of_range`. `operator[]` is undefined
behaviour: it may corrupt neighbouring memory silently, or fault much later,
depending on heap layout. So an indexing bug in an upstream policy fails
immediately and legibly, and the same bug in ours fails as a segfault ten hours
into a run -- or does not fail at all, and quietly returns wrong numbers.

The observed crash fits that shape. `mockingjay` has 28 unchecked sites, ran 621
minutes, and died mid-write with no core file. Six other policies on the *same*
wrapped ocean traces completed, and mockingjay itself completes on canneal,
water and barnes. One policy, one workload, one failure in 44.

## Not yet the root cause

This explains why a bug in our policies presents as a segfault rather than an
exception. It does not identify which index was wrong. Attempts to reproduce:

- single core, 4 wraps, mockingjay -- no crash
- 8 cores, shared, 64 wraps, mockingjay -- no crash, but `victims 0 bypasses 0`:
  the working set fit in the LLC, so `find_victim` never ran and the eviction
  path was never exercised. A repro has to force evictions.

An AddressSanitizer build is the next step, because it reports the first
out-of-bounds access whether or not that access happens to fault.

## Recommendation

Convert the rewritten policies to `.at()`. The cost is negligible against
simulation time, and it converts latent undefined behaviour into a loud,
diagnosable failure. It cannot change results unless an out-of-bounds access is
actually occurring -- in which case we need to know.
