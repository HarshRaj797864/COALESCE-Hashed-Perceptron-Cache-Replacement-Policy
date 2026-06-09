#include "coalesce_no_sharer.h"
#include <algorithm>
#include <cmath>

// --- CNS_GhostEntry ---
// Packing: [31:20] pc_sig(12b) [19:6] tag_partial(14b) [5:3] unused [2:1] state(2b) [0] valid
CNS_GhostEntry::CNS_GhostEntry(uint64_t tag, uint64_t pc, MESI_State state) {
    uint32_t pc_sig      = (pc & 0xFFF);
    uint32_t tag_partial = (tag & 0x3FFF);
    uint32_t state_bits  = (state & 0x3);
    packed = (pc_sig << 20) | (tag_partial << 6) | (state_bits << 1) | 1;
}
bool        CNS_GhostEntry::is_valid()       const { return packed & 0x1; }
uint32_t    CNS_GhostEntry::get_pc_sig()     const { return (packed >> 20) & 0xFFF; }
uint32_t    CNS_GhostEntry::get_tag_partial()const { return (packed >> 6) & 0x3FFF; }
MESI_State  CNS_GhostEntry::get_state()      const { return (MESI_State)((packed >> 1) & 0x3); }
bool CNS_GhostEntry::matches(uint64_t tag, uint64_t pc) const {
    if (!is_valid()) return false;
    return (get_pc_sig() == (pc & 0xFFF)) && (get_tag_partial() == (tag & 0x3FFF));
}

// --- CNS_BloomFilter ---
CNS_BloomFilter::CNS_BloomFilter() : insert_count(0) {
    bit_array.resize(CNS_BLOOM_SIZE, false);
    ghost_tags.resize(CNS_GHOST_CAPACITY);
}
void CNS_BloomFilter::insert(uint64_t tag, uint64_t pc, MESI_State state) {
    if (insert_count >= CNS_BLOOM_RESET_THRESHOLD) {
        std::fill(bit_array.begin(), bit_array.end(), false);
        insert_count = 0;
    }
    insert_count++;
    for (int i = 0; i < CNS_BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % CNS_BLOOM_SIZE;
        bit_array[hash] = true;
    }
    uint64_t ghost_hash = (tag ^ pc) % CNS_GHOST_CAPACITY;
    ghost_tags[ghost_hash] = CNS_GhostEntry(tag, pc, state);
}
bool CNS_BloomFilter::lookup(uint64_t tag, uint64_t pc, MESI_State& out_state) {
    for (int i = 0; i < CNS_BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % CNS_BLOOM_SIZE;
        if (!bit_array[hash]) return false;
    }
    uint64_t ghost_hash = (tag ^ pc) % CNS_GHOST_CAPACITY;
    const CNS_GhostEntry& entry = ghost_tags[ghost_hash];
    if (entry.matches(tag, pc)) {
        out_state = entry.get_state();
        return true;
    }
    return false;
}

// --- CNS_Brain ---
CNS_Brain::CNS_Brain() {
    table0.resize(CNS_TABLE_SIZE, 0);
    table1.resize(CNS_TABLE_SIZE, 0);
    for (int i = 0; i < CNS_TABLE_SIZE; i++) {
        table0[i] = -5 + (i % 11);
        table1[i] = -5 + ((i * 7) % 11);
    }
}
int CNS_Brain::get_hash0(uint64_t pc, MESI_State state) {
    uint64_t h = pc ^ 0x9e3779b9;
    h ^= (state << 8);
    return h % CNS_TABLE_SIZE;
}
// PC-only hash for table1: Jiminez 2017 multiperspective constant, no sharer input.
int CNS_Brain::get_hash1(uint64_t pc) {
    uint64_t h = (pc ^ 0x85ebca6b) ^ (pc >> 13);
    return h % CNS_TABLE_SIZE;
}
int CNS_Brain::predict_raw(uint64_t pc, MESI_State state) {
    return table0[get_hash0(pc, state)] + table1[get_hash1(pc)];
}
void CNS_Brain::train(uint64_t pc, MESI_State state, bool positive, int current_vote) {
    bool mispredicted    = (positive && current_vote <= 0) || (!positive && current_vote > 0);
    bool low_confidence  = std::abs(current_vote) <= CNS_THRESHOLD;
    if (mispredicted || low_confidence) {
        int h0 = get_hash0(pc, state);
        int h1 = get_hash1(pc);
        int direction = positive ? 1 : -1;
        int new_val0 = table0[h0] + direction;
        if (new_val0 <= CNS_MAX_WEIGHT && new_val0 >= CNS_MIN_WEIGHT) table0[h0] = new_val0;
        int new_val1 = table1[h1] + direction;
        if (new_val1 <= CNS_MAX_WEIGHT && new_val1 >= CNS_MIN_WEIGHT) table1[h1] = new_val1;
    }
}

// --- coalesce_no_sharer policy ---
coalesce_no_sharer::coalesce_no_sharer(CACHE* cache) : replacement(cache) {
    long sets = cache->NUM_SET;
    ghosts.resize(sets);
    is_sampled.resize(sets, false);
    for (long i = 0; i < sets; i++)
        if (i % CNS_SAMPLING_MODULO == 0) is_sampled[i] = true;
}

long coalesce_no_sharer::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                                     const champsim::cache_block* current_set,
                                     champsim::address ip, champsim::address full_addr,
                                     access_type type) {
    long victim   = 0;
    int  min_vote = 999999;
    long ways     = 16;

    for (long w = 0; w < ways; w++) {
        if (!current_set[w].valid) return w;

        int raw_vote   = brain.predict_raw(current_set[w].ip, current_set[w].state);
        int final_vote = raw_vote;

        // +40 MODIFIED bias retained; +20*sharers bias removed.
        if (raw_vote > 0 && current_set[w].state == MODIFIED)
            final_vote += 40;

        if (final_vote < min_vote) {
            min_vote = final_vote;
            victim   = w;
        }
    }

    if (is_sampled[set]) {
        uint64_t tag = full_addr.to<uint64_t>() >> 6;
        ghosts[set].insert(tag, current_set[victim].ip, current_set[victim].state);
    }

    return victim;
}

void coalesce_no_sharer::update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                                   champsim::address full_addr, champsim::address ip,
                                                   champsim::address victim_addr, access_type type,
                                                   uint8_t hit) {
    uint64_t tag    = full_addr.to<uint64_t>() >> 6;
    uint64_t ip_val = ip.to<uint64_t>();

    if (hit) {
        if (is_sampled[set]) {
            auto& block_meta = intern_->block[set * intern_->NUM_WAY + way];
            int vote = brain.predict_raw(ip_val, block_meta.state);
            brain.train(ip_val, block_meta.state, true, vote);
        }
    } else {
        if (is_sampled[set]) {
            MESI_State ghost_state;
            if (ghosts[set].lookup(tag, ip_val, ghost_state)) {
                int vote = brain.predict_raw(ip_val, ghost_state);
                for (int k = 0; k < 5; k++)
                    brain.train(ip_val, ghost_state, true, vote);
            }
        }
    }
}
