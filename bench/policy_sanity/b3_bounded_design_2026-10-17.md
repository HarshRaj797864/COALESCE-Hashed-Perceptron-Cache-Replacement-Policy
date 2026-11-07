# B3 diagnosis: does a directory that forgets off-chip lines explain radix? Pre-registered

**2026-10-17.** Written and committed **before** the binary below has been
run on any held-out or B3 trace. It tests a hypothesis; it changes no
simulated behaviour.

## Why

`b3_heldout_results_2026-10-17.md`: on radix, held out, the protocol view
over-counts store misses that find another core 43× (R_b 42.96), while the
traffic, the store misses and the instruction stream match gem5, and the
presence view agrees (R_a 0.876). On ocean the reverse holds: presence 0.08,
protocol 0.99.

**The hypothesis.** ChampSim's protocol view keeps a core listed after it
silently drops a clean copy, and keeps it for as long as the simulation runs
(the directory was made independent of the LLC on 2026-10-05). gem5's sharer
list lives in its inclusive L2, so it lists stale readers too -- but only while
the line stays in the L2; when the L2 evicts the line, its sharers are gone.
radix's 16 M keys stream through the 2 MB cache, so in gem5 almost every line
has left the L2 before it is written again; in ChampSim every reader is still
listed.

## What is measured

A second protocol view, the **bounded view**, kept exactly as the first --
a read at the LLC adds the reader, a store miss leaves the requester alone, a
writeback removes the writer, an upgrade leaves the upgrader alone -- except
that **it forgets every core once the line is held nowhere on chip**: in no
private cache and not in the LLC. The LLC reports its fills and evictions to
the directory for this. Two counters: store misses at the LLC, and upgrades,
for which the bounded view lists another core. Nothing simulated reads them.

**R_bounded** = bounded store-miss events per 1,000 instructions over gem5's
(SS + MT) L1_GETX per 1,000 instructions, the same window as R_b.

## Qualifying checks

- **Q0, records only:** on the laptop, against the binary before the change,
  every log line that existed before prints the same (canneal and barnes,
  shared and private, levels 0 and 2). On the server, every re-run
  configuration's rows equal the existing rows of the frozen binary in every
  column the files already had.
- **Q1:** in every run, bounded events ≤ protocol events (it is a subset by
  construction).
- **Q2:** `check_coherence_exact.sh` passes at levels 0, 1, 2.

## The runs

Level 2, LRU, shared regime, on the diagnostic binary, every B3 configuration
scored so far: ocean 4c at 2 and 8 MB; canneal 4c at 2 and 8 MB; canneal 8c;
the standard barnes in its three spans; barnes-256; radix; water-nsquared;
fmm. 12 runs, against the gem5 runs already in hand.

## Predictions

- **P1 (the hypothesis): radix's R_bounded lies in the band, 0.5 to 2.**
- **P2: the programs that agree now keep agreeing:** R_bounded in the band
  for ocean (2 and 8 MB), canneal (2 and 8 MB, and 8 cores), the standard
  barnes (force and start spans) and barnes-256.
- Reported, no prediction: water-nsquared (not discriminating), fmm (its
  stream check failed), barnes's window span, and the bounded upgrades
  against gem5's.

## How each outcome is read

- **P1 and P2 hold:** the over-count is the unbounded directory. A **step 4**
  -- the directory forgets a line's cores once it is held nowhere on chip,
  in behaviour, not only in a counter -- is the candidate fix. It gets its
  own pre-registration, which must include: a rescore of every program, a
  check of how much it changes the policy runs' timing, and **new held-out
  programs** (radix no longer counts as held out for it).
- **P1 holds, P2 fails:** forgetting off-chip lines fixes radix and breaks
  others; the right rule lies elsewhere.
- **P1 fails:** the hypothesis is wrong; radix's over-count has another
  cause.

Nothing is tuned after a number is seen.
