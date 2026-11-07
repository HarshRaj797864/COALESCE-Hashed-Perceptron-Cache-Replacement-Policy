# Policy sanity harness

Checks that replacement policies are actually doing what they claim. Two
defects found on 2026-09-15 had both been live for months, silently, because
nothing in the tree verified policy behaviour.

Run before committing anything under `simulator/replacement/`.

This directory also holds the **dated evidence docs** (`*_2026-09-*.md`) and the
raw rows they were derived from (`*_rows_*.txt`). Every quoted number should
re-derive from those files. Index: `docs/PLAN.md` § 12 (local-only).

## `check_fill_hook.sh`

Static check. Fails if a replacement module declares no
`replacement_cache_fill`.

ChampSim splits replacement notifications across two hooks, and the split is a
trap. `inc/cache.h:475` gates `update_replacement_state` on
`hit || has_cache_fill`, while the forwarding `else` in
`impl_replacement_cache_fill` routes through that same guard with `hit=false`.
So a module without the hook is **never told about fills** — only about hits —
and the simulator reports nothing. Any policy that sets per-line state at
insertion (an RRPV, an Etr, a predicted reuse distance) is silently crippled.

Two traps come as a pair: adding the hook flips the dispatch so
`update_replacement_state` now *also* fires on `try_hit` misses, where `way` is
past-the-end. Every policy needs `if (!hit) return;` (or to keep `way` out of
the miss path). Upstream's `lru` shows the pattern.

An empty hook is fine when insertion is genuinely by inheritance — see
`replacement/srrip/srrip.h` — but it must be *declared*, so intent is explicit
and the check can tell "deliberate" from "forgotten".

Under `develop` (since 2026-09-16) the hook is pure virtual, so omitting it is
a compile error; the line numbers above describe the pre-migration fork. The
guard stays as a backstop and as the record of why.

## `check_signatures.sh`

Static check. Fails if a policy's `find_victim` will never be dispatched.

`CACHE::impl_find_victim` picks a module's method by SFINAE over a fixed list of
accepted signatures. A signature matching none of them makes `has_find_victim`
false, the dispatch falls through to `return return_type{}`, and the policy
silently becomes **always evict way 0** — it compiles, links, runs and produces
plausible numbers. That is what `random` did for the life of the project.

**This guard was itself blind until 2026-09-23.** It grepped the header for the
literal `"long find_victim"`, so a declaration returning anything else produced
no match, took a `skip` branch, and exited 0 — meaning the `random` defect
verbatim (`uint32_t find_victim(..., uint64_t ip, uint64_t full_addr,
access_type)`) was reported as "declares no find_victim" and passed. The return
type is not cosmetic: `develop` makes `find_victim` pure virtual returning
`long`, so any other return type does not override it and the dispatch never
reaches the module. An unrecognised signature also printed "check by hand" and
exited 0, indistinguishable from `ok` to `run_phase_a.sh`, which gates a
multi-day sweep on these scripts.

It now matches `find_victim` regardless of return type and fails on a wrong
return type, a declaration present only in the `.cc`, no declaration at all, or
any unrecognised form.

### Test your guards

All three were given the exact defect they exist to catch. Two caught theirs;
`check_signatures` passed its. **A guard nobody has tried to fool is a guard
with an unknown false-negative rate** — which is the same failure mode as the
policies it checks. If you change one, re-run the injection tests recorded in
`verification_2026-09-22.md` round 3.

## `check_include_path.sh`

Static check. Fails if `simulator/absolute.options` points outside this tree.

Before the `develop` migration, `config.sh` regenerated the module lists on
every run but never touched `absolute.options`, so a stale copy governed the
`-I` path forever. (Under `develop` the Makefile writes it only when it is
missing — so a stale one still survives; delete it and `make`.) One dated
2025-12-30 pointed at a sibling ChampSim checkout, and for nine months every
local build took its headers from there —
`simulator/inc/block.h` carried `uint16_t sharer_mask` for 16-core support
while the build used the sibling's `uint8_t`, making cores 8-15 invisible to
the sharer mask.

## `mockingjay_etr_probe.cc`

