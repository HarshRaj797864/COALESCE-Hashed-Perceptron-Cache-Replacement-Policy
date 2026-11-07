#!/usr/bin/env python3
"""Generate a ChampSim run config for the COALESCE evaluation.

develop configures at runtime, so there is one binary (bin/champsim) and configs
are plain data. This replaces the old `config.sh <cfg> && make` workflow, which
compiled one binary per policy.

Usage:
    scripts/make_config.py --policy coalesce --cores 8 --regime shared  -o cfg.json
    bin/champsim --config cfg.json --warmup-instructions N --simulation-instructions M <traces...>

`--regime shared` populates vmem_shared_cpus with every core, enabling the
shared-VMEM overlay -- this is the paper's evaluation. `--regime private` leaves
it empty, which is stock ChampSim and the regime-1 control.

A run with the overlay active prints a non-zero `VMEM ALIASED FILLS`. Zero means
it did not engage, and the run is measuring the wrong regime.
"""
import argparse
import json
import sys

POLICIES = [
    "coalesce", "coalesce_no_mesi", "coalesce_no_sharer",
    "lru", "srrip", "drrip", "ship", "hawkeye", "mockingjay", "srrip_bias", "random",
]


def _physical_memory_bytes(cores: int) -> int:
    """Page pool sized as the historical configs did: 4 GiB up to 4 cores, 16 GiB beyond.

    Whether 16 GiB is actually enough at 16 cores is an open question -- if the
    original 16-core run exhausted its pool, some of its 23.9M invalidations
    were page recycling rather than sharing. run_phase_a.sh flags any run whose
    log carries the exhaustion warning, so this is settled by measurement.
    """
    return 4 * 1024**3 if cores <= 4 else 16 * 1024**3


def _llc_sets(cores: int, per_core_mb: float | None) -> int:
    """Sets for a 16-way, 64 B-line LLC.

    Default (per_core_mb is None) reproduces the historical configs exactly:
    2048 sets x 16 ways x 64 B = 2 MB, at EVERY core count. That is 0.5 MB per
    core at 4 cores and 0.125 MB at 16, where real parts carry 1-2 MB per core,
    so the 16-core configuration is roughly an order of magnitude undersized.

    It shows: private-VMEM LLC hit rate on canneal falls 12.21% -> 0.93% ->
    0.24% across 4/8/16 cores. At a 0.24% hit rate no replacement policy can
    matter, because nothing survives to be reused. That confounds the
    regime comparison -- part of the private/shared gap is the shared overlay
    shrinking the working set, and part is simply a cache too small to hold
    sixteen independent ones.

    Passing per_core_mb scales the cache with the core count so the two can be
    separated. If the regime difference survives a properly sized LLC it is
    real; if it vanishes, it was cache pressure.
    """
    total_mb = 2.0 if per_core_mb is None else per_core_mb * cores
    sets = int(total_mb * 1024 * 1024) // (16 * 64)
    if sets & (sets - 1):
        raise SystemExit(f"LLC of {total_mb} MB gives {sets} sets, which is not a power of two")
    return sets


