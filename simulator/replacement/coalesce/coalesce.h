#ifndef REPLACEMENT_COALESCE_H
#define REPLACEMENT_COALESCE_H

#include <vector>
#include <cstdint>
#include "cache.h"
#include "modules.h"

// Constants
constexpr int PERCEPTRON_TABLE_SIZE = 2048;
constexpr int MAX_WEIGHT = 127;
constexpr int MIN_WEIGHT = -128;
constexpr int THRESHOLD = 35;
constexpr int VETO_OVERRIDE = -100;
constexpr int BLOOM_SIZE = 1024;
constexpr int BLOOM_HASHES = 3;
constexpr int SAMPLING_MODULO = 16;
constexpr int GHOST_CAPACITY = 256;

struct CompactGhostEntry {
    uint32_t packed;
    CompactGhostEntry() : packed(0) {}
    CompactGhostEntry(uint64_t tag, uint64_t pc, int sharers, MESI_State state);
    bool is_valid() const;
    uint32_t get_pc_sig() const;
    uint32_t get_tag_partial() const;
    int get_sharers() const;
    MESI_State get_state() const;
    bool matches(uint64_t tag, uint64_t pc) const;
};

class BloomFilter {
    std::vector<bool> bit_array;
    std::vector<CompactGhostEntry> ghost_tags;
public:
    BloomFilter();
    void insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state);
    bool lookup(uint64_t tag, uint64_t pc, int& out_sharers, MESI_State& out_state);
};

class PerceptronBrain {
    std::vector<int> table0;
    std::vector<int> table1;
public:
    PerceptronBrain();
    int get_hash0(uint64_t pc, MESI_State state);
    int get_hash1(uint64_t pc, int sharers);
    int predict_raw(uint64_t pc, int sharers, MESI_State state);
    void train(uint64_t pc, int sharers, MESI_State state, bool positive, int current_vote);
};

// The main ChampSim Module
class coalesce : public champsim::modules::replacement {
    PerceptronBrain brain;
    std::vector<BloomFilter> ghosts;
    std::vector<bool> is_sampled;

public:
    explicit coalesce(CACHE* cache);

    long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip, champsim::address full_addr, access_type type);
    void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr, access_type type, uint8_t hit);
};

#endif
