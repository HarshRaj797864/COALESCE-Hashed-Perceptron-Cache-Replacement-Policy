# COALESCE's ghost-tag rescue cannot tell one address from another

**2026-09-23.** Found by reading code the six audit rounds never covered: the
bias was verified, the rescue was not. The rescue is COALESCE's only strong
positive training signal (5x), so this is not a side issue.

## The defect

The code's own comment says the rescue signal is *"this address missed again
after we threw it out"*. The implementation keys it on something else.

`coalesce.cc`, `CompactGhostEntry` and `BloomFilter`:

- The stored partial tag is `tag & 0x3FFF` — the **low** 14 bits of the line
  address. ChampSim's set index is also the low `lg2(NUM_SET)` bits of the line
  address (`cache.cc:541`). The ghost structure is **per set**, so every line it
  ever holds shares those bits. Only `14 − set_bits` bits distinguish lines:

  | geometry | sets | set bits | tag bits that distinguish lines |
  |---|---|---|---|
  | 2 MB fixed | 2048 | 11 | 3 |
  | 4c scaled | 8192 | 13 | 1 |
  | 8c scaled | 16384 | 14 | **0** |
  | 16c scaled | 32768 | 15 | **0** |

- The ghost slot is `(tag ^ pc) % 128`. The low 7 bits of `tag` are set-index
  bits, so **the slot depends on the PC alone** at every geometry.

- The Bloom filter's three hashes are `(tag ^ pc ^ k_i) % 1024`. Taking `% 1024`
  keeps the low 10 bits, and XOR with a constant is a fixed permutation of them,
  so the three positions are **one hash, shifted** — two keys that collide on
  one collide on all three. Those 10 bits of `tag` are set-index bits. **Within a
  set the Bloom filter is keyed on the PC alone.**

So the rescue answers *"did a PC with these low bits evict something in this
set recently?"*, not *"did this address come back?"* — a correct partial tag
would take the bits **above** the set index, `(tag >> set_bits) & 0x3FFF`, which
is also how hardware stores partial tags.

## Proven on an exact replica

`BloomFilter` and `CompactGhostEntry` replicated line for line. PC `P` evicts
line `A` from set `S`; later `P` misses on a **different** line `B` in the same
set. Fraction of 20,000 random trials that report a rescue:

| geometry | false rescue, different line, same PC |
|---|---|
| 2 MB fixed | 12.5% |
| 4c scaled | 50.2% |
| 8c scaled | **100.0%** |
| 16c scaled | **100.0%** |

Controls: the same line coming back rescues; the same line refilled by a
different PC does not. Two different lines in one set set identical Bloom bits
(`[609, 984, 275]` for both).

## The real runs carry the fingerprint

Observed rescue rate, `rescues / ghost_inserts`, canneal shared, scaled sweep:

| geometry | predicted floor | coalesce | no_mesi | no_sharer |
|---|---|---|---|---|
| 4c | 50% | 53.8% | 51.9% | 56.3% |
| 8c | 100% | 92.2% | 94.0% | 90.6% |
| 16c | 100% | 90.1% | 92.8% | 88.5% |

Genuine reuse has no reason to jump from ~54% to ~92% between 4 and 8 cores and
to land just above 50% and just below 100%. The rate is being set by how many
set-index bits eat into the stored tag. (Below 100% at 8c/16c is expected: a
different PC can overwrite the slot, and the Bloom filter resets every 150
inserts.) **The "92% rescue rate" is not evidence that 92% of evicted lines came
back.**

## What it does to training — hypothesis, not measured

`train()` updates only when mispredicted or `|vote| ≤ 35`, so weights do **not**
saturate (an earlier draft of this analysis said they would; checking the rule
showed otherwise). A rescue applies +1 five times whenever the context's vote is
≤ 35; a detrain applies −1 whenever the vote is > 0. With rescues firing on ~92%
of evictions, net training per sampled eviction is about **+3.6** at 8c and
+1.7 at 4c, and a hot PC's context is pushed back up every time it approaches
zero. **It can never go negative**, so the perceptron cannot learn that a hot
PC's lines are dead.

