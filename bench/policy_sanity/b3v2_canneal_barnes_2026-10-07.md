# B3 v2 on canneal and barnes: disagreement — ChampSim's private caches are not coherent

> **Correction, 2026-10-12 (later the same day): every barnes verdict below is
> void.** The traced BARNES was built with 256-body tree leaves; SPLASH-3's
> source, and the binary gem5 ran, use 10. Per 1,000 instructions the traces
> hold 26.8 read-modify-writes (10.5 locked: a mutex on every body-body
> interaction, of which that build makes about 9× as many per instruction)
> and gem5 executed 10.6 (1.7 locked). canneal agrees to 0.1% on that measure. barnes's
> numbers here are neither passes nor failures until both simulators run
> one program. canneal is not affected; ocean carries a smaller caveat.
> `b3_barnes_stream_2026-10-12.md`.

**2026-10-07.** Scored as pre-registered:
- canneal against `b3v2_canneal_design_2026-10-06.md` (`b6d0ee8`, committed
  before any canneal run existed);
- barnes against `b3v2_design_2026-10-05.md` (`3a0a085`).

Nothing was tuned after R was seen.

Sources:
- ChampSim: `phasea_rows_v13.txt` and `b3_rows_v4.txt`;
- gem5: `simulator/results/gem5_b3/canneal/` (2 MB and 8 MB, worker stops
  50/100/150 M) and `gem5_b3/barnes/` (2 MB, stops 50/150 M and the whole
  program).

## Qualifying checks — all pass

**ChampSim:**
- Both canneal trees pass `analyze_rows.py check`: complete, no wrap, TOTAL
  identity, 100.5–100.9 M instructions per core.
- **The directory changed nothing on canneal.** All 4 LRU canneal 4c rows are
  identical in all 15 columns to the `phaseA` and `phaseA_scaled` rows, which
  ran on `bin/champsim_phaseA_20260923`.
- Self-check: 0 mismatches and 12 registered, in every row.
- The private regime reads 0 for (a) and (b).

**gem5, from the pulled `config.ini` and `run.log` of all 9 runs:**
- canneal:
  - `CANNEAL 4 15000 2000 …/100000.nets 128`, 5 CPUs;
  - `max_insts_any_thread` 0 on cpu0, and the stop on cpu1–4;
  - 10 of 10 L0↔L1 buffers unordered, randomization off;
  - each exits on "a thread reached the max instruction count".
- barnes: 8 of 8 buffers unordered, randomization off.
- **The loader is idle in the canneal window:** cpu0 runs 0 instructions
  between the 50 M and 150 M stops, so the pre-registered 0.1% rule does not
  trigger.
- The workers stop within 0.4% of each other.

## Result

Events per 1,000 instructions, window 50–150 M:

| | gem5 `(SS+MT).L1_GETX` | ChampSim (b) protocol | **R_b** | (a) presence | v1 LLC-mask | shared-cache demand accesses, ChampSim / gem5 |
|---|---|---|---|---|---|---|
| **canneal 2 MB** | 0.2236 (89,307) | **0** | **0** | 0 | 0 | 5.41 / 5.18 = **1.04** |
| **canneal 8 MB** | 0.2475 (98,861) | **0** | **0** | 0 | 0 | 5.42 / 5.11 = **1.06** |
| **barnes 2 MB** | 0.1116 (44,867) | 0.00009 (37) | **0.001** | 0.00002 (9) | 0.00009 (36) | 0.51 / 0.82 = **0.63** |
| *ocean 2 MB, for reference* | *0.0696* | *0.0879* | *1.263* | | | *0.89* |

**Primary criterion, 0.5 ≤ R_b ≤ 2: fails for canneal at both sizes and for
barnes.** ChampSim records no store-time sharing on canneal, where gem5
records 89–99 thousand events in the window.

**Secondary criteria:**
- R_b ≤ 1 ≤ R_a fails.
- R_a < R_b fails (both 0).

**Window check.**
- canneal is steady: 50–100 M against 100–150 M is 0.2215 / 0.2258 at 2 MB
  and 0.2456 / 0.2494 at 8 MB, 1.02× at both.
- barnes is not: gem5's spans read 0.752 / 0.112 / 0.170 (0–50 M / 50–150 M
  / 150 M–end), a 6.7× spread. So the verdict is stated per span:
  ChampSim's 0.00009 is outside the band against every span.

**Hierarchy check: passes on all three (within 2×).** The same volume of
traffic reaches the shared cache. What differs is its type.

## The mechanism: the traffic matches; its type does not

The store-miss stream at the shared cache, window 50–150 M:

| | ChampSim LLC RFOs | gem5 L2 `L1_GETX`, all states | ratio |
|---|---|---|---|
| canneal 2 MB | 175 (0.0004/KI) | 946,589 (2.37/KI) | 0.00018 |
| canneal 8 MB | 131 | 943,622 | 0.00014 |
| barnes 2 MB | 57 | 69,496 (+ 61,777 `SS.L1_UPGRADE`) | 0.0008 |
| *ocean 2 MB* | *5.08/KI* | *4.73/KI* | *1.07* |

