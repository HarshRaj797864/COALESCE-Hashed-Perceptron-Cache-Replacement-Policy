# Verification audit — every claim made on 2026-09-22

> **COALESCE rows measured on the pre-fix policy** (added 2026-09-23). COALESCE's
> ghost-tag rescue could not tell one address from another until `97aa5da`;
> every COALESCE-family figure below predates that fix and is provisional until
> re-run. The other policies' rows are unaffected. See
> `coalesce_ghost_defect_2026-09-23.md`, "Which COALESCE findings are now
> provisional".

Re-derived from `phasea_rows_v4.txt` and `a4_rows_2026-09-21.txt`. No summary
was an input. Three claims are refuted, two overstated, seven hold.

## HOLDS

**V1 — `phaseA` is one binary.** Mixed binaries would void its ranking. No
policy is split between instrumented and not: hawkeye 4/4 with stats,
mockingjay 3/3 with, coalesce 9/9 without. Instrumentation landed hawkeye
`66cbfa1` (09-16), mockingjay `b6363d7` (09-15), coalesce `0cf55c4` (09-19), so
a single binary built between 09-16 and 09-19 produces exactly this pattern.
(My first test of this reported FAIL because it assumed all policies were
instrumented at once. The test was wrong, not the data.)

**V2 — run lengths are comparable across sweeps.** Per-core retired
instructions are 100.5M–101.1M in every configuration of both sweeps. Cross-sweep
comparison is legitimate.

**V3 — the geometries are what they claim.** LRU load hit rate is flat across
core counts in `phaseA` (23.65 / 23.95 / 24.80% at 4/8/16c) and rises in
`phaseA_scaled` (67.65 / 86.81 / 97.74%). A fixed cache and a growing one.

**V6 — the overlay validates, more strongly than reported.** All 18
private-regime rows have *exactly* zero aliased fills and zero invalidations.
Aliased fills are near-identical across the two geometries — 384,382 vs 384,915
at 4c, 907,595 vs 908,558 at 8c, 1,981,417 vs 1,982,046 at 16c — i.e. the
overlay produces the same aliasing regardless of cache size, as it must.
Invalidations do scale with cache size (157,033 vs 556,804 at 4c), which is
expected: bigger cache, lines resident longer, more chances to be invalidated.
The committed doc quoted only the scaled invalidation column; the aliased-fill
agreement is the better evidence.

**V9 — every private run is LRU.** 18 private rows, all LRU. The tool has no
cross-regime policy comparison.

**V10 — the A4 findings reproduce exactly.** ship 1.51x/0.99x, hawkeye
2.35x/1.92x, mockingjay 2.25x/1.71x on the low/high pressure split; the reuse
correlations unchanged.

**V7b — the COALESCE family does not benefit from a larger LLC for translation
lines.** Growing the LLC 8x (2 MB to 16 MB at 8 cores), translation misses per
KI improve by:

    drrip 1586x   hawkeye 216x   mockingjay 163x   lru 96x   ship 73x
    srrip 23x     srrip_bias 10x   random 8x
    coalesce_no_mesi 3x   coalesce_no_sharer 3x   coalesce 2x

A clean gap between the COALESCE family (2–3x) and everything else (8x+). The
ordering within the family tracks total bias magnitude: the full policy, which
carries both bias terms, is worst. Both ablations retain one term each
(`no_mesi` keeps `+20 x sharers`, `no_sharer` keeps `+40`), so the mechanism
predicts all three are affected, and they are.

## REFUTED

**R1 — "COALESCE's gain correlates with capacity pressure (rho +0.64), so its
advantage comes from pressure, not coherence."** Every policy shows a strong
positive correlation on that metric: hawkeye +0.96, ship +0.93, srrip +0.89,
mockingjay +0.89, drrip +0.86. **COALESCE has the lowest of any real policy.**
The correlation is a property of *gain over LRU*: at high pressure LRU is
terrible (23.95% hit rate) so everything beats it by a lot. On a metric not
anchored to LRU — gap to the best policy in that configuration — COALESCE is
rho +0.00, no relationship at all. The conclusion does not follow from the
evidence given.

