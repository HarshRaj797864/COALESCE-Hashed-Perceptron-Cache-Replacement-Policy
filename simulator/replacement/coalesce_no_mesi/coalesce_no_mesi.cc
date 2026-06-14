#include "coalesce_no_mesi.h"
#include <algorithm>
#include <cmath>

// --- CNM_GhostEntry ---
// Packing: [31:20] pc_sig(12b) [19:6] tag_partial(14b) [5:3] sharers(3b) [2:1] state(2b) [0] valid
// (state still stored for parity with the base policy; the perceptron no longer reads it.)
CNM_GhostEntry::CNM_GhostEntry(uint64_t tag, uint64_t pc, int sharers, MESI_State state) {
    uint32_t pc_sig      = (pc & 0xFFF);
    uint32_t tag_partial = (tag & 0x3FFF);
    uint32_t sharer_bits = (sharers & 0x7);
    uint32_t state_bits  = (state & 0x3);
    packed = (pc_sig << 20) | (tag_partial << 6) | (sharer_bits << 3) | (state_bits << 1) | 1;
}
bool        CNM_GhostEntry::is_valid()        const { return packed & 0x1; }
uint32_t    CNM_GhostEntry::get_pc_sig()      const { return (packed >> 20) & 0xFFF; }
uint32_t    CNM_GhostEntry::get_tag_partial() const { return (packed >> 6) & 0x3FFF; }
int         CNM_GhostEntry::get_sharers()     const { return (packed >> 3) & 0x7; }
MESI_State  CNM_GhostEntry::get_state()       const { return (MESI_State)((packed >> 1) & 0x3); }
bool CNM_GhostEntry::matches(uint64_t tag, uint64_t pc) const {
    if (!is_valid()) return false;
    return (get_pc_sig() == (pc & 0xFFF)) && (get_tag_partial() == (tag & 0x3FFF));
}

// --- CNM_BloomFilter ---
CNM_BloomFilter::CNM_BloomFilter() : insert_count(0) {
    bit_array.resize(CNM_BLOOM_SIZE, false);
    ghost_tags.resize(CNM_GHOST_CAPACITY);
}
void CNM_BloomFilter::insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state) {
    if (insert_count >= CNM_BLOOM_RESET_THRESHOLD) {
        std::fill(bit_array.begin(), bit_array.end(), false);
        insert_count = 0;
    }
    insert_count++;
    for (int i = 0; i < CNM_BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % CNM_BLOOM_SIZE;
        bit_array[hash] = true;
    }
    uint64_t ghost_hash = (tag ^ pc) % CNM_GHOST_CAPACITY;
    ghost_tags[ghost_hash] = CNM_GhostEntry(tag, pc, sharers, state);
}
bool CNM_BloomFilter::lookup(uint64_t tag, uint64_t pc, int& out_sharers, MESI_State& out_state) {
    for (int i = 0; i < CNM_BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % CNM_BLOOM_SIZE;
        if (!bit_array[hash]) return false;
    }
    uint64_t ghost_hash = (tag ^ pc) % CNM_GHOST_CAPACITY;
    const CNM_GhostEntry& entry = ghost_tags[ghost_hash];
    if (entry.matches(tag, pc)) {
        out_sharers = entry.get_sharers();
        out_state   = entry.get_state();
        return true;
    }
    return false;
}

