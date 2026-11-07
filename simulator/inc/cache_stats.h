#ifndef CACHE_STATS_H
#define CACHE_STATS_H

#include <cstdint>
#include <string>
#include <type_traits>
#include <utility>

#include "access_type.h"
#include "champsim.h"
#include "event_counter.h"

struct cache_stats {
  std::string name;
  // prefetch stats
  uint64_t pf_requested = 0;
  uint64_t pf_issued = 0;
  uint64_t pf_useful = 0;
  uint64_t pf_useless = 0;
  uint64_t pf_fill = 0;

  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> hits = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> misses = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> miss_merge = {};
  champsim::stats::event_counter<std::pair<access_type, std::remove_cv_t<decltype(NUM_CPUS)>>> fill = {};

  // -- COALESCE coherence counters -------------------------------------------
  // Synthetic invalidation accounting. Counts sharer_mask bits cleared on a
  // write hit to a multi-sharer line. LLC bookkeeping only: ChampSim models no
  // inter-level coherence, so the "invalidated" cores' L1/L2 tags still hold
  // stale copies. See coalesce_paper/COHERENCE_HOOK_AUDIT.md.
  uint64_t coherence_invalidations = 0;

  // Count of write-hit *events* that found other sharers, as distinct from the
  // number of bits cleared above. Separates "rare multi-sharer events with many
  // bits each" from "frequent two-sharer events".
  uint64_t coherence_write_hit_other_sharer_events = 0;

  // STORE-TIME counterpart of the two counters above, for the gem5 comparison
  // (bench/policy_sanity/phaseB_metric_semantics_2026-09-23.md). Both counters
  // above fire when an L2 WRITEBACK reaches the LLC, which can be long after
  // the store, or never within a run. gem5 counts at the store request
  // (L2 SS.L1_GETX + MT.L1_GETX). A store that misses the private hierarchy
  // reaches the LLC as an RFO, so the fair counterpart is an RFO hit whose
  // sharer mask names other cores. Instrumentation only: the mask and state
  // are updated exactly as before.
  //   ..._events   per RFO hit that finds other sharers (gem5 counts per event)
  //   ..._sharers  total other-sharer bits those RFOs saw
  // Not counted, because the LLC cannot see them: a store to a line its core
  // already holds privately (gem5's L1_UPGRADE; 73% of gem5's events on ocean
  // 4c), and an RFO that misses the LLC (non-inclusive -- other cores may still
  // hold the line privately with no sharer record left).
  uint64_t coherence_rfo_hit_other_sharer_events = 0;
  uint64_t coherence_rfo_hit_other_sharers = 0;

  // B3 v2: the sharer directory (sharer_directory.h), independent of LLC
  // residency. Store-time, per RFO reaching the LLC, counted once per request:
  //   presence  another core's private caches hold the line (stale copies
  //             included: ChampSim never invalidates them -> overcounts)
  //   protocol  the MESI-style sharer view lists another core (a stale
  //             private hit never re-registers -> undercounts)
  // Incremented at the LLC only.
  uint64_t coherence_dir_rfo_presence_events = 0;
  uint64_t coherence_dir_rfo_presence_others = 0;
  uint64_t coherence_dir_rfo_protocol_events = 0;
  uint64_t coherence_dir_rfo_protocol_others = 0;
  // Self-check, written at end of phase: for a private data cache, the number
  // of mismatches between its valid blocks and the directory's presence bits
  // for it (must be 0); for the LLC, the number of private caches registered
  // (must be 3 x cores).
  uint64_t coherence_dir_selfcheck_mismatches = 0;
  uint64_t coherence_dir_registered = 0;

  // B3 v4: coherent private caches (sharer_directory.h; all 0 at
  // private_coherence 0). Counted in the private cache concerned:
  //   copies_invalidated  blocks this cache dropped because another core took
  //                       the line
  //   upgrade_*           stores and RFOs that HIT this cache while another
  //                       core was listed in the protocol view (events, and
  //                       the cores listed), or held a copy (presence_events).
  //                       gem5's counterpart of the first is L2 SS.L1_UPGRADE.
  //   stale_fills         fills dropped on arrival: another core had taken
  //                       the line while they were in flight
  // and at the LLC, written at end of phase:
  //   stale_holders       cores holding a line they are marked stale for
  //                       (must be 0)
  uint64_t coherence_dir_copies_invalidated = 0;
  uint64_t coherence_dir_upgrade_events = 0;
  uint64_t coherence_dir_upgrade_cores = 0;
  uint64_t coherence_dir_upgrade_presence_events = 0;
  uint64_t coherence_dir_stale_fills = 0;
  uint64_t coherence_dir_stale_holders = 0;
  // C0 (c0_latency_design_2026-10-14.md): requests that waited
  // coherence_latency cycles for their invalidations. Printed only when the
  // latency is set.
  uint64_t coherence_latency_waits = 0;
  // Diagnosis, records only (b3_bounded_design_2026-10-17.md): store misses at
  // the LLC, and upgrades, for which the BOUNDED protocol view (it forgets a
  // line's cores once the line is held nowhere on chip) lists another core.
  uint64_t coherence_dir_rfo_bounded_events = 0;
  uint64_t coherence_dir_upgrade_bounded_events = 0;
  // Step 3, records only (b3_g5rule_design_2026-10-19.md): the same for the
  // gem5-rule view, with the cores it lists; and the lines where the views'
  // order (gem5-rule <= bounded <= protocol) fails, which must be 0.
  uint64_t coherence_dir_rfo_g5_events = 0;
  uint64_t coherence_dir_rfo_g5_cores = 0;
  uint64_t coherence_dir_upgrade_g5_events = 0;
  uint64_t coherence_dir_upgrade_g5_cores = 0;
  uint64_t coherence_dir_view_order_violations = 0;
  // Amendment 2 (2026-10-27): ownership hits that silently re-listed their
  // core in the gem5-rule view only, and the violating lines split into
  // those explained by it and the rest (must be 0).
  uint64_t coherence_dir_upgrade_g5_silent = 0;
  uint64_t coherence_dir_view_order_by_silent = 0;
  uint64_t coherence_dir_view_order_unexplained = 0;

  // Sharer-count histogram, indexed by popcount(sharer_mask), recorded in the
  // replacement policy's per-way scan. Establishes whether cross-core sharing
  // actually occurs in a workload.
  uint64_t coherence_sharer_hist[17] = {0};

  long total_miss_latency_cycles{};
};

cache_stats operator-(cache_stats lhs, cache_stats rhs);

namespace champsim
{
struct cache_queue_stats {
  uint64_t RQ_ACCESS = 0;
  uint64_t RQ_FULL = 0;
  uint64_t RQ_TO_CACHE = 0;
  uint64_t PQ_ACCESS = 0;
  uint64_t PQ_FULL = 0;
  uint64_t PQ_TO_CACHE = 0;
  uint64_t WQ_ACCESS = 0;
  uint64_t WQ_FULL = 0;
  uint64_t WQ_TO_CACHE = 0;
};
} // namespace champsim

#endif
