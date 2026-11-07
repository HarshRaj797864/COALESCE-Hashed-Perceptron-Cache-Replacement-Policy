# Trace wrapping at 8 cores — mechanism, blast radius, fix

**2026-09-21.** Raw data: `wrap_diagnosis_2026-09-21.txt` (105 healthy runs, 22
wrapped). Reproduce with `bash ~/diagnose_wraps.sh` on the server.

## The mechanism

`check_trace_length` refuses any trace with fewer than `WARMUP + SIM` = 150M
records, and it checks **every** file in a set, not a sample. water has exactly
200,000,000 records per file and ocean 171.8M–172.8M. Both passed. Both wrapped.

`simulator/src/champsim.cc:141`:

```cpp
next_phase_complete[cpu.get_cpu_num()] = next_phase_complete[...] || (cpu.sim_instr() >= length);
```

A core reaching its instruction target sets its flag — it is **not** stopped.
The phase ends only when every core's flag is set, and a finished core keeps
being ticked while the stragglers catch up. So the trace the fastest core needs
is `WARMUP + SIM` multiplied by how far it outruns the slowest.

The 150M rule was a single-core rule applied to multi-core runs.

## Measured divergence (max core / min core)

| workload | observed | max consumed | file length | verdict |
|---|---|---|---|---|
| canneal 4/8/16c | 1.06–1.07x | 162.9M | 200.0M | comfortable |
| barnes 4c | 1.07–1.08x | 163.2M | 200.0M | comfortable |
| ocean 8c | 1.02–1.10x | 172.2M | 171.8M | **at the edge** |
| water 8c (2 MB LLC) | 1.09–1.26x | 193.2M | 200.0M | survived |
| water 8c (scaled LLC) | **1.37x** | 205.5M | 200.0M | **wrapped** |

Two things make this worse than a simple sizing miss.

**It is policy-dependent.** On water, LRU diverges 1.09x, Hawkeye 1.12x, but
Mockingjay, COALESCE and `coalesce_no_mesi` all reach 1.26x — a policy that
raises IPC unevenly across cores widens the gap. So on a marginal trace, *some
policies wrap and others do not*, and a wrapped run replays its trace, inflating
reuse and therefore hit rate and IPC. **The bias runs in favour of exactly the
policies under evaluation.** Comparing a wrapped Mockingjay against an unwrapped
LRU would be worse than useless.

**A bigger cache makes it worse.** The same water jobs consumed 193M under the
2 MB LLC and 205M under the scaled one. Raising the LLC raises IPC unevenly, so
the scaled sweep needs longer traces than the unscaled one that preceded it.

## Blast radius

22 of 127 logs wrapped:

- **9 in `phaseA`, all ocean 8-core** — against the *old* 45.3M-record ocean
  traces, from before the `-n514` regeneration. Already known void; superseded
  by `phaseA_scaled`. No new loss.
- **12 in `phaseA_scaled`, water 8-core** — every policy. The whole water
  8-core scaled row is void. Short by 5.5M records, i.e. **2.8%**.
- **1 in `phaseA_scaled`, ocean 8-core `srrip`** — 172.6M consumed against a
  171.8M shortest file. Short by **0.5%**.

Everything canneal (4c, 8c, 16c) and barnes is unaffected and has a wide margin.
The jobs running now are all canneal, so nothing in flight is at risk.

`phaseA_scaled` therefore stands at 49 complete, **36 usable**.

## The fix

`check_trace_length` now takes the workload and applies a measured margin —
`trace_margin_pct` in `run_phase_a.sh`: water 150%, ocean 120%, canneal and
barnes 115%, unknown 150%. Verified to reproduce what actually happened:

    canneal 200.0M -> PASS      barnes  200.0M -> PASS
    ocean   171.8M -> REFUSE    water   200.0M -> REFUSE
    ocean    45.3M -> REFUSE    unknown 200.0M -> REFUSE

These are floors taken from observed maxima, **not predictions**. A new policy
or a larger LLC can push past them, as the scaled sweep already did. The
preflight is the cheap guard; the real one is `Reached end of trace` in the log
after the fact, which `server_status.sh` reports.

Also fixed: `server_status.sh` read one file per set and printed its count as
"records each". It is the *shortest* file that decides wrapping, so a set could
be called ok while a member of it was too short. Now reports min and max and
flags uneven sets.

## Recovering water and ocean 8-core

Both are marginal, not hopeless — 2.8% and 0.5% short.

1. **Shorten the run for these two workloads** — 50M warmup + 75M sim needs
   125M x 1.5 = 188M, inside water's 200M. Cheapest by far, and comparability
   within the water row is preserved since every policy would use it. Breaks
   the uniform 50M+100M in CLAUDE.md, so it must be reported as its own row
   with the run length stated, never merged into the main table.
2. **Regenerate longer** — ~250M records: 8 files x 16 GB = 128 GB. `/home` has
   **56 GB free** and is at 100%, so this needs `compress_traces.sh` on
   canneal_16t (203 GB) and canneal_8t (108 GB) first, which should free ~230 GB
   at the ~4:1 these achieve.
3. **Drop water 8-core** and report canneal 4/8/16c plus barnes 4c.

Option 1 for the BTP deadline, option 2 before any paper.