**R2 — "TRANSLATION misses are 7.4x/14.5x the best policy."** The ratio is
unstable because the denominator is whichever policy happens to be lowest
(DRRIP at 0.0004/KI). At 2 MB fixed, COALESCE's translation miss rate (0.6357)
is indistinguishable from LRU's (0.6380), SHiP's (0.6391) and DRRIP's (0.6374)
— every policy is ~0.63 because a 2 MB cache evicts everything. COALESCE is not
an outlier there. V7b is the stable restatement.

**R3 — "srrip_bias corroborates the mechanism; every coherence-biased policy
shows it."** srrip_bias improves 10x and random improves 8x — srrip_bias sits
next to *random*, not next to COALESCE. It is also a different base policy with
a different bias form (an eviction veto on RRIP, not an additive vote), so it
was never a controlled comparison.

## OVERSTATED

**O1 — "COALESCE is the best policy of eleven at 2 MB, +12.82% over LRU."**
True as stated and misleading. Six of eleven policies sit within **0.74%** of
first, and COALESCE leads SRRIP by **0.12%** and Mockingjay by 0.12%. The
honest description is a six-way tie — {coalesce, srrip, mockingjay, srrip_bias,
hawkeye, coalesce_no_mesi} at 204.5–206.0M cycles — with a real gap below it to
drrip (+3.84%), ship, and LRU (+12.82%). COALESCE is nominally first within the
tie. ChampSim is deterministic, so the ordering is real rather than noise, but a
0.12% margin will not survive any change of configuration and is not a
performance claim.

**O2 — "the scaled geometry ranking is meaningful at 16 cores."** Already
flagged as noise in the committed doc, and the audit confirms it: 9 of 11
policies are within 1% of first. Worth restating because the COALESCE "10/11"
figure has been quoted from it.

## What survives about COALESCE

- At 2 MB fixed canneal 8c it is in the leading six-way tie. **(O1)**
- At 2 MB/core canneal 4c and 8c it is clearly outside the leading group,
  +3.52% and +3.00% behind the winner, with 4 and 6 policies respectively
  inside 1% of first. This separation is real.
- Its family uniquely fails to convert a larger LLC into fewer translation
  misses. **(V7b)**
- Why that happens is **not established**. The bias is the suspect and the
  arithmetic is suggestive (`+20 x sharers` reaches +320 at 16 sharers against a
  perceptron range of about [-256, +254]), but no variant with the bias removed
  entirely exists, so the causal step is untested. The running bias probe tests
  a different link in the chain — whether victims are disproportionately
  unbiased lines — not this one.

## Corrected experiment list

1. A **no-bias variant** (perceptron only, both terms removed) is the missing
   control for V7b. Without it the mechanism stays a hypothesis.
2. The **cross-regime policy comparison** (V9) remains unrun and is the tool's
   headline experiment.
3. Any future ranking claim must report the **gap to the adjacent policy**, not
   only the gap to LRU. O1 happened because only the latter was quoted.

---

# Round 2 — A4 and the trace-wrap claims

## A4: 7 of 7 hold

Re-derived independently of `run_a4.sh.py`, from `a4_rows_2026-09-21.txt`.

| check | result |
|---|---|
| 11 policies x 12 traces, no gaps | 132/132, none missing |
| run lengths (IPC x cycles) | 49.978M–50.020M, zero outliers beyond 1% |
| any two policies sharing a cycle count | **0 collisions** |
| discriminating traces | exactly 10; milc 0.93% and GemsFDTD 0.89% excluded |
| every committed geomean | reproduces to **0.005pp** |
| ordering ship < hawkeye < mockingjay | +4.25% < +9.60% < +11.29% |
| ablations beat the full policy | +2.73% and +2.49% vs +2.23% |

