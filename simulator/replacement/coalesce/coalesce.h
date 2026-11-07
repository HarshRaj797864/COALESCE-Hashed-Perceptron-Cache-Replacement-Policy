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
// Reset bit_array after this many insertions. Keeps occupancy below the design
// point of 237 entries (12.5% FP rate); see coalesce_paper/citations/justifications/B7.
constexpr int BLOOM_RESET_THRESHOLD = 150;
// V2 parameters (2026-05-21): sample 1/32 sets, 128 ghost entries per sampled set.
// Total per-set storage = 128 B (Bloom) + 512 B (ghost) = 640 B; with 64 sampled sets
// (2048/32) the total is ~41 KB — a 3.6× reduction from the original V0 design.
constexpr int SAMPLING_MODULO = 32;
constexpr int GHOST_CAPACITY = 128;

struct CompactGhostEntry {
    uint32_t packed;
    CompactGhostEntry() : packed(0) {}
    CompactGhostEntry(uint64_t tag, uint64_t pc, int sharers, MESI_State state);
    bool is_valid() const;
    uint32_t get_pc_sig() const;
    uint32_t get_tag_partial() const;
    int get_sharers() const;
    MESI_State get_state() const;
    bool matches(uint64_t tag) const;   // address only; the PC is stored, not matched
};

class BloomFilter {
    std::vector<bool> bit_array;
    std::vector<CompactGhostEntry> ghost_tags;
    int insert_count;   // tracks insertions since last bit_array reset
public:
    BloomFilter();
    void insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state);
    bool lookup(uint64_t tag, uint64_t& out_alloc_pc, int& out_sharers, MESI_State& out_state);
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

    // Sharer histograms live in the policy: develop's get_sim_stats() returns
    // by value, so a policy cannot write through it.
    //
    // TWO histograms, because one alone proves nothing. sharer_hist counts
    // EVERY candidate way examined in find_victim -- the population of what is
    // resident. victim_sharer_hist counts only the way actually evicted. The
    // hypothesis under test is that COALESCE's coherence bias, which is
    // strictly non-negative and keys on MESI state and sharer count, leaves
    // unbiased lines (page-table entries among them) as the lowest-voted way by
    // construction and so evicts them out of proportion to their presence.
    // That is a comparison between the two distributions; either on its own is
    // consistent with any outcome.
    //
    // sharer_hist was previously printed as "VICTIM SHARER HIST" although it
    // has always counted candidates. The label is corrected to CANDIDATE here.
    uint64_t sharer_hist[17] = {0};
    uint64_t victim_sharer_hist[17] = {0};

    // Same comparison for the other half of the bias. cand_modified counts
    // MODIFIED lines seen as candidates, victim_modified those actually
    // evicted. If the +40 protects as intended, MODIFIED lines should be
    // evicted at a LOWER rate than they are present.
    uint64_t cand_modified = 0;
    uint64_t victim_modified = 0;
    uint64_t cand_biased = 0;    // would receive any bias: MODIFIED or sharers>=2
    uint64_t victim_biased = 0;

    // Training-path instrumentation. Without it there is no way to tell whether
    // the ghost-tag rescue fires at all -- and it was dead for nine months
    // (keyed on the incoming line instead of the evicted one) while compiling,
    // running and producing plausible numbers. Hawkeye and Mockingjay both
    // count their training events; this policy counted nothing.
    uint64_t stat_ghost_inserts = 0;
    uint64_t stat_ghost_hits = 0;   // rescue actually fired
    uint64_t stat_detrains = 0;
    uint64_t stat_hit_trains = 0;

    explicit coalesce(champsim::modules::ModuleBuilder builder);

    void initialize_replacement() override {}

    long find_victim(uint32_t triggering_cpu, uint64_t instr_id, long set, const champsim::cache_block* current_set, champsim::address ip, champsim::address full_addr, access_type type) override;

    // Insertion hook. Without it ChampSim never reports fills to this policy
    // (inc/cache.h:475 gates update_replacement_state on `hit || has_cache_fill`),
    // so the ghost-tag rescue -- which only runs on a miss -- was dead code and
    // had never executed in any result.
    void replacement_cache_fill(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr, access_type type) override;

    void update_replacement_state(uint32_t triggering_cpu, long set, long way, champsim::address full_addr, champsim::address ip, champsim::address victim_addr, access_type type, bool hit) override;

    void replacement_final_stats() override;
};

#endif
