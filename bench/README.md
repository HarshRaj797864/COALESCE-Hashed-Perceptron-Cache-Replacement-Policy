# bench/ — synthetic validation harness

Purpose: prove the VMEM shared-overlay mechanism delivers cross-CPU sharing end-to-end, before re-running canneal with overlay enabled. Without this validation, a non-zero canneal result under shared VMEM could be either (a) the mechanism working or (b) a bug in the overlay or instrumentation. The synthetic bench has known-shared addresses and known-expected outcomes per mode, so it pins down (a) vs (b).

See `docs/OPEN_DECISIONS.md` item #17 and `/home/rajharsh/.claude/plans/ok-analyzew-the-entire-crystalline-reef.md` for the design rationale.

## Files

- `synth_coherence.c` — pthread program with three deterministic sharing modes (A=private, B=producer/consumer, C=read-mostly-migratory).
- `synth_coherence` — compiled binary (`gcc -O0 -pthread -Wall synth_coherence.c -o synth_coherence`).

## The three modes

| Mode | What it does | Expected sharer-hist | Expected invalidations | Role |
|---|---|---|---|---|
| **A** | Each thread reads/writes a stack-local 4 KB array | bin[1] dominant (even under shared VMEM) | 0 | **Negative control** — proves overlay is workload-driven, not a synthetic inflator |
| **B** | tid=0 produces, tid=1..7 consume cacheline-isolated cells | bin[2..N] populated under shared VMEM; bin[1] without | >> 0 under shared VMEM | **Positive case** — the mechanism's smoking-gun demonstration |
| **C** | All threads round-robin read a 64 KB shared const array | high bins under shared VMEM | 0 (no writes) | **Read-only sharing** — populates sharer_mask without spurious invalidations |

## Build

```bash
cd bench/
gcc -O0 -pthread -Wall synth_coherence.c -o synth_coherence
./synth_coherence A 200000   # smoke test (~10 ms)
```

`-O0` keeps the loop body intact so PIN sees the memory accesses as written.

## Trace with PIN MT-Sync (server-side)

PIN MT-Sync lives at `simulator/tracer/pin/champsim_tracer.cpp`. Build it once on the server:

```bash
cd simulator/tracer/pin
make PIN_ROOT=$PIN_ROOT obj-intel64/champsim_tracer.so
```

Then trace each mode, 200 k iterations per thread (~2 M instructions each):

```bash
# from repo root
for mode in A B C; do
  $PIN_ROOT/pin -t simulator/tracer/pin/obj-intel64/champsim_tracer.so \
    -o simulator/traces/synth_mode${mode} \
    -- bench/synth_coherence $mode 200000
done
```

Produces `simulator/traces/synth_modeA{0..7}.champsimtrace`, `synth_modeB*`, `synth_modeC*`.

## ChampSim run matrix (per Plan section "Validation plan")

| Run | Mode | VMEM | Policy | Pass criterion |
|---|---|---|---|---|
| V1 | A | private | LRU | sharer_hist[1] = 100%, invalidations=0, aliased_fills=0 |
| V2 | A | shared (cpus 0..7) | LRU | sharer_hist[1] = 100%, invalidations=0, aliased_fills=0 (private workload + shared VMEM = no synthetic inflation) |
| V3 | B | private | LRU | sharer_hist[1] = 100% (current canneal behavior reproduces) |
| V4 | B | shared | LRU | sharer_hist[k≥2] > 0, invalidations > 0, aliased_fills > 0 — **mechanism fires** |
| V5 | B | shared | COALESCE | same as V4, plus COALESCE IPC distinguishable from V4 LRU IPC |
| V6 | C | shared | LRU | high sharer bins, invalidations=0 |

For each run, in addition to the existing `RESULTS_*.md` summary pattern, capture:
- `LLC COHERENCE INVALIDATIONS: X`
- `LLC COHERENCE WRITE-HIT OTHER-SHARER EVENTS: X`
- `LLC SHARER HIST TOTAL` + per-bin
- `VMEM ALIASED FILLS (cross-CPU shared-page hits): X`

All printed by the patched plain_printer. The smoking-gun number to grep is `VMEM ALIASED FILLS`.

## Config for shared runs

Use `simulator/btp_config.json` or `btp_8core_config.json` with `vmem_shared_cpus` populated, e.g.:

```json
"virtual_memory": { "vmem_shared_cpus": [0, 1, 2, 3, 4, 5, 6, 7] }
```

Empty list (`[]`) preserves existing private-VMEM behavior. The two configs ship with the empty default so existing 4-core / 8-core canneal results don't change.