The coherence bias is applied only when `raw_vote > 0`. If that reading is
right, spurious rescues keep the bias switched on precisely for the hot PCs,
and eviction among their lines is decided by the bias — the pinning the bias
probe measured (0.002x at four sharers). The two defects would then be coupled,
not independent. **Untested.** It needs the vote distribution at end of run.

A smaller defect in the same place: the 5x loop computes `vote` once, before the
loop, and passes the same stale value to all five `train()` calls, so the
confidence threshold does not bound the boost once it starts.

## Pre-registered prediction — recorded before the data exists

The sweep launched 2026-09-23 06:44 runs COALESCE at **2 MB fixed**, 4c and 16c,
on the current binary, which reports ghost counters. There, 3 tag bits survive
and the false-rescue floor is 12.5%.

**Prediction: the observed rescue rate at 2 MB fixed lands roughly between 12.5%
and 40%, far below the ~90% at scaled 8c/16c.** The upper bound allows for
genuine returns, which are more likely under 2 MB's heavier pressure. A result
near 90% would refute the defect as the explanation for the high rates.

**Amendment — 2026-09-23, recorded before any of the data below was read.**
The pre-fix 4c and 16c COALESCE-family jobs were **cancelled** before they
started (`scripts/trim_queue.sh`), to bring the post-fix relaunch forward by
about a day. The prediction is instead tested on the three pre-fix
COALESCE-family **8c private** runs of the same sweep, which were running when
this was written: same binary, same **2 MB fixed** geometry, so the same 2048
sets, 3 surviving tag bits and 12.5% false-rescue floor. The prediction is a
property of the set count, not the core count, so the bounds stand unchanged:
**12.5–40%**. What changes is the regime (private) and the core count (8); if
the result lands outside the bounds, that difference is the first thing to
examine, not a reason to move them.

### Result — read 2026-09-24 08:31 UTC

Pre-fix COALESCE family, canneal **8c private, 2 MB fixed** (2048 sets), from
each run's own counters:

| variant | ghost_inserts | ghost_rescues | rescue rate |
|---|---|---|---|
| coalesce | 289,943 | 33,322 | **11.49%** |
| coalesce_no_mesi | 288,212 | 32,992 | **11.45%** |
| coalesce_no_sharer | 290,504 | 33,310 | **11.47%** |

**Against the interval as registered, 12.5–40%: missed, low, by about 1 pp.**
The bounds are not moved.

**Against the refutation criterion, "a result near 90%": not met, decisively.**
The rate collapses from 88.5–94.0% at 16384+ sets (scaled 8c/16c, above) to
11.5% at 2048 sets — the factor of 8 that 3 surviving tag bits predict — so the
geometry, not reuse, is setting the rate. The defect explanation stands.

**Why below 12.5%, and what the registration got wrong.** 12.5% is the
false-rescue rate when the *same PC* refills a different line (the replica
table above). This doc's own scaled results already sit below their floors for
a stated reason — a different PC can overwrite the slot, and the Bloom filter
resets every 150 inserts — at 0.90–0.94 of the floor for 8c and 16c. Here the
rate is 11.47 / 12.5 = **0.92** of the floor: the same shortfall. The lower bound
should have carried it and did not. That is an error in the prediction's
lower bound, recorded rather than repaired after the fact.

Also observed: the three variants agree to within 0.05 pp, against 3–4 pp of
spread between them at the scaled geometries. Noted, not interpreted — the
regime (private) and core count (8) differ from those runs.

## Fix — applied 2026-09-23, to all three variants

Identical in `coalesce`, `coalesce_no_mesi` and `coalesce_no_sharer` — they carry
separate copies of the ghost code (`CNM_*`, `CNS_*`), and fixing only the full
policy would have turned the ablation comparison into a measurement of the fix.

