#ifndef REPLACEMENT_COALESCE_NO_MESI_H
#define REPLACEMENT_COALESCE_NO_MESI_H

#include <vector>
#include <cstdint>
#include "cache.h"
#include "modules.h"

// COALESCE V2 ablation: MESI-state axis removed from the perceptron.
// Keep: PC in hash0, sharer-count in hash1, +20*sharers bias, Bloom ghost
//       rescue, set sampling, dual 2048-entry tables, THRESHOLD=35.
// Drop: MESI-state input to hash0, +40 MODIFIED bias.
// hash0 becomes a second PC-only hash (distinct mixing remix).
// Purpose: isolate whether the MESI-state feature (hash + bias) contributes.
// Exact mirror of coalesce_no_sharer, flipped to the other feature axis.

constexpr int CNM_TABLE_SIZE            = 2048;
constexpr int CNM_MAX_WEIGHT            = 127;
constexpr int CNM_MIN_WEIGHT            = -128;
constexpr int CNM_THRESHOLD             = 35;
constexpr int CNM_BLOOM_SIZE            = 1024;
constexpr int CNM_BLOOM_HASHES          = 3;
constexpr int CNM_BLOOM_RESET_THRESHOLD = 150;
constexpr int CNM_SAMPLING_MODULO       = 32;
constexpr int CNM_GHOST_CAPACITY        = 128;

struct CNM_GhostEntry {
    uint32_t packed;
    CNM_GhostEntry() : packed(0) {}
    CNM_GhostEntry(uint64_t tag, uint64_t pc, int sharers, MESI_State state);
    bool is_valid() const;
    uint32_t get_pc_sig() const;
    uint32_t get_tag_partial() const;
    int get_sharers() const;
    MESI_State get_state() const;
    bool matches(uint64_t tag) const;   // address only; the PC is stored, not matched
};

class CNM_BloomFilter {
    std::vector<bool> bit_array;
    std::vector<CNM_GhostEntry> ghost_tags;
    int insert_count;
public:
    CNM_BloomFilter();
    void insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state);
    bool lookup(uint64_t tag, uint64_t& out_alloc_pc, int& out_sharers, MESI_State& out_state);
};

class CNM_Brain {
    std::vector<int> table0; // hash: PC only (MESI state removed)
    std::vector<int> table1; // hash: PC ^ sharers
public:
    CNM_Brain();
    int get_hash0(uint64_t pc);
    int get_hash1(uint64_t pc, int sharers);
    int predict_raw(uint64_t pc, int sharers);
    void train(uint64_t pc, int sharers, bool positive, int current_vote);
};

class coalesce_no_mesi : public champsim::modules::replacement {
    CNM_Brain brain;
    std::vector<CNM_BloomFilter> ghosts;
    // log2(number of sets). Ghost tags are per set, so the tag stored in them
    // must exclude the set-index bits, which are identical for every line a
    // given structure holds. See ghost_mix() in the .cc.
    int set_bits = 0;
    std::vector<bool> is_sampled;

public:
    // The parent cache, kept so update_replacement_state can read the hit
    // line's coherence metadata via get_block(). find_victim already receives
    // the whole set, but the hit path does not.
    champsim::modules::cache_module* cache_ = nullptr;
    long NUM_WAY = 0;

    // Sharer histogram lives in the policy: develop's get_sim_stats() returns
    // by value, so a policy cannot write through it.
    uint64_t sharer_hist[17] = {0};

    // Training-path instrumentation. Without it there is no way to tell whether
    // the ghost-tag rescue fires at all -- and it was dead for nine months
    // (keyed on the incoming line instead of the evicted one) while compiling,
    // running and producing plausible numbers. Hawkeye and Mockingjay both
    // count their training events; this policy counted nothing.
    uint64_t stat_ghost_inserts = 0;
    uint64_t stat_ghost_hits = 0;   // rescue actually fired
    uint64_t stat_detrains = 0;
    uint64_t stat_hit_trains = 0;

    explicit coalesce_no_mesi(champsim::modules::ModuleBuilder builder);

    void initialize_replacement() override {}

    long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                     const champsim::cache_block* current_set,
                     champsim::address ip, champsim::address full_addr, access_type type) override;
    // Insertion hook. Without it ChampSim never reports fills to this policy
    // (inc/cache.h:475), so the ghost-tag rescue was dead code.
    void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr, access_type type) override;

    void update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                  champsim::address full_addr, champsim::address ip,
                                  champsim::address victim_addr, access_type type, bool hit) override;

    void replacement_final_stats() override;
};

#endif
