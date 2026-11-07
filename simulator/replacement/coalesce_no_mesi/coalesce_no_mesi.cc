#include "coalesce_no_mesi.h"

#include <fmt/core.h>
#include <algorithm>
#include <cmath>
#include <cassert>

// --- Ghost-structure hashing (fixed 2026-09-23) ------------------------------
//
// The ghost tag and Bloom filter are PER SET, so the tag they store must be the
// address bits ABOVE the set index. They were given the full line address, whose
// low lg2(NUM_SET) bits ARE the set index -- identical for every line one
// structure ever holds. The 14-bit partial tag then kept only 14 - set_bits
// distinguishing bits (3 at 2 MB, none at 16384+ sets), the ghost slot
// (tag ^ pc) % 128 depended on the PC alone, and so the "rescue" fired whenever
// the same PC had evicted ANY line in the set: 12.5% false rescues at 2 MB and
// 100% at 8c/16c scaled, matching the observed 52-56% and 89-94% rates.
// Callers now pass (line_addr >> set_bits); see set_bits in the header.
//
// The Bloom filter's three hashes were (tag ^ pc ^ i*k) % 1024. Taking % 1024
// keeps the low 10 bits, and XOR with a constant only permutes them, so the
// three positions were one hash shifted: keys colliding on one collided on all
// three. Each position is now a full 64-bit mix, so they are independent.
//
// Evidence: bench/policy_sanity/coalesce_ghost_defect_2026-09-23.md
static inline uint64_t ghost_mix(uint64_t x) {   // splitmix64 finalizer
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return x;
}
//
// Keyed on the ADDRESS alone (second change, 2026-09-23). The PC is STORED in
// the entry and returned by lookup(), but is no longer part of the key. COALESCE
// scores, detrains and hit-trains the line's ALLOCATING PC, so a rescue means
// "this line came back after we threw it out" -- whichever PC brings it back --
// and it must train the allocating PC it stored, not the refilling one. Keyed on
// (tag, pc), the rescue fired only for same-PC returns: on 429.mcf that missed
// 989 of 1,402 genuine early evictions (70.5%), all inside the ghost window.
// Training the stored 12-bit signature is exact: every perceptron hash reads
// only the PC's low 11 bits (checked by coalesce_ablation_probe.cc).
static inline uint64_t ghost_key(uint64_t tag) { return ghost_mix(tag); }
static inline uint64_t ghost_hash_i(uint64_t tag, int i) {
    return ghost_mix(ghost_key(tag) + static_cast<uint64_t>(i + 1) * 0x9e3779b97f4a7c15ULL);
}


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
bool CNM_GhostEntry::matches(uint64_t tag) const {
    if (!is_valid()) return false;
    return get_tag_partial() == (tag & 0x3FFF);
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
        uint64_t hash = ghost_hash_i(tag, i) % CNM_BLOOM_SIZE;
        bit_array.at(hash) = true;
    }
    uint64_t ghost_hash = ghost_key(tag) % CNM_GHOST_CAPACITY;
    ghost_tags.at(ghost_hash) = CNM_GhostEntry(tag, pc, sharers, state);
}
bool CNM_BloomFilter::lookup(uint64_t tag, uint64_t& out_alloc_pc, int& out_sharers, MESI_State& out_state) {
    for (int i = 0; i < CNM_BLOOM_HASHES; i++) {
        uint64_t hash = ghost_hash_i(tag, i) % CNM_BLOOM_SIZE;
        if (!bit_array.at(hash)) return false;
    }
    uint64_t ghost_hash = ghost_key(tag) % CNM_GHOST_CAPACITY;
    const CNM_GhostEntry& entry = ghost_tags.at(ghost_hash);
    if (entry.matches(tag)) {
        out_alloc_pc = entry.get_pc_sig();
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
    // The full policy's get_hash0 with the state term at zero (INVALID == 0).
    // This used to be (pc ^ 0x9e3779b9) ^ (pc >> 11): removing the MESI feature
    // ALSO swapped in upper PC bits, giving this ablation a different PC hash with
    // less aliasing, so "no_mesi beats coalesce" could not be attributed to the
    // feature. An ablation must differ in exactly one factor. Verified by
    // bench/policy_sanity/coalesce_ablation_probe.cc.
    uint64_t h = pc ^ 0x9e3779b9;
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
champsim::modules::replacement::register_module<coalesce_no_mesi> coalesce_no_mesi_register("coalesce_no_mesi");

coalesce_no_mesi::coalesce_no_mesi(champsim::modules::ModuleBuilder builder)
    : cache_(builder.get_parent<champsim::modules::cache_module>()),
      NUM_WAY(static_cast<long>(builder.get_parent<champsim::modules::cache_module>()->num_ways()))
{
    long sets = static_cast<long>(cache_->num_sets());
    // Per-set ghost structures must store the tag bits above the set index.
    assert(sets > 0 && (sets & (sets - 1)) == 0);
    set_bits = __builtin_ctzll(static_cast<unsigned long long>(sets));
    ghosts.resize(sets);
    is_sampled.resize(sets, false);
    for (long i = 0; i < sets; i++)
        if (i % CNM_SAMPLING_MODULO == 0) is_sampled.at(i) = true;
}

long coalesce_no_mesi::find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set,
                                   const champsim::cache_block* current_set,
                                   champsim::address ip, champsim::address full_addr,
                                   access_type type) {
    long victim   = 0;
    int  min_vote = 999999;
    long ways     = NUM_WAY;

    for (long w = 0; w < ways; w++) {
        if (!current_set[w].valid) return w;

        int current_sharers = __builtin_popcount(current_set[w].sharer_mask);

        if (current_sharers >= 0 && current_sharers <= 16) {
            sharer_hist[current_sharers]++;
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

    if (is_sampled.at(set)) {
        // Key the ghost on the EVICTED line's address, not the incoming one.
        // The rescue signal is "this address missed again after we threw it
        // out", so the tag and the metadata stored beside it must describe the
        // same line.
        uint64_t tag = (current_set[victim].address.to<uint64_t>() >> 6) >> set_bits;
        int victim_sharers = __builtin_popcount(current_set[victim].sharer_mask);
        stat_ghost_inserts++;
        ghosts.at(set).insert(tag, current_set[victim].ip, victim_sharers, current_set[victim].state);

        // Detrain. We are evicting this context, so train it negatively. If
        // that turns out to be wrong, the ghost-tag rescue in
        // replacement_cache_fill overturns it with the 5x boosted positive
        // train. Without this the perceptron receives ONLY positive
        // reinforcement -- nothing anywhere tells it a context should be
        // evicted -- which makes it a one-sided reinforcer rather than a
        // classifier. Hawkeye (CRC2 paper section 2.3), SHiP and Mockingjay
        // all detrain on eviction; this is the COALESCE analogue.
        int victim_vote = brain.predict_raw(current_set[victim].ip, victim_sharers);
        stat_detrains++;
        brain.train(current_set[victim].ip, victim_sharers, false, victim_vote);
    }

    return victim;
}

void coalesce_no_mesi::replacement_cache_fill(uint32_t triggering_cpu, long set, long way,
                                              champsim::address full_addr, champsim::address ip,
                                              champsim::address victim_addr, access_type type) {
    // A miss is being filled. If the incoming line carries a ghost tag then we
    // evicted it too early, so rescue that context with the boosted train.
    if (!is_sampled.at(set)) return;

    uint64_t tag    = (full_addr.to<uint64_t>() >> 6) >> set_bits;
    uint64_t alloc_pc = 0;   // the evicted line's allocating PC, from the ghost

    int ghost_sharers;
    MESI_State ghost_state;
    if (ghosts.at(set).lookup(tag, alloc_pc, ghost_sharers, ghost_state)) {
        stat_ghost_hits++;
        (void)ghost_state; // state recorded but no longer read by the perceptron
        int vote = brain.predict_raw(alloc_pc, ghost_sharers);
        for (int k = 0; k < 5; k++)
            brain.train(alloc_pc, ghost_sharers, true, vote);
    }
}

void coalesce_no_mesi::update_replacement_state(uint32_t triggering_cpu, long set, long way,
                                                champsim::address full_addr, champsim::address ip,
                                                champsim::address victim_addr, access_type type,
                                                bool hit) {
    // Misses arrive through replacement_cache_fill instead; here `way` is
    // past-the-end and must not be used to index. Mirrors upstream lru.
    if (!hit) return;
    if (!is_sampled.at(set)) return;


    const auto* bp = cache_->get_block(set, way);
    if (bp == nullptr) return; // way is past-the-end; nothing to train on
    stat_hit_trains++;
    const auto& block_meta = *bp;
    // Train the line's ALLOCATING PC, not the PC that hit it (fixed 2026-09-23).
    // find_victim scores a line by current_set[w].ip, detraining and the ghost
    // rescue use the same allocating PC, and cache.cc carries it "so a
    // replacement policy can recover the context that brought the line in".
    // Training the hitting PC instead credited a context no eviction decision
    // consults: on 429.mcf 96.6% of LLC hits came from a different, non-zero PC
    // than the one that allocated the line. See
    // bench/policy_sanity/coalesce_preaudit_2026-09-23.md.
    const uint64_t ctx = block_meta.ip;
    int current_sharers = __builtin_popcount(block_meta.sharer_mask);
    int vote = brain.predict_raw(ctx, current_sharers);
    brain.train(ctx, current_sharers, true, vote);
}

void coalesce_no_mesi::replacement_final_stats()
{
    fmt::print("\n{}: ghost_inserts {} ghost_rescues {} ({:.4f}% of inserts)  detrains {}  hit_trains {}\n",
               "COALESCE", stat_ghost_inserts, stat_ghost_hits,
               stat_ghost_inserts ? 100.0 * static_cast<double>(stat_ghost_hits) / static_cast<double>(stat_ghost_inserts) : 0.0,
               stat_detrains, stat_hit_trains);

    uint64_t total = 0;
    for (auto v : sharer_hist) total += v;
    if (total == 0) return;
    fmt::print("\n{} VICTIM SHARER HIST TOTAL: {:14}\n", "COALESCE", total);
    for (std::size_t i = 0; i < std::size(sharer_hist); i++) {
        if (sharer_hist[i] > 0)
            fmt::print("{} VICTIM SHARER HIST[{:2}]: {:14}  ({:6.3f}%)\n", "COALESCE", i, sharer_hist[i],
                       100.0 * static_cast<double>(sharer_hist[i]) / static_cast<double>(total));
    }
}