// --- CNM_Brain ---
CNM_Brain::CNM_Brain() {
    table0.resize(CNM_TABLE_SIZE, 0);
    table1.resize(CNM_TABLE_SIZE, 0);
    for (int i = 0; i < CNM_TABLE_SIZE; i++) {
        table0[i] = -5 + (i % 11);
        table1[i] = -5 + ((i * 7) % 11);
    }
}
// PC-only hash for table0: MESI state removed; distinct PC remix so the two
// tables stay orthogonal (mirrors the no-sharer module's PC-only hash1).
// 0x9e3779b9 is the original hash0 mixing constant.
int CNM_Brain::get_hash0(uint64_t pc) {
    uint64_t h = (pc ^ 0x9e3779b9) ^ (pc >> 11);
    return h % CNM_TABLE_SIZE;
}
int CNM_Brain::get_hash1(uint64_t pc, int sharers) {
    uint64_t h = pc ^ 0x85ebca6b;
    h ^= (sharers << 4);
    return h % CNM_TABLE_SIZE;
}
int CNM_Brain::predict_raw(uint64_t pc, int sharers) {
    return table0[get_hash0(pc)] + table1[get_hash1(pc, sharers)];
}
void CNM_Brain::train(uint64_t pc, int sharers, bool positive, int current_vote) {
    bool mispredicted   = (positive && current_vote <= 0) || (!positive && current_vote > 0);
    bool low_confidence = std::abs(current_vote) <= CNM_THRESHOLD;
    if (mispredicted || low_confidence) {
        int h0 = get_hash0(pc);
        int h1 = get_hash1(pc, sharers);
        int direction = positive ? 1 : -1;
        int new_val0 = table0[h0] + direction;
        if (new_val0 <= CNM_MAX_WEIGHT && new_val0 >= CNM_MIN_WEIGHT) table0[h0] = new_val0;
        int new_val1 = table1[h1] + direction;
        if (new_val1 <= CNM_MAX_WEIGHT && new_val1 >= CNM_MIN_WEIGHT) table1[h1] = new_val1;
    }
}

// --- coalesce_no_mesi policy ---
coalesce_no_mesi::coalesce_no_mesi(CACHE* cache) : replacement(cache) {
    long sets = cache->NUM_SET;
    ghosts.resize(sets);
    is_sampled.resize(sets, false);
    for (long i = 0; i < sets; i++)
        if (i % CNM_SAMPLING_MODULO == 0) is_sampled[i] = true;
}

long coalesce_no_mesi::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                                   const champsim::cache_block* current_set,
                                   champsim::address ip, champsim::address full_addr,
                                   access_type type) {
    long victim   = 0;
    int  min_vote = 999999;
    long ways     = 16;

    for (long w = 0; w < ways; w++) {
        if (!current_set[w].valid) return w;

        int current_sharers = __builtin_popcount(current_set[w].sharer_mask);

        if (current_sharers >= 0 && current_sharers <= 16) {
            intern_->sim_stats.coherence_sharer_hist[current_sharers]++;
        }

        int raw_vote   = brain.predict_raw(current_set[w].ip, current_sharers);
        int final_vote = raw_vote;

        // +40 MODIFIED bias REMOVED (MESI axis ablated); +20*sharers retained.
        if (raw_vote > 0) {
            if (current_sharers >= 2) final_vote += (20 * current_sharers);
        }

        if (final_vote < min_vote) {
            min_vote = final_vote;
            victim   = w;
        }
    }

    if (is_sampled[set]) {
        uint64_t tag = full_addr.to<uint64_t>() >> 6;
        int victim_sharers = 0;
        for (int i = 0; i < 16; i++) {
            if ((current_set[victim].sharer_mask >> i) & 1) victim_sharers++;
        }
        ghosts[set].insert(tag, current_set[victim].ip, victim_sharers, current_set[victim].state);
    }

    return victim;
}

void coalesce_no_mesi::update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                                champsim::address full_addr, champsim::address ip,
                                                champsim::address victim_addr, access_type type,
                                                uint8_t hit) {
    uint64_t tag    = full_addr.to<uint64_t>() >> 6;
    uint64_t ip_val = ip.to<uint64_t>();

    if (hit) {
        if (is_sampled[set]) {
            auto& block_meta = intern_->block[set * intern_->NUM_WAY + way];
            int current_sharers = 0;
            for (int i = 0; i < 16; i++) {
                if ((block_meta.sharer_mask >> i) & 1) current_sharers++;
            }
            int vote = brain.predict_raw(ip_val, current_sharers);
            brain.train(ip_val, current_sharers, true, vote);
        }
    } else {
        if (is_sampled[set]) {
            int ghost_sharers;
            MESI_State ghost_state;
            if (ghosts[set].lookup(tag, ip_val, ghost_sharers, ghost_state)) {
                (void)ghost_state; // state recorded but no longer read by the perceptron
                int vote = brain.predict_raw(ip_val, ghost_sharers);
                for (int k = 0; k < 5; k++)
                    brain.train(ip_val, ghost_sharers, true, vote);
            }
        }
    }
}
