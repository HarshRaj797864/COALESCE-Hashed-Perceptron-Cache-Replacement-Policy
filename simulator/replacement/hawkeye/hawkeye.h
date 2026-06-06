// Hawkeye cache replacement policy
// Faithful re-implementation of:
//   Akanksha Jain and Calvin Lin, "Back to the Future: Leveraging Belady's
//   Algorithm for Improved Cache Replacement," ISCA 2016.
// Reference: the CRC2 (Cache Replacement Championship 2017) reference implementation
//   distributed by the authors. Constants and algorithm match the published paper.
//
// Mechanism:
//   * OPTgen: a sliding-window approximation of Belady's MIN policy. Per
//     "sampled set", it tracks a recent occupancy vector and decides retroactively
//     whether a re-referenced line could have been cached under MIN.
//   * PC predictor: per-CPU 8 K-entry table of 3-bit saturating counters indexed
//     by hashed allocator PC. Trained by OPTgen's retroactive labels.
//   * Per-line RRPV: 3-bit. Cache-friendly inserted at 0; cache-averse at 7
//     (the maxRRPV). On eviction, the maxRRPV line is the victim. If no line
//     is at maxRRPV the policy ages cache-friendly lines toward 6 (so that
//     they remain higher-priority than fresh cache-averse but lower than the
//     freshest cache-friendly).
//
// This is a stand-alone ChampSim module. Storage is per-CACHE-instance.

#ifndef REPLACEMENT_HAWKEYE_H
#define REPLACEMENT_HAWKEYE_H

#include <array>
#include <cstdint>
#include <vector>

#include "cache.h"
#include "modules.h"
#include "msl/fwcounter.h"

struct hawkeye : public champsim::modules::replacement {
  // -- Policy constants (CRC2 defaults) --------------------------------------
  static constexpr unsigned MAX_RRPV = 7;             // 3-bit RRPV (0..7)
  static constexpr unsigned PREDICTOR_BITS = 3;       // 3-bit saturating counter
  static constexpr unsigned PREDICTOR_MAX = (1u << PREDICTOR_BITS) - 1; // 7
  static constexpr unsigned PREDICTOR_THRESHOLD = (PREDICTOR_MAX + 1) / 2; // 4 -> averse
  static constexpr std::size_t PREDICTOR_ENTRIES = 8192;

  // OPTgen / sampler geometry
  static constexpr std::size_t SAMPLED_SETS = 64;     // sampled sets per cache (LLC)
  static constexpr std::size_t SAMPLER_WAYS = 8;      // entries in the per-sampled-set history table
  static constexpr std::size_t OPTGEN_VECTOR_FACTOR = 8; // ring-buffer size = 8 * NUM_WAY

  // -- Geometry (filled in ctor from CACHE*) ---------------------------------
  long NUM_SET = 0;
  long NUM_WAY = 0;

  // -- Per-line RRPV ---------------------------------------------------------
  std::vector<unsigned> rrpv;   // size = NUM_SET * NUM_WAY

  // -- Per-CPU predictor: 8K entries x 3-bit saturating counters -------------
  std::vector<std::array<champsim::msl::fwcounter<PREDICTOR_BITS>, PREDICTOR_ENTRIES>> predictor;

  // -- OPTgen state per sampled set ------------------------------------------
  // occupancy_vec[s][t] = number of "live" sampler lines at timestamp t in
  // sampled set s. Implemented as a ring buffer of length (SAMPLER_WAYS *
  // OPTGEN_VECTOR_FACTOR). Indexed by (timestamp mod size).
  struct OPTgen {
    std::vector<unsigned> occupancy;   // ring buffer
    uint64_t current_quanta = 0;       // monotonic timestamp
    unsigned cache_capacity = 0;       // = SAMPLER_WAYS

    void init(unsigned ways);
    // Returns true iff a line whose previous access was at `prev_quanta`
    // would have been kept in the cache by Belady's MIN over the interval
    // [prev_quanta, current_quanta).
    bool would_cache(uint64_t prev_quanta) const;
    // Mark the interval [prev_quanta, current_quanta) as carrying one more
    // live line. Must be called after `would_cache` returns true.
    void add_access(uint64_t prev_quanta);
    // Advance the timestamp by one quanta (called on every sampled access).
    void advance();
  };

  std::vector<OPTgen> optgens;          // size = SAMPLED_SETS
  std::vector<bool> is_sampled;         // size = NUM_SET; true iff set is sampled
  std::vector<std::size_t> set_to_optgen_idx; // size = NUM_SET; sampled set -> [0..SAMPLED_SETS)

  // -- Per-sampled-set sampler -----------------------------------------------
  // Recent accesses per sampled set: address (block tag), allocator PC and
  // the OPTgen timestamp at the time of access. Used to feed OPTgen + predictor
  // training when a line is re-referenced.
  struct SamplerEntry {
    bool valid = false;
    uint64_t addr_tag = 0;     // upper bits of the block address
    uint64_t pc_sig = 0;       // hashed allocator PC of last touch
    uint64_t last_quanta = 0;  // OPTgen timestamp of last touch
    uint64_t last_used = 0;    // LRU recency within the sampler set
    uint32_t cpu = 0;          // owning CPU (predictor is per-CPU)
  };
  std::vector<std::vector<SamplerEntry>> sampler; // size SAMPLED_SETS x SAMPLER_WAYS

  // -- Misc state ------------------------------------------------------------
  uint64_t access_counter = 0;          // global LRU recency for sampler

  // -- Constructor / interface ----------------------------------------------
  explicit hawkeye(CACHE* cache);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                   const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type);

  void update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                champsim::address full_addr, champsim::address ip,
                                champsim::address victim_addr, access_type type,
                                uint8_t hit);

private:
  // hash the PC down to a predictor index. CRC2 reference uses a simple
  // (PC >> 2) ^ (PC >> 13) style mix; we use the upper 32 bits XOR-folded.
  static std::size_t hash_pc(champsim::address ip);

  // age every line in the set: increment RRPV up to MAX_RRPV - 1 (so a
  // cache-averse line at MAX_RRPV is still the preferred victim).
  void age_set(long set);
};

#endif