- **Tag.** Both call sites now pass `(line_addr >> 6) >> set_bits`, the address
  bits *above* the set index. `set_bits = ctz(num_sets)`, computed once in the
  constructor, asserting a power of two. That single change makes the 14-bit
  partial tag and the ghost slot carry real address bits.
- **Bloom hashes.** Each of the three positions is now a full 64-bit splitmix64
  mix of `(tag, pc)` with a distinct increment, so they are independent. The
  ghost slot uses the same mixed key.
- **Unchanged:** the 12-bit PC signature, 14-bit partial-tag width, 1024-bit
  filter, 3 hashes, 150-insert reset, 128-entry ghost, 5x boost. Keying on the PC
  is kept — the rescue trains the PC context that made the decision, so requiring
  the same PC is intended. The Bloom and slot now hash the *full* PC where they
  previously saw only its low 7-10 bits, which removes PC aliasing as a side
  effect.
- **Left alone, recorded:** the 5x loop's stale `vote`. `CLAUDE.md` documents the
  boost as "5x repeat" and the code does repeat five times; changing it would be
  a design change, not a defect fix.

### Verified against the real compiled code, both directions

`bench/policy_sanity/coalesce_ghost_probe.cc` links against `coalesce.o` itself,
not a replica. False rescue is a different line in the same set, same PC; true
rescue is the same line coming back, as a positive control. 20,000 trials each:

| sets | pre-fix code, pre-fix calling | fixed code |
|---|---|---|
| 2048 | **12.520%** false, 100% true | **0.000%** false, 100% true |
| 8192 | **49.890%** false, 100% true | **0.000%** false, 100% true |
| 16384 | **100.000%** false, 100% true | **0.000%** false, 100% true |
| 32768 | **100.000%** false, 100% true | **0.000%** false, 100% true |

The pre-fix build **fails** the probe and the fixed build **passes** it — a probe
that passed on both would prove nothing. The pre-fix figures match the replica's
prediction to within sampling noise, so the defect is now confirmed on the real
compiled code, not only on a model of it.

Limitation, stated in the probe: it reimplements the callers' one-line tag
convention rather than driving the real `find_victim` / `replacement_cache_fill`,
which need a live cache. The end-to-end runs cover the call sites.

### End-to-end, real simulator, real trace

The probe cannot drive the real call sites. So both builds were run locally on
`429.mcf`, single core, 2 MB LLC (2048 sets), 10M warmup + 20M simulation.
This is a structural check, not a result: one trace, one short run.

| | pre-fix | fixed |
|---|---|---|
| ghost inserts | 31,434 | 32,894 |
| ghost rescues | 3,919 (**12.47%**) | 2,958 (8.99%) |
| LLC load accesses | 542,065 | 542,061 |
| LLC load hits | 5,290 (**0.98%**) | 83,455 (**15.40%**) |
| IPC | 0.2481 | 0.2610 (**+5.2%**) |

- **The pre-fix rescue rate sits on the predicted 12.5% floor** for 2048 sets,
  now on the real code at the real call sites. (A pure-floor reading is not
  exact: the pre-fix slot was PC-only, so it remembered only the latest eviction
  per PC and also missed genuine returns. The two effects are not separable from
  the rates alone.)
- **The fixed code still rescues** — 2,958 times — so the real call sites pass
  the right tag. This is the coverage the probe states it lacks.
- **The defect was not cosmetic.** The access streams are nearly identical, and
  the load hit rate went from 0.98% to 15.40%. A4's longer server run of the
  pre-fix policy shows the same regime: coalesce 2.74% against LRU's 1.30%, with
  SRRIP at 13.15% and Hawkeye at 19.89%. Run lengths differ, so the fixed figure
  cannot be placed in A4's ranking — that needs the server re-run.

### Which COALESCE findings are now provisional

**All of them.** Each was measured on the pre-fix policy, and the fix plausibly
moves each one:

