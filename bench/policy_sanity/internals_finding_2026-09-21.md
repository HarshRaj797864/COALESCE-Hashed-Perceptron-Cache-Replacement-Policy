# Policy internals — nothing is broken; barnes 4c (scaled) is empty

> **One conclusion here is wrong, not merely provisional** (added 2026-09-23).
> COALESCE's non-zero `ghost_rescues` was read as the rescue working. It was
> non-zero *because of* the ghost-tag defect: the tag carried no address bits,
> so the rescue fired on lines that had never been evicted. A non-zero counter
> proves a code path runs, not that it computes the right thing. See
> `coalesce_ghost_defect_2026-09-23.md`, "The invalidation ledger".

**2026-09-21.** Raw: `internals_2026-09-21.txt`, 84 completed logs.
Reported 6 "dead mechanisms" and 9 "missing stats". Neither is a code defect.

## The 6 "dead" are all barnes 4-core, scaled — and the cache never fills

    phaseA_scaled/.../barnes_4core/coalesce     ins       0  resc      0  detr       0  hitt   23412
    phaseA_scaled/.../barnes_4core/hawkeye      fills 51556  hits 553687  detr       0  optgen  7323
    phaseA_scaled/.../barnes_4core/mockingjay   victims   0  fills 51556  rdp      155

    phaseA_scaled/.../canneal_8core/coalesce    ins   26833  resc  24753  detr   26833  hitt  270888
    phaseA_scaled/.../canneal_8core/hawkeye     fills 959689  hits 8861463  detr 5767  optgen 107402
    phaseA_scaled/.../canneal_8core/mockingjay  victims 472815  fills 947190  rdp   121

`Mockingjay: victims 0` settles it. `victims` counts calls to `find_victim`.
Zero means **no line was ever evicted**: at the scaled geometry barnes 4-core
gets a 2 MB x 4 = 8 MB LLC, which is larger than its working set, so the cache
never fills.

Every "dead" counter follows from that, not from dead code. COALESCE's ghost
insert and its detraining both live in `find_victim`; Hawkeye's detraining does
too. A policy that is never asked to evict cannot run them. `hit_trains 23412`
and `fills 51556` confirm the other hooks fire normally.

The same fact explains the IDENTICAL ablation flags: with zero evictions there
are no replacement decisions, so `coalesce`, `coalesce_no_mesi` and
`coalesce_no_sharer` are necessarily the same policy. On canneal 8-core, where
there are 472,815 evictions, all three differ as they should.

**So barnes 4-core in the scaled sweep cannot discriminate between policies.**
Same category as A4's milc and GemsFDTD, which were excluded for a 0.9% IPC
spread. All 12 barnes rows in `phaseA_scaled` are uninformative -- not wrong,
just empty. barnes at the unscaled 2 MB geometry may still have pressure; that
is a separate question and those logs predate the counters.

## The 9 "missing stats" are an older binary

All are `phaseA` (unscaled) COALESCE variants. That sweep ran before
`replacement_final_stats` printed these counters. Not a defect; it does mean the
unscaled sweep cannot be audited this way.

## Consequence

With water and ocean dropped for trace wrapping, and barnes 4-core empty at the
scaled geometry, the scaled sweep's usable content is **canneal at 4, 8 and 16
cores**. That is 36 of the 48 remaining jobs.

Worth stating plainly in the write-up rather than discovering later: the LLC
sizing that fixes the confound found on 2026-09-19 also removes all capacity
pressure from the smallest workload. Cache size is not a free parameter -- it
decides which workloads still pose a replacement problem at all.
