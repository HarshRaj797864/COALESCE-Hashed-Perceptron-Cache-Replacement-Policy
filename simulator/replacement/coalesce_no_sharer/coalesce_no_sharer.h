#ifndef REPLACEMENT_COALESCE_NO_SHARER_H
#define REPLACEMENT_COALESCE_NO_SHARER_H

#include <vector>
#include <cstdint>
#include "cache.h"
#include "modules.h"

// COALESCE V2 ablation: sharer-count axis removed from the perceptron.
// Keep: PC in hash0, MESI state in hash0, +40 MODIFIED bias, Bloom ghost rescue,
//       set sampling, dual 2048-entry tables, THRESHOLD=35.
// Drop: sharer-count input to hash1/predict_raw/train, +20*sharers bias.
// hash1 becomes a second PC-only hash (Jiminez 2017 multiperspective mixing constant).
// Purpose: isolate whether the sharer feature contributes at all.

constexpr int CNS_TABLE_SIZE            = 2048;
constexpr int CNS_MAX_WEIGHT            = 127;
constexpr int CNS_MIN_WEIGHT            = -128;
constexpr int CNS_THRESHOLD             = 35;
constexpr int CNS_BLOOM_SIZE            = 1024;
constexpr int CNS_BLOOM_HASHES          = 3;
constexpr int CNS_BLOOM_RESET_THRESHOLD = 150;
constexpr int CNS_SAMPLING_MODULO       = 32;
constexpr int CNS_GHOST_CAPACITY        = 128;

struct CNS_GhostEntry {
    uint32_t packed;
    CNS_GhostEntry() : packed(0) {}
    CNS_GhostEntry(uint64_t tag, uint64_t pc, MESI_State state);
    bool is_valid() const;
    uint32_t get_pc_sig() const;
    uint32_t get_tag_partial() const;
    MESI_State get_state() const;
    bool matches(uint64_t tag, uint64_t pc) const;
};

class CNS_BloomFilter {
    std::vector<bool> bit_array;
    std::vector<CNS_GhostEntry> ghost_tags;
    int insert_count;
public:
    CNS_BloomFilter();
    void insert(uint64_t tag, uint64_t pc, MESI_State state);
    bool lookup(uint64_t tag, uint64_t pc, MESI_State& out_state);
};

class CNS_Brain {
    std::vector<int> table0; // hash: PC ^ MESI-state
    std::vector<int> table1; // hash: PC only (no sharers)
public:
    CNS_Brain();
    int get_hash0(uint64_t pc, MESI_State state);
    int get_hash1(uint64_t pc);
    int predict_raw(uint64_t pc, MESI_State state);
    void train(uint64_t pc, MESI_State state, bool positive, int current_vote);
};

class coalesce_no_sharer : public champsim::modules::replacement {
    CNS_Brain brain;
    std::vector<CNS_BloomFilter> ghosts;
    std::vector<bool> is_sampled;

public:
    explicit coalesce_no_sharer(CACHE* cache);

    long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                     const champsim::cache_block* current_set,
                     champsim::address ip, champsim::address full_addr, access_type type);
    void update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                  champsim::address full_addr, champsim::address ip,
                                  champsim::address victim_addr, access_type type, uint8_t hit);
};

#endif
