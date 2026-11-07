# Overlay validation — complete, and the first uncontaminated one

**2026-09-18.** LRU, canneal, 5M warmup + 10M simulation per core, ChampSim
@ develop f9ed890e, `results/phaseA_quick`. All six runs complete, none hit the
page-pool exhaustion warning.

**Short-length pass. Magnitudes are not quotable** — the full-length sweep
(50M + 100M per core) supersedes them. What is being tested here is the shape.

## Result

| cores | regime | aliased fills | invalidations | inval/core | max cycles |
|---|---|---|---|---|---|
| 4 | private | **0** | **0** | 0 | 24,701,069 |
| 4 | shared | 37,394 | 15,757 | 3,939 | 20,537,871 |
| 8 | private | **0** | **0** | 0 | 27,480,470 |
| 8 | shared | 93,688 | 32,369 | 4,046 | 22,769,635 |
| 16 | private | **0** | **0** | 0 | 33,822,830 |
| 16 | shared | 212,269 | 73,351 | 4,584 | 27,928,370 |

**Scaling** — invalidations ×2.054 from 4→8 cores, ×2.266 from 8→16. Aliased
fills ×2.505 and ×2.266. Monotone, smooth, slightly superlinear: invalidations
per core creep up (3,939 → 4,046 → 4,584), which is what should happen as more
cores share a line and each write invalidates more copies.

**Performance** — sharing removes 16.85% / 17.14% / 17.43% of cycles at 4/8/16
cores. Consistent and mildly increasing. Four cores aliasing one copy of the
data relieves more capacity pressure than the invalidation traffic costs.

## Against the published claim

The paper reports 0.11M → 6.9M → 23.9M invalidations at 4/8/16 cores, which is
**×62.7 then ×3.46**. A 63-fold jump from doubling the core count is not a
physical effect, and it should have been questioned at the time.

The 8-core mix was `canneal_big{0,1,2,3,4,0,1,2}` — three traces used twice.
Under the shared-VMEM overlay two cores running the same trace touch identical
addresses and alias by construction, so the duplication lands exactly on the
4→8 step where the discontinuity appears. The old figure is an artifact with a
visible signature, not merely an unverified number.

## Why this measurement is trustworthy where the old one was not

Three mechanisms can fabricate sharing. All three are controlled:

1. **Repeated traces** — every core gets a distinct thread of one parallel run
   (`canneal_{4,8,16}t/canneal1..N`), skipping thread 0, which loads the
   netlist. The runner now refuses to pad a mix rather than repeating traces.
2. **Page-pool recycling** — `vmem.cc` repopulates the free list when physical
   pages run out, handing the same page to different virtual pages, which is
   indistinguishable from sharing to a physically-indexed LLC. `make_config.py`
   was giving every core count a 4 GiB pool against the reference's 16 GiB;
   fixed, and the `vmem` column confirms no run exhausted it — including at 16
   cores, so 16 GiB is adequate there.
3. **Traces without data accesses** — the tracer wrote every thread's operands
   into thread 0's buffer, leaving 28 of 34 traces instruction-only. Regenerated
   and audited: 54 healthy, 0 broken.

The private-VMEM control reading **exactly zero at all three core counts** is
what rules out any remaining source: with the overlay off there is no sharing
at all, so every invalidation in the shared rows came from the overlay.

> **Correction, 2026-09-23** (`verification_2026-09-22.md` round 4). That
> argument holds for the **invalidations** column and not for the **aliased
> fills** column. `vmem.cc:124` increments `aliased_fills` inside
> `if (asid == SHARED_ASID)`, and no core resolves to `SHARED_ASID` when the
> overlay is off — so the private zero there is true by construction and proves
> only that the overlay is disabled.
>
> `coherence_invalidations` carries the argument: `cache.cc:273-275` computes it
> from `sharer_mask & ~(1u << cpu)` on a real write hit, with no reference to the
> ASID. Zero in the private regime therefore does mean cores never held the same
> physical line, and it would go non-zero if the page pool recycled pages into a
> collision — the `EXHAUSTED-INVALID` hazard these runs check and pass.
>
> So the conclusion stands on one column rather than two. Also note the two are
> on different bases: `aliased_fills` is a `static` never reset and printed at
> end of run, covering warmup **and** simulation, while
> `coherence_invalidations` is snapshotted into `roi_stats` in `end_phase` and
> covers simulation only. The ratio between the columns means nothing.

## What this establishes, and what it does not

**Does.** Stock ChampSim produces no sharing whatsoever — measured now, not
asserted. The overlay produces sharing that scales monotonically and near
linearly with core count on genuinely distinct threads. The regime change is
large and consistent, so regime 1 and regime 2 are materially different
experiments.

**Does not.** That the sharing corresponds to real program semantics. Trace
replay preserves neither synchronisation nor inter-thread ordering, so address
overlap is not the same thing as program-level sharing. That is what gem5
validation (Phase B) is for, and it has not started. This result shows the
overlay does what it was built to do; it does not show that what it does
matches reality.

Nothing here speaks to replacement policies — LRU only, deliberately, because
invalidation scaling is a property of the memory system rather than the policy.