def build(policy: str, cores: int, regime: str, llc_per_core_mb: float | None = None,
          private_coherence: int = 0, coherence_latency: int = 0, sync_mutex_order: str | None = None,
          llc_mshr: int | None = None) -> dict:
    """Mirror the historical btp_config.json hierarchy so results stay comparable."""
    if coherence_latency and private_coherence != 2:
        raise SystemExit("--coherence-latency needs --private-coherence 2")
    lvl1 = {"sets": 64, "ways": 8, "rq_size": 64, "wq_size": 64, "pq_size": 32,
            "mshr_size": 8, "latency": 4, "prefetcher": "no", "replacement": "lru"}
    return {
        "num_cores": cores,
        "block_size": 64,
        "page_size": 4096,
        "heartbeat_frequency": 10000000,
        "L1I": dict(lvl1),
        "L1D": dict(lvl1),
        "L2C": {"sets": 1024, "ways": 8, "rq_size": 32, "wq_size": 32, "pq_size": 16,
                "mshr_size": 16, "latency": 10, "prefetcher": "no", "replacement": "lru"},
        "LLC": {"sets": _llc_sets(cores, llc_per_core_mb), "ways": 16, "rq_size": 32, "wq_size": 32, "pq_size": 16,
                "mshr_size": llc_mshr if llc_mshr else 16, "latency": 20, "prefetcher": "no", "replacement": policy},
        # Physical memory sizes the page pool, and the pool matters here more
        # than it looks. When VirtualMemory exhausts it, vmem.cc's ppage_pop
        # prints "[VMEM] WARNING: Out of physical memory, freeing ppages" and
        # REPOPULATES the free list -- the same physical pages are handed out
        # again. Under the shared-VMEM overlay two virtual pages landing on one
        # recycled physical page are indistinguishable from genuine sharing to a
        # physically-indexed LLC, so an undersized pool fabricates exactly the
        # aliasing and invalidation traffic this evaluation measures.
        #
        # These match the historical configs (btp_config 4 GiB at 4 cores,
        # btp_8core_shared and btp_16core_shared 16 GiB) so numbers stay
        # comparable. A hard-coded 4 GiB was being used at every core count,
        # which left 8- and 16-core runs with a quarter of the intended pool.
        "physical_memory": {"size": _physical_memory_bytes(cores), "latency": 50},
        "virtual_memory": {"vmem_shared_cpus": list(range(cores)) if regime == "shared" else []},
        # Private-cache coherence (inc/sharer_directory.h; B3 v4). 0 is the
        # simulator as it was. A binary older than B3 v4 IGNORES this key, so
        # check the run's log: it must print "PRIVATE-CACHE COHERENCE LEVEL".
        "private_coherence": private_coherence,
        # C0 (c0_latency_design_2026-10-14.md): cycles an ownership request
        # waits for its invalidations. Written only when set, so every other
        # config is byte-identical to before; a binary without C0 ignores it,
        # so the log must print "COHERENCE INVALIDATION LATENCY (CYCLES)".
        **({"coherence_latency": coherence_latency} if coherence_latency else {}),
        # Synchronised replay (sync_mutex_design_2026-10-19.md): who takes a
        # mutex next. Absent means "timing", the simulator's default; written
        # only when given, so every other config is byte-identical to before.
        **({"sync_mutex_order": sync_mutex_order} if sync_mutex_order else {}),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--policy", required=True, choices=POLICIES)
    ap.add_argument("--cores", type=int, required=True)
    ap.add_argument("--regime", choices=["shared", "private"], required=True,
                    help="shared = the paper's evaluation; private = the regime-1 control")
    ap.add_argument("--llc-per-core-mb", type=float, default=None,
                    help="scale the LLC with core count instead of the historical fixed 2 MB "
                         "(e.g. 2 gives 8 MB at 4 cores, 32 MB at 16). Omit for the "
                         "historical geometry.")
    ap.add_argument("--private-coherence", type=int, choices=[0, 1, 2], default=0,
                    help="0 = none (default); 1 = an ownership request reaching the LLC "
                         "invalidates other cores' private copies; 2 = 1, plus a store that "
                         "hits a shared private copy takes the line too (the upgrade)")
    ap.add_argument("--coherence-latency", type=int, default=0,
                    help="C0: cycles a request that must take a line from other cores waits "
                         "for the invalidations (needs --private-coherence 2; 0 = none, the default)")
    ap.add_argument("--sync-mutex-order", choices=["timing", "recorded"], default=None,
                    help="synchronised replay: a mutex goes to whichever core the simulated timing "
                         "brings first (timing, the simulator's default when omitted) or in the "
                         "traced run's order (recorded). Only traces whose mutex records carry "
                         "addresses are affected")
    ap.add_argument("--llc-mshr", type=int, default=None,
                    help="the LLC's MSHRs (default 16, as every earlier run; the step-5 sensitivity run uses 64)")
    ap.add_argument("-o", "--output", help="write here instead of stdout")
    args = ap.parse_args()

    text = json.dumps(build(args.policy, args.cores, args.regime, args.llc_per_core_mb,
                            args.private_coherence, args.coherence_latency, args.sync_mutex_order, args.llc_mshr), indent=2) + "\n"
    if args.output:
        with open(args.output, "w") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
