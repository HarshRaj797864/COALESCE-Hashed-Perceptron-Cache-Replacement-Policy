// Hawkeye cache replacement policy.
//
// Faithful port of the CRC2 artifact for:
//   Akanksha Jain and Calvin Lin, "Back to the Future: Leveraging Belady's
//   Algorithm for Improved Cache Replacement", ISCA 2016, and
//   "Hawkeye: Leveraging Belady's Algorithm for Improved Cache Replacement",
//   Cache Replacement Championship 2 (CRC2), 2017.
//
// Ported from hawkeye_algorithm.cc + optgen.h + hawkeye_predictor.h +
// helper_function.h, cross-checked constant-by-constant against Table 1 of the
// CRC2 paper ("Hawkeye hardware budget, 16-way 2MB LLC"):
//
//   Sampler              2800 entries, 4-byte entry            11.2 KB
//   Hawkeye Predictor    2 predictors, 2K entries, 5-bit        2.56 KB
//   Occupancy Vector     64 vectors, 128 entries each           4 KB
//   Replacement state    3-bit RRIP per line                   12 KB
//   Sampled-line state   1-bit prefetch + 11-bit signature      1.5 KB
//
// This file is a REWRITE (2026-09-15). The previous implementation was a
// from-scratch reimplementation that diverged from the published policy in
// thirteen respects and produced results byte-identical to SRRIP on 429.mcf --
// same IPC, same cycle count -- because it was running the same degenerate
// algorithm. The defects that mattered:
//
//   H1  No replacement_cache_fill hook, so ChampSim never reported fills
//       (inc/cache.h:475 gates update_replacement_state on
//       `hit || has_cache_fill`) and the insertion RRPV was never set.
//   H2  No detraining on eviction, and no per-line PC signature to detrain
//       with. CRC2 paper section 2.3 specifies it: "...evicts the line with
//       the highest RRIP value (oldest cache-friendly line) and detrains its
//       corresponding load instruction if the evicted line is present in the
//       sampler."
//   H3  Ageing ran unconditionally on every access. It must run only on a
//       MISS, only for a cache-friendly insertion, and only while no line has
//       already reached MAXRRIP-1.
//   H4  Ageing also ran on hits, where the reference does not age at all.
//   H7  OPTgen capacity was NUM_WAY; the artifact uses NUM_WAY - 2.
//   H8  Predictor was 8192 entries of 3 bits initialised to 0 (maximally
//       cache-friendly); the reference is 2048 entries of 5 bits initialised
//       to 16 (neutral).
//   H9  One predictor instead of the reference's separate demand and prefetch
//       predictors.
//   H11 Sampler held 512 entries indexed by cache set; the reference holds
//       2800 entries over 350 sets indexed by address, with an explicit LRU
//       field.
//   H13 Per-CPU predictors. CRC2 paper section 4.1 is explicit that the
//       multi-core configuration uses "a single occupancy vector and a single
//       predictor to reconstruct and learn OPT's solution for the interleaved
//       access stream from the past".
//
// Deliberate adaptations to this simulator, none of them silent:
//
//   * Hook split. The artifact has one hook called on every hit and every
//     fill; modern ChampSim splits that in two. We implement BOTH
//     replacement_cache_fill and update_replacement_state and funnel them into
//     handle_access(). Because the fill hook now exists, update_replacement_state
//     is also invoked from try_hit on MISSES, where `way` is past-the-end --
//     hence the `if (!hit) return;` guard, the same one upstream's lru uses.
//   * access_type::WRITE is ChampSim's writeback and maps to the artifact's
//     WRITEBACK: early return, RRPV untouched.
//   * The predictor's lazily-initialised std::map is a flat vector initialised
//     to (MAX_PCMAP+1)/2. Exactly equivalent: the artifact's "not found" path
//     returns cache-friendly, and 16 >= 16 is cache-friendly.
//   * The prefetch-aware machinery is ported even though both btp_config.json
//     and btp_8core_config.json set "prefetcher": "no" at the LLC, so no
//     PREFETCH access ever reaches this module. Ported so the policy stays
//     correct if a prefetcher is ever enabled.
//
// Disclosed constant: the artifact initialises OPTgen with a capacity of
// LLC_WAYS - 2 rather than LLC_WAYS. The paper states only that OPTgen checks
// whether "there is enough space in the cache" (section 2.1), so this comes
// from the artifact, not the text. Followed as-is.

