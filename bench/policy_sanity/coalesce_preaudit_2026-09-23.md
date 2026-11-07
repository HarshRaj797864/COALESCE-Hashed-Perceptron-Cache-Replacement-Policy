# COALESCE pre-relaunch audit

**2026-09-23.** Everything in COALESCE not covered by the bias check or the
ghost fix, read before the relaunch so the family is re-run once, not twice.

## Fixed: the ablations changed two things, not one

Each ablation is meant to be the full policy minus one feature. Each also
swapped in extra PC bits where the feature had been:

| table | `coalesce` | ablation, before |
|---|---|---|
| `table0` | `pc ^ c0 ^ (state << 8)` | no_mesi: `pc ^ c0 ^ (pc >> 11)` |
| `table1` | `pc ^ c1 ^ (sharers << 4)` | no_sharer: `pc ^ c1 ^ (pc >> 13)` |

Folding in upper PC bits separates PCs that the full policy lets alias, so each
ablation also had a **different, less-aliased PC hash**. A4's "both ablations beat
the full policy" could therefore not be attributed to the removed feature.

Fixed so each ablation is the full policy with the feature's term at zero.
`bench/policy_sanity/coalesce_ablation_probe.cc` links all three real policy
objects and compares every hash over 200,000 random inputs:

| comparison | before | after |
|---|---|---|
| no_mesi `table0` vs full `get_hash0(pc, INVALID)` | 199,893 differ | **0** |
| no_sharer `table1` vs full `get_hash1(pc, 0)` | 199,899 differ | **0** |
| the untouched table in each ablation | 0 | 0 |

The untouched tables already matched, so these two lines were the whole
confound. Everything else was already identical across the three: every
constant, the training rule, the initial weights, the sampling and the 5x boost.

## Fixed (decision: allocating PC): hit training credited a different PC

| path | PC it uses |
|---|---|
| `find_victim` scoring a line | the line's **allocating** PC (`current_set[w].ip`) |
| detrain on eviction | the line's allocating PC |
| rescue on refill | the refilling PC, required to match the allocating PC |
| **hit training** | **the PC that hit** (`ip_val`) |

`block_meta.ip` is set at fill (`cache.cc:110`) and never updated, and
`cache.cc` says it is carried "so a replacement policy can recover the context
that brought the line in". The hit path reads the block's state and sharers but
not its PC — so it trains a context `(hitting PC, the line's state)` that no
eviction decision ever consults.

**Measured**, `429.mcf`, 2M + 6M, temporary counter in a local build (not
committed):

| LLC hits | 23,564 |
|---|---|
| hit by the PC that allocated the line | 1.6% |
| line allocated by a writeback (PC 0) | 1.9% |
| **hit by a different, non-zero PC** | **96.6%** |
| distinct allocating / hitting PCs | 18 / 12 |

PC 0 is ruled out as the cause. mcf is pointer-chasing: one instruction loads a
node, others read its other fields. So ~97% of COALESCE's positive hit signal
reaches a context other than the one that decides whether that line survives.

Two self-consistent resolutions:

- **(A) allocating-PC context, SHiP-style.** Hit training uses `block_meta.ip`.
  One line in each of the three variants, and it makes the hit path agree with
  scoring, detraining and the rescue.
- **(B) last-access context, as in perceptron reuse predictors.** Train the stored
  context on a hit, then update the line's PC to the hitting one. That changes
  what `block.ip` means for every consumer and needs a `cache.cc` change.

**Decided 2026-09-23: (A).** All three variants now train `block_meta.ip` on a
hit; the three hit paths are identical apart from their feature arguments. The
rescue path is unchanged by this commit. Probes and guards pass.

## Fixed (decision: address key): the rescue required the same PC

With the allocating PC as the context, the rescue's condition was inconsistent.
The ghost was keyed on `(tag, pc)`, so it fired only when the **same** PC brought
an evicted line back — while the comment above it defines the rescue by the
*line*: "If the incoming line carries a ghost tag then we evicted it too early."

**Measured**, `429.mcf`, 2M + 6M, temporary counter (not committed): of 1,402
evicted lines that came back in sampled sets, **413 (29.5%)** returned via the
allocating PC and were rescued; **989 (70.5%)** returned via a different PC and
were not — although **all 1,402 came back within 150 evictions**, inside the
ghost window. So the window was never the limit; the PC condition was.

This reverses a claim in the ghost-fix commit `97aa5da`, that PC keying was kept
"on purpose — the rescue trains the PC context that made the decision". That
reasoning assumed the trained context was the *refilling* PC. Once the context
is the allocating PC, it no longer holds.

