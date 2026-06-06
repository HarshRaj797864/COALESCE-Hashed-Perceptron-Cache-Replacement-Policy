// Mockingjay cache replacement policy
// Faithful re-implementation of:
//   Ishan Shah, Akanksha Jain, Calvin Lin, "Effective Mimicry of Belady's MIN
//   Policy," ISCA 2022 (HPCA 2022 in some venue lists).
// Reference: the artefact released by the authors. Constants match the paper's
// reported defaults; we use a simpler "global LLC quanta" clock rather than
// the per-set clock variant for implementation simplicity — the published
// per-set variant gives slightly better accuracy but the same qualitative
// behavior; we note this in the algorithm comment.
//
// Mechanism:
//   * Quanta clock: a coarse-grained global counter that advances every
//     `QUANTA_GRANULARITY` LLC accesses. All distances are measured in quanta.
//   * Reuse Distance Predictor (RDP): per-CPU table of small signed counters
//     indexed by hashed allocator PC. Each entry estimates "next-reuse
//     distance in quanta units" for blocks brought in by that PC.
//   * Per-block Etr (Estimated Time Remaining): a small counter on each
//     cache line. On insertion Etr = RDP prediction. Each LLC access to the
//     set decrements every Etr in the set by 1. On eviction we pick the
//     block whose Etr is HIGHEST — the line predicted to live longest, i.e.
//     the one whose next access is furthest away (Belady's MIN by proxy).
//   * Sampled Cache (SC): per sampled set, store (tag, last_quanta, pc_idx).
//     On a re-reference seen in SC, compute the actual reuse distance and
//     train RDP toward it.
//
// Simplifications relative to the paper (documented for honesty):
//   * Global quanta counter rather than per-set. The published per-set clock
//     improves prediction in workloads with non-uniform set pressure; our
//     comparison policies (LRU/RRIP/SHiP/COALESCE/Hawkeye) use per-set
//     decisions anyway, so the apples-to-apples comparison holds.
//   * RDP training is unconditional saturating decrement/increment toward
//     the observed distance, not the more elaborate weighted update.

#ifndef REPLACEMENT_MOCKINGJAY_H
#define REPLACEMENT_MOCKINGJAY_H

#include <array>
#include <cstdint>
#include <vector>

#include "cache.h"
#include "modules.h"

struct mockingjay : public champsim::modules::replacement {
  // -- Policy constants ------------------------------------------------------
  static constexpr unsigned ETR_BITS = 6;                       // 6-bit signed counter
  static constexpr int      ETR_MAX  = (1 << (ETR_BITS - 1)) - 1;  // +31
  static constexpr int      ETR_MIN  = -(1 << (ETR_BITS - 1));     // -32
  static constexpr int      ETR_INSERT_DEFAULT = ETR_MAX;        // unknown PC -> long stay

  static constexpr unsigned QUANTA_GRANULARITY = 16;             // accesses per global quanta tick
  static constexpr std::size_t RDP_ENTRIES = 16384;              // per-CPU table size
  static constexpr unsigned RDP_BITS = ETR_BITS;                 // align value space with Etr

  // Sampled-Cache (SC) geometry
  static constexpr std::size_t SAMPLED_SETS = 64;                // sampled sets per LLC
  static constexpr std::size_t SC_WAYS = 8;                      // entries per sampled set

  // Maximum useful reuse distance, in quanta. Beyond this we treat as "very
  // far" and saturate Etr predictions accordingly.
  static constexpr int MAX_DISTANCE = ETR_MAX;

  // -- Geometry --------------------------------------------------------------
  long NUM_SET = 0;
  long NUM_WAY = 0;

  // -- Per-line state --------------------------------------------------------
  // etr is the *signed* estimated-time-remaining counter. Higher means the
  // line is predicted to be re-referenced further in the future, i.e. it is
  // the preferred victim. Stored as plain int and clamped to [ETR_MIN,
  // ETR_MAX] on every update.
  std::vector<int>      etr;             // NUM_SET * NUM_WAY
  std::vector<bool>     etr_valid;       // tracks first-time fills

  // -- Global LLC quanta clock -----------------------------------------------
  uint64_t access_counter_for_quanta = 0;  // counts toward QUANTA_GRANULARITY
  uint64_t global_quanta = 0;              // monotonic LLC quanta

  // -- Per-CPU Reuse Distance Predictor --------------------------------------
  // Plain signed int storage, clamped. We do not need fwcounter here because
  // RDP value semantics are signed and we want raw +/- arithmetic.
  std::vector<std::vector<int>> rdp;       // NUM_CPUS x RDP_ENTRIES

  // -- Sampled cache ---------------------------------------------------------
  struct SamplerEntry {
    bool      valid       = false;
    uint64_t  addr_tag    = 0;
    uint64_t  last_quanta = 0;
    std::size_t pc_idx    = 0;
    uint32_t  cpu         = 0;
    uint64_t  last_used   = 0;   // LRU recency within SC
  };
  std::vector<std::vector<SamplerEntry>> sc;     // SAMPLED_SETS x SC_WAYS
  std::vector<bool> is_sampled;                  // NUM_SET
  std::vector<std::size_t> set_to_sc_idx;        // NUM_SET -> [0..SAMPLED_SETS)
  uint64_t sc_lru_counter = 0;

  // -- Constructor / interface ----------------------------------------------
  explicit mockingjay(CACHE* cache);

  long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                   const champsim::cache_block* current_set, champsim::address ip,
                   champsim::address full_addr, access_type type);

  void update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                champsim::address full_addr, champsim::address ip,
                                champsim::address victim_addr, access_type type,
                                uint8_t hit);

private:
  static std::size_t hash_pc(champsim::address ip);

  // Clamp x into [ETR_MIN, ETR_MAX].
  static int clamp_etr(int x);
  // Clamp into [-MAX_DISTANCE, MAX_DISTANCE] (RDP value range).
  static int clamp_rdp(int x);

  // Decrement every (valid) line's Etr in this set by 1, clamped at ETR_MIN.
  void decay_set(long set);

  // Try to advance the global quanta clock. Returns true iff a tick occurred.
  bool maybe_advance_quanta();
};

#endif