One sensitivity worth recording: `473.astar` has a 1.77% spread against a 1.0%
inclusion threshold. It is the only trace close to the cut, so trace selection
is not fully insensitive to that threshold.

## Trace wrap: all hold, two numbers were imprecise

| claim | verdict |
|---|---|
| water_8t files are exactly 200,000,000 records | confirmed, spread 0% |
| ocean_8t min 171,823,397, uneven | confirmed |
| 22 of 127 logs wrapped | confirmed |
| water short by ~2.8% | 205,523,509 consumed vs 200,000,000 → **2.76%** |
| ocean (scaled) short by ~0.5% | 172,632,044 vs 171,823,397 → **0.47%** |
| divergence is policy-dependent on water | 1.09x (lru) to 1.26x (mockingjay, coalesce) |

**The 9 `phaseA` ocean wraps really are explicable only by the older, shorter
traces.** The highest consumption by any core in those runs is 169,824,982,
below the *shortest* current ocean file at 171,823,397. With today's traces no
core could have reached EOF, so they cannot have wrapped on them.

Imprecise as committed, neither affecting the margins chosen:

- canneal divergence was written as 1.06–1.07x; measured over 47 runs it is
  **1.04–1.08x**.
- "water 1.37x" in the divergence table is consumption against the 150M
  *nominal*, not max/min across cores, which is **1.35x**. Two different
  quantities were given one label.

## New finding: ChampSim's EOF safety net is unreachable

`champsim.cc` carries a guard intended to stop a run whose trace runs out:

```cpp
// If any trace reaches EOF, terminate all phases
if (std::any_of(std::begin(traces), std::end(traces),
                [](const auto& tr) { return tr.eof(); })) {
  std::fill(std::begin(next_phase_complete), std::end(next_phase_complete), true);
}
```

`repeatable::eof()` (`inc/repeatable.h:47`) is:

```cpp
[[nodiscard]] bool eof() const { return false; }
```

`main.cc:194` sets `repeat = simulation_given`, so every run that passes
`--simulation-instructions` — which is every run this project makes — wraps its
readers in `repeatable`, and the guard can never fire. The trace reopens *and*
the check that would have caught it is disabled by the same wrapper.

This is upstream behaviour, not a local defect, and it is the same class as S1
and S2 in `CLAUDE.md`: a guard that exists, compiles, and is structurally
unable to trigger. It explains why wrapping had to be found by reading
`main.cc` rather than by anything failing.

---

# Round 3 — the guards themselves

The three guards had never been tested. They are the foundation of every
"the policies are correct" claim, and a guard that passes vacuously is this
project's signature failure, so each was given the exact defect it exists to
catch.

| guard | injected defect | result |
|---|---|---|
| `check_include_path` | `absolute.options` pointed at the sibling ChampSim tree | **caught it** |
| `check_fill_hook` | a module with no `replacement_cache_fill` | **caught it** |
| `check_signatures` | `uint32_t find_victim(..., uint64_t ip, uint64_t full_addr, access_type)` | **PASSED IT** |

## check_signatures was blind to its own motivating bug

It grepped the header for the literal string `"long find_victim"`. A
declaration returning anything else produced an empty `$sig`, which took a
`skip` branch and **continued without failing**. So the `random` defect
verbatim — raw addresses paired with the scoped enum, returning `uint32_t` —
was reported as `skip (declares no find_victim)` and the script exited 0.

The return type is not cosmetic: `develop` makes `find_victim` pure virtual
returning `long`, so a different return type does not override it and the
dispatch never reaches the module. The guard's whole purpose is catching a
`find_victim` that will not be called, and the one form guaranteed not to be
called was the one it skipped.

A second hole in the same branch: `check` for an unrecognised signature also
exited 0, so "verify this by hand" was indistinguishable from "ok" to anything
consuming the exit code — including `run_phase_a.sh`, which gates a multi-day
sweep on it.

