# Phase B — the two simulators do not count the same thing

**2026-09-23.** Found while choosing which gem5 stat to compare against
ChampSim's invalidation counter. Nothing has been run; this is static analysis
of both codebases, done before any comparison number exists so that none can
be misread.

`docs/PLAN.md` lists as an open item: *"Define the comparison metric precisely —
sharing-degree distribution and invalidations per kilo-instruction, measured the
same way on both sides."* The obvious choice, invalidations per KI on each side,
**does not meet that bar**, for two independent reasons.

## 1. They count invalidations at different protocol events

How requests reach ChampSim's LLC, from the code:

- A CPU store enters L1D as `access_type::WRITE` (`ooo_cpu.cc:848`).
- A request that misses is forwarded down as `RFO` when it was a `WRITE`
  (`cache.cc:305`). So **a store miss arrives at the LLC as `RFO`.**
- A dirty eviction sends a writeback as `access_type::WRITE` (`cache.cc:158`).
  So **at the LLC, `WRITE` means an L2 writeback**, never a store.

ChampSim's counter fires only on a `WRITE` hit (`cache.cc:272`). An `RFO` hit
takes the other branch and **adds** the storing core to the sharer mask.

| | ChampSim | gem5 MESI_Two_Level |
|---|---|---|
| trigger | an L2 **writeback** hits the LLC while its sharer mask names other cores | a **store request** reaches L2 for a line other L1s hold |
| when | when the dirty line leaves the writer's L2 — possibly much later, possibly never within the run | at the moment of the store |
| store to a line the core already holds shared (upgrade) | **invisible** — an L1D store hit marks the line dirty and forwards nothing (`cache.cc:241`) | counted, as `L1_UPGRADE` |
| inclusive L2 evicting a line L1s hold | **none** — no back-invalidation; per `cache.cc:246-248` "invalidated" cores keep stale copies | L1 receives `Inv` for these too |
| sharer set | cores that touched the line *at the LLC* since the last writeback; sticky, since invalidated cores keep hitting privately and never re-register | **also sticky** — see correction below; not "cores whose L1 holds it now", as first written |

Both ChampSim counters are writeback-time: `COHERENCE INVALIDATIONS` is per
sharer and `COHERENCE WRITE-HIT OTHER-SHARER EVENTS` is per event
(`plain_printer.cc:129-130`). Neither is store-time.

So a match between the two inv/KI figures could be coincidence, and a mismatch
could be pure definition. The comparison could neither validate the overlay nor
refute it.

## 2. The cache hierarchies are not the same shape

| | L1D | private L2 | shared cache |
|---|---|---|---|
| ChampSim (`make_config.py`) | 32 KB | **512 KB** | LLC 2 MB |
| gem5 (`run_gem5_splash.sh`) | 32 KB | **none** | L2 2 MB |

MESI_Two_Level is exactly two levels: private L1, shared L2. ChampSim has a
private 512 KB L2 between them. Every shared-cache rate differs by that L2's
filtering, and per-kilo-instruction normalisation does not remove it. It bites
hardest on sharing specifically: a line a core keeps re-reading from its private
L2 never re-registers in ChampSim's LLC sharer mask, while in gem5 every L1 miss
to it reaches the shared L2.

`run_gem5_splash.sh` claimed *"CACHE GEOMETRY IS MATCHED DELIBERATELY"*. It
matched the LLC size and nothing else; the header now says so.

## The protocol's own answer (read from the server, 2026-09-23)

`gem5_stats.sh protocol` against the real `MESI_Two_Level-L2cache.sm`. Every L2
transition whose actions send an invalidation:

| transition | action | class |
|---|---|---|
| `SS, L1_GETX → SS_MB` | `fwm_sendFwdInvToSharersMinusRequestor` | **coherence** — store miss, line shared by other L1s |
| `SS, L1_UPGRADE → SS_MB` | same, plus `ts_sendInvAckToUpgrader` | **coherence** — store to a line already held shared; invisible to ChampSim |
| `SS, L2_Replacement_clean → I_I` | `f_sendInvToSharers` | inclusion recall |
| `SS, {L2_Replacement, MEM_Inv} → S_I` | `f_sendInvToSharers` | inclusion recall |
| `MT, {L2_Replacement, MEM_Inv} → MT_I` | `f_sendInvToSharers` | inclusion recall |
| `MT, L2_Replacement_clean → MCT_I` | `f_sendInvToSharers` | inclusion recall |
| `SS, {Flush, Flush_NP[_Clean]} → I_FF` | `fwn_sendInvToSharersMinusRequestorFlush` | explicit flush |

At the L1, every `Inv` transition runs `fi_sendInvAck`, in states `NP/I`, `S`,
`E`, `IS`, `IM`, `SM` and the prefetch variants. **L1 `Inv` cannot be the
metric**: `S, Inv` fires from both a coherence invalidation (`SS.L1_GETX`) and
a recall (`SS.L2_Replacement`), and `E, Inv` fires *only* from a recall — an E
line is held by one L1 in L2 state MT, and the only MT transitions that send
`Inv` are the replacement ones. It sums two classes that ChampSim can only
produce one of.

### Two traps in reading these stats

**Selecting by action name misses ownership transfers.** A store miss to a line
one L1 owns exclusively (L2 state `MT`) is resolved by *forwarding* the request
to the owner, which then gives the line up. That removes another core's copy
because of a write — exactly what ChampSim's counter is meant to capture — but
the forwarding action has no "Inv" in its name, so the first version of the
listing never showed it. `protocol` now also lists every transition on
`L1_GETX`/`L1_UPGRADE` (L2) and `Fwd_GETX`/`Fwd_GETS` (L1) with all their
actions, which is complete where the name filter is not.

