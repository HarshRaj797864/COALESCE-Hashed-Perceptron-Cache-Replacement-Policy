#include "coalesce.h"
#include <cmath>

// --- CompactGhostEntry Implementation ---
CompactGhostEntry::CompactGhostEntry(uint64_t tag, uint64_t pc, int sharers, MESI_State state) {
    uint32_t pc_sig = (pc & 0xFFF);
    uint32_t tag_partial = (tag & 0x3FFF);
    uint32_t sharer_bits = (sharers & 0x7);
    uint32_t state_bits = (state & 0x3);
    packed = (pc_sig << 20) | (tag_partial << 6) | (sharer_bits << 3) | (state_bits << 1) | 1;
}
bool CompactGhostEntry::is_valid() const { return packed & 0x1; }
uint32_t CompactGhostEntry::get_pc_sig() const { return (packed >> 20) & 0xFFF; }
uint32_t CompactGhostEntry::get_tag_partial() const { return (packed >> 6) & 0x3FFF; }
int CompactGhostEntry::get_sharers() const { return (packed >> 3) & 0x7; }
MESI_State CompactGhostEntry::get_state() const { return (MESI_State)((packed >> 1) & 0x3); }
bool CompactGhostEntry::matches(uint64_t tag, uint64_t pc) const {
    if (!is_valid()) return false;
    return (get_pc_sig() == (pc & 0xFFF)) && (get_tag_partial() == (tag & 0x3FFF));
}

// --- BloomFilter Implementation ---
BloomFilter::BloomFilter() {
    bit_array.resize(BLOOM_SIZE, false);
    ghost_tags.resize(GHOST_CAPACITY);
}
void BloomFilter::insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state) {
    for (int i = 0; i < BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % BLOOM_SIZE;
        bit_array[hash] = true;
    }
    uint64_t ghost_hash = (tag ^ pc) % GHOST_CAPACITY;
    ghost_tags[ghost_hash] = CompactGhostEntry(tag, pc, sharers, state);
}
bool BloomFilter::lookup(uint64_t tag, uint64_t pc, int& out_sharers, MESI_State& out_state) {
    for (int i = 0; i < BLOOM_HASHES; i++) {
        uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % BLOOM_SIZE;
        if (!bit_array[hash]) return false;
    }
    uint64_t ghost_hash = (tag ^ pc) % GHOST_CAPACITY;
    const CompactGhostEntry& entry = ghost_tags[ghost_hash];
    if (entry.matches(tag, pc)) {
        out_sharers = entry.get_sharers();
        out_state = entry.get_state();
        return true;
    }
    return false;
}

// --- PerceptronBrain Implementation ---
PerceptronBrain::PerceptronBrain() {
    table0.resize(PERCEPTRON_TABLE_SIZE, 0);
    table1.resize(PERCEPTRON_TABLE_SIZE, 0);
    for (int i = 0; i < PERCEPTRON_TABLE_SIZE; i++) {
        table0[i] = -5 + (i % 11);
        table1[i] = -5 + ((i * 7) % 11);
    }
}
int PerceptronBrain::get_hash0(uint64_t pc, MESI_State state) {
    uint64_t h = pc ^ 0x9e3779b9;
    h ^= (state << 8);
    return h % PERCEPTRON_TABLE_SIZE;
}
int PerceptronBrain::get_hash1(uint64_t pc, int sharers) {
    uint64_t h = pc ^ 0x85ebca6b;
    h ^= (sharers << 4);
    return h % PERCEPTRON_TABLE_SIZE;
}
int PerceptronBrain::predict_raw(uint64_t pc, int sharers, MESI_State state) {
    return table0[get_hash0(pc, state)] + table1[get_hash1(pc, sharers)];
}
void PerceptronBrain::train(uint64_t pc, int sharers, MESI_State state, bool positive, int current_vote) {
    bool mispredicted = (positive && current_vote <= 0) || (!positive && current_vote > 0);
    bool low_confidence = std::abs(current_vote) <= THRESHOLD;
    if (mispredicted || low_confidence) {
        int h0 = get_hash0(pc, state);
        int h1 = get_hash1(pc, sharers);
        int direction = positive ? 1 : -1;
        
        int new_val0 = table0[h0] + direction;
        if (new_val0 <= MAX_WEIGHT && new_val0 >= MIN_WEIGHT) table0[h0] = new_val0;
        
        int new_val1 = table1[h1] + direction;
        if (new_val1 <= MAX_WEIGHT && new_val1 >= MIN_WEIGHT) table1[h1] = new_val1;
    }
}

// --- Main COALESCE Policy ---
coalesce::coalesce(CACHE* cache) : replacement(cache) {
    long sets = cache->NUM_SET;
    ghosts.resize(sets);
    is_sampled.resize(sets, false);
    for (long i = 0; i < sets; i++) {
        if (i % SAMPLING_MODULO == 0) is_sampled[i] = true;
    }
}

long coalesce::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip, champsim::address full_addr, access_type type) {
    long victim = 0;
    int min_vote = 999999;
    long ways = 16; 

    for (long w = 0; w < ways; w++) {
        if (!current_set[w].valid) return w;

        // Decode the bitmask
        int current_sharers = 0;
        for (int i = 0; i < 8; i++) {
            if ((current_set[w].sharer_mask >> i) & 1) current_sharers++;
        }

        // NO .to<uint64_t>() here, current_set[w].ip is already a uint64_t
        int raw_vote = brain.predict_raw(current_set[w].ip, current_sharers, current_set[w].state);
        int final_vote = raw_vote;

        if (raw_vote > 0) {
            if (current_set[w].state == MODIFIED) final_vote += 40;
            if (current_sharers >= 2) final_vote += (20 * current_sharers);
        }

        if (final_vote < min_vote) {
            min_vote = final_vote;
            victim = w;
        }
    }

    if (is_sampled[set]) {
        uint64_t tag = full_addr.to<uint64_t>() >> 6;
        int victim_sharers = 0;
        for (int i = 0; i < 8; i++) {
            if ((current_set[victim].sharer_mask >> i) & 1) victim_sharers++;
        }
        // NO .to<uint64_t>() here either
        ghosts[set].insert(tag, current_set[victim].ip, victim_sharers, current_set[victim].state);
    }

    return victim;
}

void coalesce::update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr, access_type type, uint8_t hit) {
    uint64_t tag = full_addr.to<uint64_t>() >> 6;
    uint64_t ip_val = ip.to<uint64_t>();

    if (hit) {
        if (is_sampled[set]) {
            // REACH INTO THE CACHE TO GET THE REAL METADATA
            auto& block_meta = intern_->block[set * intern_->NUM_WAY + way];
            
            // Decode the bitmask to get real sharer count
            int current_sharers = 0;
            for (int i = 0; i < 8; i++) {
                if ((block_meta.sharer_mask >> i) & 1) current_sharers++;
            }

            int vote = brain.predict_raw(ip_val, current_sharers, block_meta.state);
            brain.train(ip_val, current_sharers, block_meta.state, true, vote);
        }
    } else {
        if (is_sampled[set]) {
            int ghost_sharers;
            MESI_State ghost_state;
            if (ghosts[set].lookup(tag, ip_val, ghost_sharers, ghost_state)) {
                int vote = brain.predict_raw(ip_val, ghost_sharers, ghost_state);
                for(int k = 0; k < 5; k++) {
                    brain.train(ip_val, ghost_sharers, ghost_state, true, vote);
                }
            }
        }
    }
}