**Fixed.** Matches `find_victim` regardless of return type; fails on a wrong
return type, on a declaration present only in the `.cc`, on no declaration at
all, and on any unrecognised form. Re-tested across four cases: the real tree
passes, the `random` defect fails, a correct signature passes, a missing
declaration fails.

**No live blind spot.** All eleven real policies report `ok` before and after
the fix, so nothing that has run was mis-certified. The guard could not have
caught a regression, which is a different and still serious problem.

---

# Round 4 — the overlay and sharer_mask, read rather than inferred

Until now the overlay was validated only by its outputs. This is the code.

## The ASID mechanism is correct

`vmem.cc:111-118`. The page map is keyed on `{asid, vpage}`. Cores registered
by `set_shared_cpus()` all resolve to `SHARED_ASID`, so identical virtual
addresses from different cores collapse to one key and therefore one physical
page. Cores not registered keep `cpu_num` and cannot collide. That is exactly
the intended mechanism and it is implemented directly.

`try_emplace(key, ppage_front())` with `if (fault) ppage_pop()` is also right:
`ppage_front()` only peeks, and the pop happens only when an insert actually
occurred, so no physical page is leaked on a repeated translation.

## `sharer_mask` maintenance is sound

| event | code | effect |
|---|---|---|
| fill (`cache.cc:108-109`) | `state = dirty ? MODIFIED : EXCLUSIVE`, `sharer_mask = 1u << fill.cpu` | sole ownership, **no stale mask inherited from the evicted line** |
| read hit (`:281-283`) | `sharer_mask \|= 1u << cpu`; `SHARED` if not MODIFIED and popcount > 1 | reader joins the set |
| write hit (`:273-279`) | count `popcount(sharer_mask & ~(1u<<cpu))` as invalidations, then `sharer_mask = 1u << cpu`, `state = MODIFIED` | sole ownership restored |

The fill path overwriting the mask unconditionally is the important one — a
carried-over mask would have inflated every sharer count in the project, and it
does not happen. Defaults in `block.h` are `INVALID` / `0`.

The documented simplification is real and is in the code as described: a read
hit on a MODIFIED line adds a sharer without the M→S downgrade, stated in the
comment as 0.3% of MODIFIED observations.

## CORRECTION: half of the overlay validation is tautological

The committed validation table presents two columns as evidence:

    cores  regime    aliased fills   invalidations
    4      private             0                0
    4      shared        384,915          556,804

**`aliased_fills` in the private regime is zero by construction.** The
increment sits inside `if (asid == SHARED_ASID)` (`vmem.cc:124`), and in the
private regime no core ever resolves to `SHARED_ASID`. The counter cannot be
non-zero there whatever the memory system does. That column proves the overlay
is switched off. It is not evidence about sharing.

**`coherence_invalidations` in the private regime is genuine.** It is computed
in `cache.cc:273-275` from `sharer_mask & ~(1u << cpu)` on a real write hit,
with no reference to the ASID or the overlay. Zero there means cores genuinely
never held the same physical line — which is the claim — and it would become
non-zero if the page pool ever recycled pages into a collision, which is the
`EXHAUSTED-INVALID` hazard the runs already check for and pass.

So the validation stands, on one column rather than two. The load-bearing
evidence is the invalidation count, not the aliased-fill count.

## The two counters are not on the same basis

- `aliased_fills` is `static inline` on `VirtualMemory` (`vmem.h:63`),
  incremented in `va_to_pa`, **never reset**, and printed from `main.cc:217` at
  the end of the run. It covers **warmup + simulation** (150M per core).
- `coherence_invalidations` is snapshotted into `roi_stats` in
  `CACHE::end_phase` (`cache.cc:914`), so the reported figure is
  **simulation only** (100M per core).

Putting them in adjacent columns invites a ratio that means nothing. The
private/shared contrast is unaffected, but the two numbers describe different
windows and should be labelled as such.