#ifndef REPLACEMENT_HAWKEYE_H
#define REPLACEMENT_HAWKEYE_H

#include <cstdint>
#include <map>
#include <vector>

#include "cache.h"
#include "modules.h"

struct hawkeye : public champsim::modules::replacement {
  // -- Reference constants ---------------------------------------------------
  static constexpr unsigned MAXRRIP = 7;            // 3-bit RRIP
  static constexpr std::size_t OPTGEN_SIZE = 128;   // 8x associativity
  static constexpr int MAX_PCMAP = 31;              // 5-bit predictor counter
  static constexpr std::size_t PCMAP_SIZE = 2048;   // 11-bit hashed PC index
  static constexpr std::size_t SAMPLER_ENTRIES = 2800;
  static constexpr std::size_t SAMPLER_HIST = 8;
  static constexpr std::size_t SAMPLER_SETS = SAMPLER_ENTRIES / SAMPLER_HIST; // 350
  static constexpr uint64_t TIMER_SIZE = 1024;

  // -- Geometry --------------------------------------------------------------
  long NUM_SET = 0;
  long NUM_WAY = 0;
  int LOG2_LLC_SET = 0;

  // -- Hawkeye predictor -----------------------------------------------------
  // The artifact's map<uint64_t,int> with lazy initialisation to
  // (MAX_PCMAP+1)/2, flattened to a vector. get_prediction returns true for
  // cache-friendly; high counter == friendly.
  struct Predictor {
    std::vector<int> counters;
    void init() { counters.assign(PCMAP_SIZE, (MAX_PCMAP + 1) / 2); }
    bool get_prediction(uint64_t pc) const;
    void increase(uint64_t pc);
    void decrease(uint64_t pc);
  };
  Predictor predictor_demand;
  Predictor predictor_prefetch;

  // -- OPTgen ----------------------------------------------------------------
  struct OPTgen {
    std::vector<unsigned> liveness_intervals;
    uint64_t num_cache = 0;
    uint64_t access = 0;
    uint64_t cache_size = 0;

    void init(uint64_t size)
    {
      num_cache = 0;
      access = 0;
      cache_size = size;
      liveness_intervals.assign(OPTGEN_SIZE, 0u);
    }
    void set_access(uint64_t val)
    {
      access++;
      liveness_intervals[val] = 0;
    }
    void set_prefetch(uint64_t val) { liveness_intervals[val] = 0; }
    // Would OPT have kept a line whose usage interval runs from endVal to val?
    // If so, reserve a way across that interval and count the hit.
    bool is_cache(uint64_t val, uint64_t endVal);
  };
  std::vector<OPTgen> optgen_occup_vector; // NUM_SET

  // -- Sampler ---------------------------------------------------------------
  struct HISTORY {
    uint64_t PCval = 0;
    uint32_t previousVal = 0;
    uint32_t lru = 0;
    bool prefetching = false;

    void update(uint32_t currentVal, uint64_t PC)
    {
      previousVal = currentVal;
      PCval = PC;
    }
    void set_prefetch() { prefetching = true; }
  };
  std::vector<std::map<uint64_t, HISTORY>> cache_history_sampler; // SAMPLER_SETS

  // -- Per-line state --------------------------------------------------------
  std::vector<unsigned> rrip;              // NUM_SET * NUM_WAY
  std::vector<uint64_t> sample_signature;  // NUM_SET * NUM_WAY, raw PC
  std::vector<uint8_t> prefetching_line;   // NUM_SET * NUM_WAY
  std::vector<uint64_t> set_timer;         // NUM_SET, wraps at TIMER_SIZE

  // -- Sanity counters (printed by replacement_final_stats) ------------------
  // stat_fills is load-bearing: zero means the insertion hook is not wired up
  // and the policy is learning nothing. See bench/policy_sanity/.
  uint64_t stat_fills = 0;
  uint64_t stat_hits = 0;
  uint64_t stat_detrains = 0;

  explicit hawkeye(champsim::modules::ModuleBuilder builder);

  void initialize_replacement() override {}

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type) override;

  // Insertion hook. MUST exist -- see H1 above.
  void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                              access_type type) override;

  void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr,
                                access_type type, bool hit) override;

  void replacement_final_stats() override;

private:
  // The artifact's UpdateReplacementState body, shared by both hooks above.
  void handle_access(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, access_type type, bool hit);

  bool is_sampled_set(long set) const;
  void update_cache_history(std::size_t sample_set, uint32_t currentVal);
};

#endif
