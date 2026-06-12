# Barnes — SPLASH-3 N-body octree under shared VMEM

n16384 input, 4-thread PIN traces, 50 M warmup + 100 M sim per core.

## 4-core shared (8 policies — COMPLETE)

| Rank | Policy | max_cycles | vs LRU |
|---|---|---|---|
| 1 | **LRU** | **156,549,335** | – |
| 2 | DRRIP | 158,994,040 | +1.6 % |
| 3 | SRRIP | 159,098,740 | +1.6 % |
| 4 | SHiP | 159,175,321 | +1.7 % |
| 5 | Hawkeye | 159,500,118 | +1.9 % |
| 6 | **COALESCE** | **160,448,239** | **+2.5 %** |
| 7 | coalesce_no_sharer | 160,656,244 | +2.6 % |
| 8 | Mockingjay | 162,545,897 | +3.8 % |

## Why barnes doesn't discriminate (and why LRU wins)

The bet was that barnes' irregular octree + writes + sharing would be
canneal-class. The LLC data says otherwise: **cpu0→LLC sees only ~500 K
accesses total** (LOAD 344 K, RFO 52 K, WRITE 105 K) vs canneal's tens of
millions. At n16384 the working set largely fits in L1/L2 — the LLC is
barely pressured. 30 K invalidations, 3.5 K aliased fills.

Consequences:
- Total policy spread is only **3.8 %** — the workload barely discriminates.
- With high temporal locality and no capacity pressure, LRU's recency
  heuristic is optimal-ish; every learned policy pays its sampling /
  prediction overhead for nothing. All three learning policies (COALESCE,
  Hawkeye gap small; Mockingjay last) trail the simple heuristics.
- This is a *third* characterization corner: canneal = high pressure +
  irregular (COALESCE wins), ocean = high pressure + regular (RRIP wins),
  fluidanimate = read-only (inert), **barnes = low LLC pressure (nothing
  matters, LRU wins)**.

For the paper: barnes goes in the characterization table as the
low-LLC-pressure boundary case. A +2.5 % loss inside a 3.8 % spread is
benign disclosure, and Mockingjay being last again (4th workload in a row)
strengthens finding #2 (multi-programmed SOTA does not transfer).

Possible future work note: barnes at larger n (e.g. n=262144) would
pressure the LLC and may discriminate; not run due to compute budget.

## Status

| Directory | Status |
|---|---|
| `4core/` | ✅ all 8 policies |
| `8core/` | not run — traces (8t) not generated; cut per calendar |