## `aliased_fills` is misnamed

It counts every `va_to_pa` call on a shared page whose first allocator was a
different core — not fills, and not unique pages. The printed label,
"cross-CPU shared-page hits", is accurate; the variable name is not. Its
magnitude (384,915 over ~600M instructions at 4 cores) is consistent with
`va_to_pa` being reached on translation misses rather than every access.

---

# Round 5 — determinism, config generation, the trace auditor, extraction, barnes

## The simulator is deterministic

Asserted earlier when discussing a 0.12% ranking margin; now checked.

- `shuffle_pages()` (`vmem.cc:69-73`) shuffles only `if
  (randomization_seed.has_value())`, and then with `std::mt19937_64{seed}` — a
  value from config, never `random_device`.
- `make_config.py` emits **no** randomization seed, so the shuffle is a no-op
  and physical pages are handed out in linear order.
- `random`'s generator is `std::mt19937_64 rng{}` (`random.h:10`),
  default-constructed, so a fixed seed.
- A grep for `random_device`, `srand`, `time(NULL)` and
  `default_random_engine` across `src/`, `inc/` and every policy finds nothing
  else.

So a repeated run reproduces exactly, and both sweeps used the same page
layout. Sub-1% ranking differences are **real but tiny**, not noise — which is
what `phasea_results` §2's six-way tie needed to be interpretable.

## Config generation is correct

    shared  -> vmem_shared_cpus [0, 1, 2, 3]   LLC sets 2048 (= 2 MB)
    private -> vmem_shared_cpus []             LLC sets 2048

Matching the `CLAUDE.md` warning that an empty list silently disables the
overlay. The default really is the fixed 2 MB geometry, confirming the
`phaseA` / `phaseA_scaled` distinction independently of the hit-rate inference.

## The trace auditor's indices are right

`FMT = '<QBB2B4B2Q4Q'`, 64 bytes, 15 fields; memory operands at `[9:15]`.
Tested against records built with a known layout:

| record | `[9:15]` verdict | old `v[8:10] or v[10:14]` |
|---|---|---|
| registers only | no memory ✓ | **memory ✗** |
| `src_mem[0]` set | memory ✓ | memory ✓ |
| `src_mem[3]` set (last field) | memory ✓ | memory ✓ |
| `dst_mem[0]` set | memory ✓ | memory ✓ |
| high source *register* only | no memory ✓ | **memory ✗** |

The old slice reported a register-only record as having memory operands, which
is precisely how traces with no data accesses passed for months. The current
indices classify all five cases correctly, so "28 of 34 broken" and the 67
since verified rest on a correct test.

## Extraction is consistent

No raw logs exist locally, but the extracted fields must satisfy identities a
mis-parse would break. Over 130 completed runs, all hold:

- `TOTAL == LOAD + WRITE + RFO + TRANSLATION` **exactly** (prefetcher off)
- `TOTAL hits == sum of per-type hits` exactly
- hits never exceed accesses, for every type
- private has zero aliased fills; shared has non-zero

## barnes 4c at the scaled geometry: confirmed, and cleanly

Two independent lines agree:

- **Zero LLC misses in the ROI.** 398,578 load accesses, **0** misses.
- **The cache cannot fill.** 131,072 lines against 51,556 lifetime fills.

At the 2 MB geometry the same workload has 138,297 fills against 32,768 lines
and 104,903 victims. So the "dead mechanism" counters on barnes really are an
empty cache, not broken code.

### A general caveat this exposed

Policy-internal counters (`stat_fills`, `stat_victims`, `ghost_inserts`) are
plain members incremented throughout the run and printed at the end, so they
cover **warmup + simulation**. Cache statistics (`la`, `lh`, `ta`, `th`) are
snapshotted into `roi_stats` in `end_phase` and cover **simulation only**. That
is why barnes shows 51,556 fills alongside 0 misses — the fills happened in
warmup. The same mismatch applies to `aliased_fills` versus
`coherence_invalidations` (round 4). Never divide one kind by the other.

