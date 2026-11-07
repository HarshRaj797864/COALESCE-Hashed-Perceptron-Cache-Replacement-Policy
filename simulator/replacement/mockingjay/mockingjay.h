// Mockingjay cache replacement policy.
//
// Faithful port of the authors' released artifact:
//   Ishan Shah, Akanksha Jain, Calvin Lin, "Effective Mimicry of Belady's MIN
//   Policy", HPCA 2022.  Artifact: https://github.com/ishanashah/Mockingjay
//   (file `mockingjay.llc_repl`, old-ChampSim `CACHE::llc_*` interface).
//
// This file is a REWRITE (2026-09-15).  The previous implementation was
// structurally inverted and behaved as an MRU-eviction policy; see
// `docs/PLAN.md` § 0 and `bench/policy_sanity/mockingjay_etr_probe.cc`.
// The five defects that mattered:
//
//   1. find_victim ranked by max(Etr) instead of max(|Etr|) with a tie-break
//      toward the most negative.  Since update_replacement_state refreshes the
//      touched line's Etr while ageing every other line, max(Etr) is always the
//      line just touched -> MRU eviction, 100% of the time.
//   2. Etr decayed on every access instead of once per GRANULARITY accesses to
//      the set, so Etr (carried in quanta) burned ~16x too fast and pinned at
//      the floor.
//   3. No bypass.  The reference declines to allocate when the predicted reuse
//      distance exceeds MAX_RD or exceeds every resident line's Etr.
//   4. RDP trained by +/-1 saturation instead of the reference's
//      temporal_difference(), and there was no detrain() on unreused eviction
//      from the sampled cache.
//   5. Constants far off the reference: MAX_DISTANCE 31 vs MAX_RD 105,
//      ETR range +/-31 vs +/-INF_ETR (15 for a 16-way cache).
//
// Interface note.  The artifact has ONE hook, called on every hit and every
// fill.  Modern ChampSim splits that in two, and the split is a trap:
// inc/cache.h:475 gates update_replacement_state on `hit || has_cache_fill`,
// so a module WITHOUT replacement_cache_fill is never told about fills at all
// (the forwarding `else` in impl_replacement_cache_fill is dead code).  That is
// what crippled this policy and several others; see docs/PLAN.md.
//
// So we implement BOTH, and both funnel into handle_access().  Because we now
// have a fill hook, update_replacement_state is also invoked from try_hit on
// MISSES, where `way` is past-the-end — hence the `if (!hit) return;` guard,
// the same one upstream's lru uses.
//
// Documented deviations from the artifact (kept deliberately):
//   * The RDP is an unbounded unordered_map keyed by PC signature, exactly as
//     in the released artifact.  This is not hardware-realisable, but it is
//     what produced the published numbers, so it is what we reproduce.  Report
//     it as a deviation in the paper's methodology, not as our design choice.
//   * FLEXMIN_PENALTY is applied to prefetch samples.  Our LLC configuration
//     runs without a prefetcher, so this path is inert here.

#ifndef REPLACEMENT_MOCKINGJAY_H
#define REPLACEMENT_MOCKINGJAY_H

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "cache.h"
#include "modules.h"

struct mockingjay : public champsim::modules::replacement {
  // -- Reference constants (mockingjay.llc_repl lines 11-24) -----------------
  static constexpr int HISTORY = 8;
  static constexpr int GRANULARITY = 8;
  static constexpr int SAMPLED_CACHE_WAYS = 5;
  static constexpr int LOG2_SAMPLED_CACHE_SETS = 4;
  static constexpr int TIMESTAMP_BITS = 8;
  static constexpr double TEMP_DIFFERENCE = 1.0 / 16.0;

  // -- Geometry, derived at construction from the real cache -----------------
  long NUM_SET = 0;
  long NUM_WAY = 0;
  int LOG2_LLC_SET = 0;
  int LOG2_LLC_SIZE = 0;
  int LOG2_SAMPLED_SETS = 0;
  int SAMPLED_CACHE_TAG_BITS = 0;
  int PC_SIGNATURE_BITS = 0;
  int LOG2_BLOCK = 0;  // copy of ChampSim's global LOG2_BLOCK_SIZE (extern const unsigned)

  int INF_RD = 0;   // LLC_WAY * HISTORY - 1
  int INF_ETR = 0;  // (LLC_WAY * HISTORY / GRANULARITY) - 1
  int MAX_RD = 0;   // INF_RD - 22
  double FLEXMIN_PENALTY = 0.0;

  // -- State -----------------------------------------------------------------
  std::vector<int> etr;                // NUM_SET * NUM_WAY
  std::vector<int> etr_clock;          // NUM_SET
  std::vector<int> current_timestamp;  // NUM_SET

  std::unordered_map<uint64_t, int> rdp;

  struct SampledCacheLine {
    bool valid = false;
    uint64_t tag = 0;
    uint64_t signature = 0;
    int timestamp = 0;
  };
  std::unordered_map<uint32_t, std::vector<SampledCacheLine>> sampled_cache;

  // -- Sanity counters (printed by replacement_final_stats) ------------------
  // stat_fills and rdp.size() are the load-bearing ones: zero fills means the
  // insertion hook is not wired up, zero rdp entries means the predictor never
  // trained.  See bench/policy_sanity/.
  uint64_t stat_victims = 0;
  uint64_t stat_bypasses = 0;
  uint64_t stat_fills = 0;
  uint64_t stat_hits = 0;
  uint64_t stat_victim_etr_pos = 0;   // victim predicted for distant future reuse
  uint64_t stat_victim_etr_neg = 0;   // victim overdue: predicted reuse already passed
  uint64_t stat_victim_etr_zero = 0;

  explicit mockingjay(champsim::modules::ModuleBuilder builder);

  void initialize_replacement() override {}

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type) override;

  // Insertion hook.  MUST exist: without it ChampSim never tells this policy
  // about fills (inc/cache.h:475 gates update_replacement_state on
  // `hit || has_cache_fill`), and Etr — which is set at insertion — never gets
  // initialised.  Upstream made this pure virtual in `develop` (f7c01d58).
  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                              access_type type) override;

  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                access_type type, bool hit) override;

  void replacement_final_stats() override;

private:
  // The artifact's single llc_update_replacement_state body, shared by both
  // hooks above.
  void handle_access(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, access_type type, bool hit);

  bool is_sampled_set(long set) const;
  uint64_t get_pc_signature(uint64_t pc, bool hit, bool prefetch, uint32_t core) const;
  uint32_t get_sampled_cache_index(uint64_t full_addr) const;
  uint64_t get_sampled_cache_tag(uint64_t x) const;
  int search_sampled_cache(uint64_t block_address, uint32_t set);
  void detrain(uint32_t set, int way);
  int temporal_difference(int init, int sample) const;
  int increment_timestamp(int input) const;
  int time_elapsed(int global, int local) const;
};

#endif