**Fix, identical in all three variants:** the ghost is keyed on the line address
alone. The victim's allocating PC is still stored in the entry, `lookup()` now
returns it, and the rescue trains that stored PC instead of the refilling one.

**Why training a 12-bit signature is exact:** every perceptron hash reads only
the PC's low 11 bits. `coalesce_ablation_probe.cc` checks all six hashes against
`pc & 0xFFF` over 200,000 PCs — zero differ — with a control, the removed
`(pc^c0)^(pc>>11)` no_mesi hash, which differs on 199,810. The ablation fix above
was therefore a **precondition** for this one: under the old no_mesi hash the
rescue would have trained entries the scoring path never reads.

**The ghost probe, rewritten for these semantics** — and made to test the partial
tag directly. Once the Bloom filter mixes the full tag, a single-entry filter
rejects a different line on the Bloom check alone, so an end-to-end test could no
longer see the caller's tag convention; a caller reverted to the full line
address would still have passed. Results, correct caller vs the pre-fix caller
convention against the same object:

| test | correct caller | pre-fix caller |
|---|---|---|
| partial-tag collisions, 2048 / 8192 / 16384 / 32768 sets | 0.0065 / 0.0050 / 0.0075 / 0.0055% (floor 0.0061%) | **12.49 / 50.07 / 100 / 100%** |
| loaded filter, 150 inserted, absent lines | 0.000% | **0.465%** |
| rescue returns the stored allocating PC | 100% | — |

The loaded-filter cut started at 0.5%, which passed the defect at 0.465%; it is
now 0.05%. The pre-fix convention fails five checks through two independent
paths.

## The fixes, end to end: correct per the design is not the same as better

All four builds on `429.mcf`, single core, 2 MB LLC, 10M warmup + 20M simulation,
local, deterministic, one run each:

| build | rescues | rate | LLC load hit | IPC | vs pre-fix |
|---|---|---|---|---|---|
| pre-fix (as run on the server) | 3,919 | 12.47% | 0.98% | 0.2481 | — |
| + ghost-tag fix `97aa5da` | 2,958 | 8.99% | **15.40%** | 0.2610 | **+5.20%** |
| + hit training on the allocating PC `5beb7a8` | 3,350 | 9.42% | **0.39%** | 0.2485 | +0.16% |
| + rescue keyed on the address `8de8c42` | 8,528 | 28.00% | 1.44% | 0.2481 | +0.00% |

Each fix removes a demonstrated inconsistency between what the code did and what
its own design says. Together they return COALESCE on this trace to exactly its
pre-fix IPC, and the hit-training change — decided on consistency grounds before
any end-to-end number existed — is the one that erases the ghost fix's gain.
**Being internally consistent did not make the policy better here.**

What that does and does not show. One trace, single core, one short run, so it
cannot say which version is better in general — and COALESCE's design targets
multi-core sharing, which mcf has none of. At 2M + 6M neither build does well
(below), so the ghost-fix build's 15.40% is a longer-warmup effect that a single
run cannot distinguish from a favourable phase.

### A hypothesis tested and refuted: vote ties

`find_victim` takes the first way with the lowest vote (strict `<`), so tied votes
go to the lowest-numbered way. The hypothesis was that the consistency fixes made
votes tie. Measured with a temporary probe, 2M + 6M:

| build | evictions | min vote tied | all 16 ways equal | victim way 0 / way 15 | LLC load hit |
|---|---|---|---|---|---|
| ghost fix only | 148,053 | **50.4%** | 0.8% | 13.4% / 3.2% | 0.62% |
| all three fixes | 140,457 | **29.7%** | 0.0% | 13.2% / 3.7% | 0.22% |

Ties are frequent in **both**, and more so in the build that did better, with the
same skew toward low way numbers in both (uniform would be 6.25% per way). Ties do
not explain the difference. They are a real, pre-existing property of COALESCE
recorded below.

## Recorded, not changed

- **Perceptron hashes are weak, not broken.** Both are `(pc ^ c) ^ feature`, then
  `% 2048`, so the feature aliases with PC bits 8-9 or 4-8. Unlike the ghost
  defect, no input has constant low bits here — the table is global and PCs vary
  — so for a fixed PC every feature value reaches a distinct entry.
- **`VETO_OVERRIDE = -100`** is defined in `coalesce.h` and never used. A leftover
  that could suggest a veto mechanism exists; it does not.
- **The 5x loop's stale `vote`**, recorded with the ghost fix.
- **COALESCE has no tie-breaker.** It carries no recency or ageing state, so when
  the perceptron and bias give several ways the same vote, the lowest way index
  wins. On mcf 30-50% of evictions are decided that way, evicting way 0 about
  twice as often as a uniform choice would. A design gap, not a defect in the
  code as written; under the freeze it is recorded, not changed.