**Confirmed from the server:**

    L2  transition(MT, L1_GETX, MT_MB)    b_forwardRequestToExclusive; uu_profileMiss
    L1  transition(E,  Fwd_GETX, I)       forward_eviction_to_cpu; d_sendDataToRequestor
    L1  transition(M,  Fwd_GETX, I)       forward_eviction_to_cpu; d_sendDataToRequestor
    L1  transition(M_I, Fwd_GETX, SINK_WB_ACK)   owner was already writing it back

So an ownership transfer does invalidate the owner's copy (E/M → I). Also
visible and worth knowing:

- `M, L1_GETX → MT_MB` sends data and **invalidates nothing** — in L2 state `M`
  the L2 holds the only copy and no L1 has it.
- `NP, L1_GETX → IM` fetches from memory; nobody else holds the line.
- There is **no** `MT, L1_UPGRADE`: an upgrade means the requester holds the line
  shared, and in `MT` only one L1 holds it, exclusively.

### Correction: gem5's sharer list is sticky too

This document first described gem5's sharer set as "cores whose L1 holds it now",
as the contrast to ChampSim's sticky mask. The protocol says otherwise. The L1
has a transition `{NP, I}, Inv → fi_sendInvAck`: an L1 that does **not** hold
the line receives an invalidation and acknowledges it. That transition exists
only because the L2 can list as a sharer an L1 that has already dropped the
line — consistent with clean evictions of `S` lines being silent. So both
simulators over-state the sharer set after a silent eviction, and the gap
between them is narrower than claimed here at first. (Confirming the silent
eviction directly means listing the L1's `L1_Replacement` transitions from `S`.)

### A cross-check the protocol makes available

`Fwd_GETX` is sent only by `MT.L1_GETX`, and each forward is handled exactly
once at the owning L1, in `E`, `M` or `M_I` (`LLSC_E`/`LLSC_M` stall it and
re-fire it). Therefore

    L2Cache_Controller.MT.L1_GETX  ==  L1Cache_Controller.{E,M,M_I}.Fwd_GETX

`gem5_stats.sh extract` checks this per run and says so if it fails. It is the
gem5-side counterpart of `TOTAL == LOAD+WRITE+RFO+TRANSLATION` on the ChampSim
side: if it breaks, our reading of the protocol is wrong and every figure
inherits that.

**Event totals double-count stalls.** Transient states stall an arriving
request and re-fire it later, e.g. `{MT_MB, SS_MB}, {L1_GETS, L1_GETX,
L1_UPGRADE} → zz_stallAndWaitL1RequestQueue`. The event total
`L2Cache_Controller.L1_GETX` counts both the stalled attempt and the retry.
**Only per-state stats — `SS.L1_GETX`, `MT.L1_GETX` — count each store once.**

### Resulting INV_STATS — confirmed, available as `PRESET=mesi_two_level`

    ChampSim-visible, store miss to a line others hold:
        system.ruby.L2Cache_Controller.SS.L1_GETX
        system.ruby.L2Cache_Controller.MT.L1_GETX
    ChampSim-invisible, report separately as the size of the blind spot:
        system.ruby.L2Cache_Controller.SS.L1_UPGRADE
    Exclude: every L2_Replacement*, MEM_Inv, Flush*, every L1 Inv, every
             event total.

These are per **event**. The fair ChampSim counterpart is the proposed store-time
counter (an `RFO` hit at the LLC whose sharer mask names other cores), also per
event — not today's per-sharer `COHERENCE INVALIDATIONS`, which fires at
writeback.

## What each gem5 candidate actually measures

From the protocol definition (`gem5_stats.sh protocol`, which lists the
transitions whose actions send an invalidation):

| gem5 stat | meaning | ChampSim counterpart |
|---|---|---|
| `L2Cache_Controller.SS.L1_GETX` | store **miss** to a line other L1s share → invalidate them | an `RFO` hit at the LLC with other sharers — **not counted today** |
| `L2Cache_Controller.SS.L1_UPGRADE` | store to a line the requester already holds shared | none; structurally invisible |
| `L2Cache_Controller.*.L2_Replacement` sending Inv | inclusion recall | none |
| `L1Cache_Controller.Inv` | every invalidation an L1 receives, **coherence and recall together** | none directly |

## Options

1. **Match the event.** Add a ChampSim counter for an `RFO` hit at the LLC whose
   sharer mask names other cores — a store miss to a shared line, which is what
   `SS.L1_GETX` counts. Instrumentation only, read-only with respect to
   behaviour; it can go in the same rebuild as the DRRIP/SHiP counters once the
   sweep drains. Report `SS.L1_UPGRADE` separately as the measured size of what
   ChampSim cannot see — turning a limitation into a number.
2. **Match the hierarchy.** gem5's MESI_Three_Level has private L0 and L1 and a
   shared L2, which maps onto ChampSim's L1D / L2C / LLC. Needs a gem5 rebuild
   with that protocol selected, which is CPU-heavy and should wait for the sweep.
3. **Compare trends, not magnitudes.** Whether sharing scales the same way with
   core count, whether the private or single-core case reads zero on both sides
   (the smoke run already shows gem5 does), whether a read-only workload reads
   near zero, whether workloads order the same way. Robust to both mismatches,
   and weaker.

(3) is achievable now and defensible. (1) plus (2) is what a reviewer asking
"does the overlay produce realistic sharing?" would actually accept. Whichever
is chosen, the metric has to be fixed **before** the multi-core gem5 runs, not
fitted to whatever they produce.