Standalone, no build dependencies:

```sh
g++ -O2 -o probe mockingjay_etr_probe.cc && ./probe
```

Reproduces the arithmetic of the pre-2026-09-15 Mockingjay against a synthetic
access stream and reports how often the victim is the most-recently-touched
way. The broken policy scored **100%** in every RDP state — cold, trained
toward near reuse, trained toward far reuse, all of them.

**That invariance is the signal, not the rate.** This is the regression witness
for the inversion, and it is deterministic. Do not try to reproduce it from
in-simulator counters; see below for why.

## Live counters

`mockingjay` and `hawkeye` print sanity lines at end of simulation:

```
Mockingjay: victims N bypasses N rdp_entries N
Mockingjay: fills N hits N
Mockingjay: victim Etr  overdue(negative) X%  distant-reuse(positive) Y%  zero Z%

Hawkeye: fills N hits N detrains N
Hawkeye: OPTgen hits N accesses N hit rate X%
```

Two of these are real health checks, and both catch the missing-fill-hook class
of bug:

- **`fills 0`** — the insertion hook is not wired up; the policy is learning
  nothing.
- **`rdp_entries 0`** / **`OPTgen accesses 0`** — the predictor never trained.

The rest is context. For Mockingjay, victims should be mostly *overdue*
(negative Etr, predicted reuse already passed); a run with almost no negative
victims would mean the Etr counters are not ageing.

### A counter that was removed, and why

An earlier version printed "victim was most-recently-touched way X%" with the
claim that it should sit near `1/NUM_WAY`. **Both the claim and the measurement
were wrong**, and it cost a false alarm on an otherwise healthy run.

The measurement is meaningless once a policy bypasses. On a bypassed fill no
line is installed, so the recorded "last touched way" goes stale and ends up
naming whichever line has aged longest — which is precisely the line that
*should* be evicted. On `429.mcf` bypasses outnumbered victims, and the counter
read 50–62% while every other signal said the policy was correct.

The lesson generalises: a sanity counter that can be driven by correct
behaviour is worse than no counter, because it trains you to ignore it.

### COALESCE's counters

COALESCE prints, at end of run:

```
COALESCE: ghost_inserts N ghost_rescues N (X% of inserts)  detrains N  hit_trains N
COALESCE BIAS EXPOSURE: cand_modified N victim_modified N  cand_biased N victim_biased N
```

**A non-zero `ghost_rescues` did not mean the rescue worked.** Until `97aa5da`
(2026-09-23) the ghost tag carried no address bits, and the rescue fired on
lines that had never been evicted — the counter was non-zero *because of* the
defect. `scripts/check_policy_internals.sh` reads all of these from completed
logs; it proves a path runs, not that it is right. DRRIP and SHiP (upstream
`develop`'s code) print nothing yet.

## COALESCE probes

Both link the real compiled policy objects, not replicas, and both carry a
negative control that must fail — a check that cannot fail proves nothing.

- `coalesce_ghost_probe.cc` — the ghost tag, the Bloom filter and the stored
  allocating PC. Built with `-DCALLER_PASSES_LINE_ADDR` it reproduces the pre-fix
  calling convention and **must fail**.
- `coalesce_ablation_probe.cc` — each ablation's hashes must equal the full
  policy's with that one feature set to zero (0 of 200,000 PCs differ). The
  negative control, the pre-fix ablation hash, must differ, and does on 199,810
  of 200,000.

Build lines are in each file's header (run from `simulator/` after `make`).

## Single-core validation (A4) — built

`scripts/run_a4.sh` + `run_a4.sh.py`: 11 policies × 12 LLC-sensitive SPEC
CPU2006 SimPoints, 132/132 complete on 2026-09-21
(`a4_results_2026-09-21.md`). Report **load** hit rate, not total — on
`429.mcf` the total LLC hit rate reads LRU 28.1% vs Hawkeye 8.7%, which looks
inverted purely because LRU hits 99.9% of L2 writebacks and everyone else ~2%.
Load hit rate tells the true story (LRU 1.7%, SRRIP 12.6%, Hawkeye 12.4%).
