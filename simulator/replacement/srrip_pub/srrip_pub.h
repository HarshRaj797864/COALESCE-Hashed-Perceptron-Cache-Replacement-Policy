#ifndef REPLACEMENT_SRRIP_PUB_H
#define REPLACEMENT_SRRIP_PUB_H

// SRRIP with the published insertion (bench/policy_sanity/srrip_pub_design_2026-11-18.md):
// upstream's replacement/srrip, unchanged but for replacement_cache_fill, which
// inserts at RRPV maxRRPV - 1 = 2 (Jaleel et al., ISCA 2010, SRRIP-HP, M = 2).
// Upstream's fill hook is empty, so its filled lines keep the victim's RRPV, 3
// (srrip_insertion_diagnosis_2026-11-11.md). Renamed types: every module links
// into one binary.

#include <cstdint>
#include <vector>

#include "cache.h"
#include "modules.h"

struct srrip_pub_set_helper {
  using rrpv_type = int;
  static constexpr rrpv_type maxRRPV = 3;

  std::vector<rrpv_type> rrpv_values;
  rrpv_type& get_rrpv(long way);

  explicit srrip_pub_set_helper(long ways);

  long victim();
  void update(long way, bool hit);
};

struct srrip_pub : public champsim::modules::replacement {

  std::vector<srrip_pub_set_helper> sets;
  uint64_t fills = 0;        // QS1: fills seen by the hook
  uint64_t fills_at_2 = 0;   // ... and those left at RRPV maxRRPV - 1

  explicit srrip_pub(champsim::modules::ModuleBuilder builder);
  srrip_pub(champsim::modules::cache_module* cache, long sets_, long ways_);

  void initialize_replacement() override {}
  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type) override;
  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                access_type type, bool hit) override;
  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                              access_type type) override;
  void replacement_final_stats() override;
};

#endif