---

# Round 6 — the bias probe, and a double-count in my own extraction

## A double-count bug in `phase_rows` (mine, found 2026-09-23)

`plain_printer.cc:184-199` prints the entire cache-stat block **twice** when
`NUM_CPUS > 1`: once under "Total Simulation Statistics (not including warmup)"
from `sim_cache_stats`, then again under "Region of Interest Statistics" from
`roi_cache_stats`. `CACHE::end_phase` copies `sim_stats` into `roi_stats`, so
for the final phase the two blocks are **identical**.

`phase_rows` summed the whole file, so **every LLC counter in every multi-core
row is exactly 2x the true value.** Visible directly in the probe output, where
`cpu0->LLC TRANSLATION ACCESS: 5942` appears twice with identical figures.

**What this does and does not affect:**

| quantity | affected? |
|---|---|
| hit rates (load, total, per-type) | **no** — numerator and denominator both doubled |
| policy rankings by `max_cycles` | **no** — `max_cycles` comes from the "Simulation complete" lines, printed once |
| policy-vs-policy ratios (e.g. round 2's improvement factors) | **no** — both sides doubled |
| **absolute per-instruction rates (MPKI, TR miss/KI, wb miss/KI)** | **YES — all quoted figures read 2x high** |
| A4 | **no** — single core skips the first block entirely |

So no verdict in rounds 1–5 changes, but every absolute MPKI-style number
quoted from the Phase A sweep is twice its true value, and A4's are not —
the two datasets were silently on different bases.

The `TOTAL == LOAD + WRITE + RFO + TRANSLATION` identity from round 5 **could
not** catch this: a uniform doubling preserves it. An identity check validates
internal consistency, not absolute scale.

Fixed by gating all five per-type sums on the ROI block; verified against a
synthetic two-block log (reads 300000, not 600000). **The committed
`phasea_rows_v*.txt` files still carry doubled counters and must be re-pulled.**

## The bias probe: CONFIRMED, and it decomposes

Clean figures from the `BIAS EXPOSURE` line (the histogram rows as originally
rendered were garbled — see below):

    candidates examined  9,131,904      victims  570,744
    carrying any bias       76.87%               39.65%      ratio 0.52x
    MODIFIED                41.64%               39.50%      ratio 0.95x

**The two bias terms do completely different amounts of work:**

| sharers | candidates | victims | vict/cand |
|---|---|---|---|
| 1 | 60.913% | 99.640% | **1.636x** |
| 2 | 8.992% | 0.278% | **0.031x** |
| 3 | 8.215% | 0.048% | **0.006x** |
| 4 | 21.880% | 0.034% | **0.002x** |

Monotonic in sharer count, and near-total: 21.88% of resident lines have four
sharers and they are 0.034% of evictions. **`+20 x sharers` does not bias
eviction, it effectively pins the line.** Meanwhile `+40` on MODIFIED moves the
eviction rate from 41.64% to 39.50% — a factor of 0.95, which is nearly inert.

Derivable from the same figures: lines that are biased but *not* MODIFIED
(i.e. multi-sharer, not dirty) are 35.23% of candidates and 0.149% of victims,
a ratio of **0.004x**.

This confirms the mechanism proposed in `coalesce_diagnosis_2026-09-22.md` —
unbiased lines absorb the evictions — while showing that the *sharer* term, not
the MODIFIED term, is responsible. A4 found the MODIFIED term costs 0.26pp on
single core where it is the only term that can fire; here, where both can, it
is the harmless one.

### The histogram rendering was broken

The report `paste`d two greps and selected awk fields by position. The
percentage column varies in width, so fields shifted and victim counts printed
under the wrong headings — bucket 2 rendered as "victim 2 1585", two values run
together. Fixed to parse both histograms in one pass and join on the bucket
index. A table that misreports the quantity it exists to show is worse than no
table.