**canneal: every read of shared state is a locked read-modify-write.**
- canneal's `AtomicPtr<T>::Get()` calls `atomic_load_acq_ptr`. The bundled
  `atomic/amd64/atomic.h` implements that load as
  `MPLOCKED cmpxchgq` (`ATOMIC_STORE_LOAD(long, "cmpxchgq %0,%1", …)`). In
  the traced binary, `atomic_load_acq_long` at 0x2c58 is
  `f0 48 0f b1 02  lock cmpxchg %rax,(%rdx)`.
- On every move a worker reads `present_loc` this way for both candidate
  elements (`calculate_delta_routing_cost`) and for every fan-in and fan-out
  of each (`netlist_elem::swap_cost`).
- A locked cmpxchg always writes its target, so the core must own the line.
- **gem5** does exactly that. Ruby's `Sequencer::makeRequest`: *"x86 locked
  instructions are translated to store cache coherence requests because these
  requests should always be treated as read exclusive operations."*
  - 99.7% of the window's (SS+MT) events are `MT.L1_GETX` (89,040 of
    89,307): another core's private cache owned the line.
  - Upgrades are negligible: 580.
- **ChampSim**'s trace keeps the instruction's address, as a source and a
  destination, but not its lock or ownership semantics.
  - The core issues the read half as a LOAD (`ooo_cpu.cc`, `issue_read`).
  - The write half is a WRITE to L1D, which hits the line the load brought
    in, or merges with its miss.
  - Only a WRITE that misses is forwarded as an RFO (`cache.cc:328`).
  - So the shared cache sees a read, the protocol view adds the reader, and
    no store-time event occurs.
- **Measured:** demand traffic matches within 4–6%, yet ChampSim's LLC sees
  0.02% as many store-type requests as gem5's L2. The rest of the matching
  volume arrives as loads.

**barnes: ChampSim never invalidates a private copy.** This was
pre-registered as a known difference in `b3v2_design_2026-10-05.md`.
- In gem5, when two cores write the same lines in turn, each write takes the
  line from the other: 42,849 `MT.L1_GETX` and 61,777 `SS.L1_UPGRADE` in the
  window.
- In ChampSim, a core's copy survives the other core's write, so its next
  write hits its own stale copy. Neither the miss nor the upgrade reaches the
  LLC.
- ChampSim's demand traffic is 0.63× gem5's; the coherence misses are absent.
- barnes's locks are also locked RMWs, the canneal mechanism. **The two are
  not separated here:** that would need per-PC attribution, which neither
  side records.

**Why ocean agreed:** its sharing stores are plain stores that miss the
private hierarchy. They reach the LLC as RFOs: 5.08/KI against gem5's GETX
4.73/KI, where the directory sees them.

## What this establishes

**Established, on three workloads at 4 cores:**
- The overlay reproduces the *volume* of shared-cache traffic: ChampSim /
  gem5 = 0.89 and 0.99 (ocean), 1.04 and 1.06 (canneal), 0.63 (barnes).
- It reproduces store-time sharing **only where sharing goes through plain
  store misses** (ocean).
- It **does not** when sharing goes through locked read-modify-writes
  (canneal) or repeated writes by different cores (barnes).
- The cause is that ChampSim's private caches are not coherent:
  - an RMW issues no ownership request;
  - a write never invalidates other cores' private copies.
- These are properties of the tool as built, measured against a real MESI
  protocol. They are not tuning matters.

**Consequences for results already in hand.**
- **A5, the cross-regime result, is canneal.** In ChampSim's shared regime,
  canneal's location-pointer accesses reach the LLC as reads. A5 measures how
  rankings move under *this* model of sharing. It is not shown to be how
  they move under coherent hardware. A5 must carry this as its first threat
  to validity (PLAN § 8).
- **COALESCE and srrip_bias** take their coherence inputs, LLC MESI state
  and sharer counts, from the same model. On canneal those inputs see
  write-sharing as read-sharing.

**Not established:** how much of the cross-regime effect would survive a
coherent private hierarchy. That needs either the comparison below or a
coherence engine.

## What could follow — the owner's decision; none of it is pre-registered yet

1. **Disclose and keep.** Report B3 as: agreement on ocean, disagreement on
   canneal and barnes, the mechanism measured. The tool paper's claim narrows
   to traffic fidelity plus sharing on store-miss workloads.
2. **v3, records only (all results stay bit-identical).** The directory
   would treat an LLC load that comes from an RMW instruction as an ownership
   request, and would count private-cache store hits to lines the protocol
   view lists as shared, as gem5's upgrades. This would score against the
   **existing** gem5 runs; no gem5 rerun is needed. It shows whether the
   overlay can *see* the sharing, not whether the simulation *behaves*
   coherently.
3. **v3, behavioural (a coherence engine):**
   - issue an RMW's read as an RFO;
   - back-invalidate other cores' private copies on an ownership request,
     using the directory's presence bits.

   It changes simulated behaviour, so the sweeps behind A5 would rerun on
   the fixed simulator. **Validating each step is cheap, though: the gem5
   reference runs are done and do not change.** Each fix needs only the
   ChampSim LRU runs, ~3 h, to be re-scored against them.

   This is the B3 loop doing its job: v1 found the LLC forgetting sharers;
   the directory fixed it, and ocean agreed. v2 now names the next two
   mechanisms, each with numbers.

   (Corrected the same day. This option first read "days of server time …
   the MICRO 2027 coherence-engine paper", which presented the fix as out of
   reach. It is not: only the A5 rerun is expensive.)
