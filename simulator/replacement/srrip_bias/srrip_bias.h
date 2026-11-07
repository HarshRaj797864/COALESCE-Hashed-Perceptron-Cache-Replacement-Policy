// SRRIP augmented with a coherence-state / sharer-count retention bias.
//
// This exists to answer HiPC #275 Reviewer 1 directly:
//   "How does an S/D-RRIP policy augmented with the sharer-count biases
//    perform relative to COALESCE?"
//
// Design intent: be SRRIP in every respect except the coherence bias, so the
// comparison isolates exactly one variable.
//   * Insertion is by inheritance from the aged victim way, identical to
//     ChampSim's SRRIP -- hence the deliberately empty replacement_cache_fill.
//   * Ageing and hit promotion are SRRIP's.
//   * The ONLY difference is that victim selection ranks by an effective RRPV
//     that subtracts a bias for MODIFIED lines and for lines with >= 2 sharers.
//
// The bias is GRADED, not a veto. An earlier version of this file skipped
// MODIFIED-or-shared lines entirely when searching for a victim, which under
// canneal's sharing left almost no evictable ways, collapsed effective
// capacity, and starved cores -- the 8-core run never completed. A reviewer
// reading that code would rightly call it a strawman. A graded bias prefers to
// retain coherence-expensive lines while still allowing them to be evicted
// when everything else in the set is more valuable.
//
// The bias magnitudes mirror COALESCE's vote bias (+40 for MODIFIED,
// +20 x sharers for sharers >= 2, i.e. equal weight at two sharers) scaled into
// RRPV space, which spans only 0..3. They are a design choice, not a derived
// constant, and are exposed here so they can be swept.

#ifndef SRRIP_BIAS_H
#define SRRIP_BIAS_H

#include <vector>

#include "cache.h"
#include "modules.h"

struct srrip_bias : champsim::modules::replacement {
  using rrpv_type = int;
  static constexpr rrpv_type maxRRPV = 3;

  // Coherence retention bias, subtracted from a line's RRPV when ranking
  // victims. Larger = more strongly retained.
  static constexpr rrpv_type BIAS_MODIFIED = 1;
  static constexpr rrpv_type BIAS_SHARED = 1;   // applied when sharers >= 2
  static constexpr int SHARED_THRESHOLD = 2;

  long NUM_SET = 0;
  long NUM_WAY = 0;
  std::vector<rrpv_type> rrpv_values;

  explicit srrip_bias(champsim::modules::ModuleBuilder builder);
  srrip_bias(long sets, long ways);

  void initialize_replacement() override {}

  rrpv_type& get_rrpv(long set, long way);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type) override;

  // Deliberately empty: insertion is by inheritance from the aged victim way,
  // exactly as in ChampSim's SRRIP. Declared rather than omitted because a
  // replacement module without this hook is never told about fills at all
  // (inc/cache.h:475), and that silence is what crippled several policies here.
  void replacement_cache_fill(uint32_t /*triggering_cpu*/, long /*set*/, long /*way*/, champsim::address /*full_addr*/, champsim::address /*ip*/,
                              champsim::address /*victim_addr*/, access_type /*type*/) override
  {
  }

  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                access_type type, bool hit) override;

  void replacement_final_stats() override {}
};

#endif