| finding | where | why it may not survive |
|---|---|---|
| both ablations beat the full policy on single core; `+40` MODIFIED is a dirty-bit preference costing 0.26pp | `a4_results_2026-09-21.md` | all three variants carried the defect, and it interacts differently with each one's features — on mcf the pre-fix variants already spread 2.74% / 6.52% / 9.26% |
| `+20 x sharers` pins lines at 0.002x | bias probe, `verification_2026-09-22.md` round 6 | the coupling hypothesis above: spurious rescues kept votes positive, and the bias applies only to positive votes — with the fix, votes can go negative |
| the COALESCE family fails to convert a larger LLC into fewer translation misses | `coalesce_diagnosis_2026-09-22.md` | same mechanism, downstream of eviction choices |
| COALESCE's rank at every geometry | `coalesce_ranking_2026-09-22.md`, both Phase A sweeps | the policy being ranked has changed |

What does **not** change: the overlay, the other ten policies, the trace and
extraction work, the Phase B semantics analysis, and the existence of the bias
defect itself — the bias arithmetic is independent of the rescue. What changes
is how much damage it does once the perceptron can learn again.

### The invalidation ledger

**The live window.** The defective code dates from the first commit, but it did
nothing until the rescue was wired up in `6963644` on **2026-09-16** — before
that the rescue was dead code, and those results were already void for that
reason. So this defect affects exactly the runs from **2026-09-16 to 2026-09-23**.

**Invalidated as evidence about COALESCE** (valid only as measurements of the
defective implementation):

| results | count |
|---|---|
| A4 COALESCE-family rows | 36 of 132 |
| Phase A COALESCE-family rows | 31 of 148 (`phaseA` 13, `phaseA_scaled` 18) |
| the COALESCE jobs in the sweep launched 2026-09-23 | kept deliberately, to test the pre-registered prediction |

plus every conclusion drawn only from them — see the provisional table above —
and one more: **`check_policy_internals.sh` certified COALESCE's rescue as
working** because `ghost_rescues` was non-zero. It was non-zero *because* of the
defect. A non-zero counter proves a code path runs, not that it computes the
right thing — the same limit as a guard that nobody has tried to fool.

**Not affected.** The defect is in COALESCE's ghost code, which no other policy
uses: the eight baselines everywhere (96 of 132 A4 runs, 117 of 148 Phase A
rows), A4's purpose as baseline validation and its reuse finding, the overlay
validation (LRU only), traces, extraction, the guards, determinism, the Phase B
semantics analysis, the Hawkeye verification, and the cross-regime experiment
now running, whose question is about the baselines.

**Conclusions that mixed COALESCE rows with baseline rows** — recomputed with the
COALESCE family removed. All four survive:

| conclusion | with COALESCE | baselines only | survives? |
|---|---|---|---|
| the scaled geometry removes the replacement problem (canneal hit-rate spread, 4c / 8c / 16c) | 19.90 / 6.28 / 1.65 pp | 14.27 / 6.28 / **0.67** pp | yes — stronger at 16c |
| a multi-way tie at 2 MB canneal 8c | six within 0.74% | **four** within 0.55% (srrip, mockingjay, srrip_bias, hawkeye), then drrip at +4.49% | yes, as a four-way tie |
| core divergence on water is policy-dependent | up to 1.26x | 1.09x (lru) to **1.26x** (mockingjay) | yes, unchanged — the water margin stands |
| gain over LRU tracks pressure for every policy (refuting R1) | — | srrip +0.89, hawkeye +0.96, mockingjay +0.89, ship +0.93, drrip +0.86 | yes — it never depended on COALESCE |

### Consequences

- **Every COALESCE result predating this fix measures a policy whose rescue was
  PC-only**, including all three variants in both Phase A sweeps and A4.
- **The server is untouched.** The sweep launched this morning runs the pre-fix
  binary, so its COALESCE rows describe the pre-fix policy — which keeps the
  pre-registered 2 MB prediction above testable. The fix deploys when the sweep
  drains, and the COALESCE family then needs its own re-run.
- The other ten policies are unaffected.
