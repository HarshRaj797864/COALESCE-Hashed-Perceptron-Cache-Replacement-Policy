#include <iostream>
#include <vector>
#include <cmath>
#include <iomanip>
#include <string>
#include <cstdint>
#include <algorithm>
#include <map>

// ==========================================
// CONFIGURATION & CONSTANTS
// ==========================================
const int NUM_SETS = 64;
const int WAYS = 16;
const int CACHE_SIZE_LINES = NUM_SETS * WAYS;

const int LATENCY_L3_HIT = 15;
const int LATENCY_DRAM = 200;
const int LATENCY_COHERENCE_PENALTY = 100;

const int PERCEPTRON_TABLE_SIZE = 2048;
const int MAX_WEIGHT = 127;
const int MIN_WEIGHT = -128;
const int THRESHOLD = 35;
const int VETO_OVERRIDE = -100;

const int BLOOM_SIZE = 1024;
const int BLOOM_HASHES = 3;

const int SHCT_SIZE = 1024;

const int SAMPLING_MODULO = 16;

// ==========================================
// DATA STRUCTURES
// ==========================================

enum MESI_State
{
    INVALID = 0,
    SHARED = 1,
    EXCLUSIVE = 2,
    MODIFIED = 3
};

struct CacheLine
{
    bool valid = false;
    uint64_t tag = 0;
    uint64_t pc = 0;
    int sharers = 0;
    MESI_State state = INVALID;

    int lru_stack = 0;
    int rrpv = 3;
    bool is_dead_prediction = false;
};

// ==========================================
// COMPACT GHOST ENTRY (Flit-Compatible)
// ==========================================
struct CompactGhostEntry
{
    uint32_t packed;

    CompactGhostEntry() : packed(0) {}

    CompactGhostEntry(uint64_t tag, uint64_t pc, int sharers, MESI_State state)
    {
        uint32_t pc_sig = (pc & 0xFFF);
        uint32_t tag_partial = (tag & 0x3FFF);
        uint32_t sharer_bits = (sharers & 0x7);
        uint32_t state_bits = (state & 0x3);

        packed = (pc_sig << 20) |
                 (tag_partial << 6) |
                 (sharer_bits << 3) |
                 (state_bits << 1) |
                 1;
    }

    bool is_valid() const { return packed & 0x1; }
    uint32_t get_pc_sig() const { return (packed >> 20) & 0xFFF; }
    uint32_t get_tag_partial() const { return (packed >> 6) & 0x3FFF; }
    int get_sharers() const { return (packed >> 3) & 0x7; }
    MESI_State get_state() const { return (MESI_State)((packed >> 1) & 0x3); }

    bool matches(uint64_t tag, uint64_t pc) const
    {
        if (!is_valid()) return false;
        return (get_pc_sig() == (pc & 0xFFF)) &&
               (get_tag_partial() == (tag & 0x3FFF));
    }
};

// ==========================================
// BLOOM FILTER WITH FEATURE STORAGE
// ==========================================
class BloomFilter
{
    std::vector<bool> bit_array;
    std::vector<CompactGhostEntry> ghost_tags;
    int insertion_ptr;

    static constexpr int GHOST_CAPACITY = 256;

public:
    BloomFilter() : insertion_ptr(0)
    {
        bit_array.resize(BLOOM_SIZE, false);
        ghost_tags.resize(GHOST_CAPACITY);
    }

    void clear()
    {
        std::fill(bit_array.begin(), bit_array.end(), false);
        std::fill(ghost_tags.begin(), ghost_tags.end(), CompactGhostEntry());
        insertion_ptr = 0;
    }

    void insert(uint64_t tag, uint64_t pc, int sharers, MESI_State state)
    {
        for (int i = 0; i < BLOOM_HASHES; i++)
        {
            uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % BLOOM_SIZE;
            bit_array[hash] = true;
        }
        uint64_t ghost_hash = (tag ^ pc) % GHOST_CAPACITY;
        ghost_tags[ghost_hash] = CompactGhostEntry(tag, pc, sharers, state);
    }

    bool lookup(uint64_t tag, uint64_t pc, int& out_sharers, MESI_State& out_state)
    {
        for (int i = 0; i < BLOOM_HASHES; i++)
        {
            uint64_t hash = (tag ^ pc ^ (i * 0x9e3779b9)) % BLOOM_SIZE;
            if (!bit_array[hash])
                return false;
        }

        uint64_t ghost_hash = (tag ^ pc) % GHOST_CAPACITY;
        const CompactGhostEntry& entry = ghost_tags[ghost_hash];

        if (entry.matches(tag, pc))
        {
            out_sharers = entry.get_sharers();
            out_state = entry.get_state();
            return true;
        }

        return false;
    }
};

// ==========================================
// PERCEPTRON BRAIN (Dual Hashed)
// ==========================================
class PerceptronBrain
{
    std::vector<int> table0;
    std::vector<int> table1;

public:
    PerceptronBrain()
    {
        table0.resize(PERCEPTRON_TABLE_SIZE, 0);
        table1.resize(PERCEPTRON_TABLE_SIZE, 0);

        for (int i = 0; i < PERCEPTRON_TABLE_SIZE; i++)
        {
            table0[i] = -5 + (i % 11);
            table1[i] = -5 + ((i * 7) % 11);
        }
    }

    int get_hash0(uint64_t pc, MESI_State state)
    {
        uint64_t h = pc ^ 0x9e3779b9;
        h ^= (state << 8);
        return h % PERCEPTRON_TABLE_SIZE;
    }

    int get_hash1(uint64_t pc, int sharers)
    {
        uint64_t h = pc ^ 0x85ebca6b;
        h ^= (sharers << 4);
        return h % PERCEPTRON_TABLE_SIZE;
    }

    int predict_raw(uint64_t pc, int sharers, MESI_State state)
    {
        return table0[get_hash0(pc, state)] + table1[get_hash1(pc, sharers)];
    }

    void train(uint64_t pc, int sharers, MESI_State state, bool positive, int current_vote)
    {
        bool mispredicted = (positive && current_vote <= 0) || (!positive && current_vote > 0);
        bool low_confidence = std::abs(current_vote) <= THRESHOLD;

        if (mispredicted || low_confidence)
        {
            int h0 = get_hash0(pc, state);
            int h1 = get_hash1(pc, sharers);

            int direction = positive ? 1 : -1;

            int new_val0 = table0[h0] + direction;
            if (new_val0 <= MAX_WEIGHT && new_val0 >= MIN_WEIGHT)
                table0[h0] = new_val0;

            int new_val1 = table1[h1] + direction;
            if (new_val1 <= MAX_WEIGHT && new_val1 >= MIN_WEIGHT)
                table1[h1] = new_val1;
        }
    }
};

// ==========================================
// ABSTRACT POLICY BASE
// ==========================================
class ReplacementPolicy
{
public:
    virtual void update_on_hit(int set_idx, int way, const CacheLine &line) = 0;
    virtual void update_on_miss(int set_idx, int way, uint64_t pc, uint64_t tag) = 0;
    virtual int find_victim(int set_idx, const std::vector<CacheLine> &set, uint64_t pc, int sharers, MESI_State state) = 0;
    virtual std::string name() = 0;
    virtual ~ReplacementPolicy() {}
};

// ==========================================
// POLICY 1: LRU (Baseline)
// ==========================================
class LRU_Policy : public ReplacementPolicy
{
    std::vector<std::vector<int>> stacks;

public:
    LRU_Policy()
    {
        stacks.resize(NUM_SETS, std::vector<int>(WAYS));
        for (int i = 0; i < NUM_SETS; i++)
            for (int w = 0; w < WAYS; w++)
                stacks[i][w] = w;
    }

    void update_stack(int set_idx, int way)
    {
        int old_pos = stacks[set_idx][way];
        for (int w = 0; w < WAYS; w++)
        {
            if (stacks[set_idx][w] < old_pos)
                stacks[set_idx][w]++;
        }
        stacks[set_idx][way] = 0;
    }

    void update_on_hit(int set_idx, int way, const CacheLine &line) override { update_stack(set_idx, way); }
    void update_on_miss(int set_idx, int way, uint64_t pc, uint64_t tag) override { update_stack(set_idx, way); }

    int find_victim(int set_idx, const std::vector<CacheLine> &set, uint64_t pc, int sharers, MESI_State state) override
    {
        for (int w = 0; w < WAYS; w++)
        {
            if (!set[w].valid)
                return w;
            if (stacks[set_idx][w] == WAYS - 1)
                return w;
        }
        return 0;
    }
    std::string name() override { return "LRU"; }
};

// ==========================================
// POLICY 2: SRRIP (Baseline)
// ==========================================
class SRRIP_Policy : public ReplacementPolicy
{
protected:
    std::vector<std::vector<int>> rrpv;
public:
    SRRIP_Policy()
    {
        rrpv.resize(NUM_SETS, std::vector<int>(WAYS, 3));
    }

    void update_on_hit(int set_idx, int way, const CacheLine &line) override
    {
        rrpv[set_idx][way] = 0;
    }

    void update_on_miss(int set_idx, int way, uint64_t pc, uint64_t tag) override
    {
        rrpv[set_idx][way] = 2;
    }

    int find_victim(int set_idx, const std::vector<CacheLine> &set, uint64_t pc, int sharers, MESI_State state) override
    {
        while (true)
        {
            for (int w = 0; w < WAYS; w++)
            {
                if (!set[w].valid)
                    return w;
                if (rrpv[set_idx][w] == 3)
                    return w;
            }
            for (int w = 0; w < WAYS; w++)
            {
                if (rrpv[set_idx][w] < 3)
                    rrpv[set_idx][w]++;
            }
        }
    }
    std::string name() override { return "SRRIP"; }
};

// ==========================================
// POLICY 3: SHiP (PC-Aware Baseline)
// ==========================================
class SHiP_Policy : public SRRIP_Policy
{
    std::vector<int> shct;
public:
    SHiP_Policy()
    {
        shct.resize(SHCT_SIZE, 0);
    }

    int get_sig(uint64_t pc) { return pc % SHCT_SIZE; }

    void update_on_hit(int set_idx, int way, const CacheLine &line) override
    {
        rrpv[set_idx][way] = 0;
        int sig = get_sig(line.pc);
        if (shct[sig] > 0)
            shct[sig]--;
    }

    void update_on_miss(int set_idx, int way, uint64_t pc, uint64_t tag) override
    {
        int sig = get_sig(pc);
        if (shct[sig] >= 2)
            rrpv[set_idx][way] = 3;
        else
            rrpv[set_idx][way] = 2;
    }

    int find_victim(int set_idx, const std::vector<CacheLine> &set, uint64_t pc, int sharers, MESI_State state) override
    {
        return SRRIP_Policy::find_victim(set_idx, set, pc, sharers, state);
    }

    std::string name() override { return "SHiP"; }
};

// ==========================================
// POLICY 4: SDBP (Sampling Dead Block)
// ==========================================
class SDBP_Policy : public LRU_Policy
{
    std::vector<int> dead_table;
public:
    SDBP_Policy()
    {
        dead_table.resize(SHCT_SIZE, 0);
    }

    int get_hash(uint64_t pc) { return pc % SHCT_SIZE; }

    void update_on_hit(int set_idx, int way, const CacheLine &line) override
    {
        LRU_Policy::update_on_hit(set_idx, way, line);
        int h = get_hash(line.pc);
        if (dead_table[h] > 0)
            dead_table[h]--;
    }

    int find_victim(int set_idx, const std::vector<CacheLine> &set, uint64_t pc, int sharers, MESI_State state) override
    {
        for (int w = 0; w < WAYS; w++)
        {
            if (!set[w].valid)
                return w;
            if (dead_table[get_hash(set[w].pc)] >= 2)
                return w;
        }
        return LRU_Policy::find_victim(set_idx, set, pc, sharers, state);
    }

    void on_evict(uint64_t pc)
    {
        int h = get_hash(pc);
        if (dead_table[h] < 3)
            dead_table[h]++;
    }

    std::string name() override { return "SDBP (Sim)"; }
};

// ==========================================
// POLICY 5: COALESCE
// ==========================================
class COALESCE_Policy : public ReplacementPolicy
{
    PerceptronBrain brain;
    std::vector<BloomFilter> ghosts;
    std::vector<bool> is_sampled;

public:
    COALESCE_Policy()
    {
        ghosts.resize(NUM_SETS);
        is_sampled.resize(NUM_SETS, false);

        for (int i = 0; i < NUM_SETS; i++)
        {
            if (i % SAMPLING_MODULO == 0)
                is_sampled[i] = true;
        }
    }

    void update_on_hit(int set_idx, int way, const CacheLine &line) override
    {
        if (is_sampled[set_idx])
        {
            int vote = brain.predict_raw(line.pc, line.sharers, line.state);
            brain.train(line.pc, line.sharers, line.state, true, vote);
        }
    }

    void update_on_miss(int set_idx, int way, uint64_t pc, uint64_t tag) override
    {
        if (is_sampled[set_idx])
        {
            int ghost_sharers;
            MESI_State ghost_state;

            if (ghosts[set_idx].lookup(tag, pc, ghost_sharers, ghost_state))
            {
                int vote = brain.predict_raw(pc, ghost_sharers, ghost_state);

                for (int k = 0; k < 5; k++)
                {
                    brain.train(pc, ghost_sharers, ghost_state, true, vote);
                }
            }
        }
    }

    int find_victim(int set_idx, const std::vector<CacheLine> &set, uint64_t pc, int sharers, MESI_State state) override
    {
        int victim = -1;
        int min_vote = 999999;

        for (int w = 0; w < WAYS; w++)
        {
            if (!set[w].valid)
                return w;

            int raw_vote = brain.predict_raw(set[w].pc, set[w].sharers, set[w].state);
            int final_vote = raw_vote;

            if (raw_vote > VETO_OVERRIDE)
            {
                if (set[w].state == MODIFIED)
                    final_vote += 150;

                if (set[w].sharers >= 2)
                    final_vote += 75;
            }

            if (final_vote < min_vote)
            {
                min_vote = final_vote;
                victim = w;
            }
        }

        if (is_sampled[set_idx] && victim >= 0)
        {
            CacheLine v = set[victim];
            ghosts[set_idx].insert(v.tag, v.pc, v.sharers, v.state);
        }

        return victim;
    }

    std::string name() override { return "COALESCE-Fixed"; }
};

// ==========================================
// SIMULATOR ENGINE
// ==========================================
class Simulator
{
    ReplacementPolicy *policy;
    std::vector<std::vector<CacheLine>> cache;
    SDBP_Policy *sdbp_ref = nullptr;

public:
    uint64_t hits = 0;
    uint64_t misses = 0;
    uint64_t coherence_evictions_saved = 0;
    uint64_t total_latency = 0;

    Simulator(ReplacementPolicy *p) : policy(p)
    {
        cache.resize(NUM_SETS, std::vector<CacheLine>(WAYS));
        if (p->name() == "SDBP (Sim)")
            sdbp_ref = (SDBP_Policy *)p;
    }

    void access(uint64_t addr, uint64_t pc, int sharers, MESI_State state)
    {
        int set_idx = (addr / 64) % NUM_SETS;
        uint64_t tag = addr;

        for (int w = 0; w < WAYS; w++)
        {
            if (cache[set_idx][w].valid && cache[set_idx][w].tag == tag)
            {
                hits++;
                total_latency += LATENCY_L3_HIT;

                cache[set_idx][w].sharers = sharers;
                cache[set_idx][w].state = state;
                cache[set_idx][w].pc = pc;

                policy->update_on_hit(set_idx, w, cache[set_idx][w]);
                return;
            }
        }

        misses++;
        int victim = policy->find_victim(set_idx, cache[set_idx], pc, sharers, state);

        CacheLine v = cache[set_idx][victim];
        if (v.valid)
        {
            if (v.state == MODIFIED || v.sharers > 1)
                total_latency += (LATENCY_DRAM + LATENCY_COHERENCE_PENALTY);
            else
                total_latency += LATENCY_DRAM;

            if (sdbp_ref)
                sdbp_ref->on_evict(v.pc);
        }
        else
        {
            total_latency += LATENCY_DRAM;
        }

        cache[set_idx][victim] = {true, tag, pc, sharers, state, 0, 2};
        policy->update_on_miss(set_idx, victim, pc, tag);
    }

    void print_stats()
    {
        double hit_rate = 100.0 * hits / (hits + misses);
        double amat = (double)total_latency / (hits + misses);

        std::cout << std::left << std::setw(20) << policy->name()
                  << " | Hit Rate: " << std::fixed << std::setprecision(2) << std::setw(6) << hit_rate << "%"
                  << " | AMAT: " << std::setprecision(1) << std::setw(6) << amat << " cyc"
                  << " | Total Latency: " << total_latency << "\n";
    }
};

// ==========================================
// MAIN & WORKLOADS
// ==========================================
int main()
{
    std::cout << "========================================================\n";
    std::cout << "                      COALESCE\n";
    std::cout << "========================================================\n\n";

    auto run_scenario = [](std::string name, auto workload_gen)
    {
        std::cout << ">>> SCENARIO: " << name << "\n";

        LRU_Policy lru;
        Simulator s1(&lru);
        workload_gen(s1);
        s1.print_stats();

        SRRIP_Policy srrip;
        Simulator s2(&srrip);
        workload_gen(s2);
        s2.print_stats();

        SHiP_Policy ship;
        Simulator s3(&ship);
        workload_gen(s3);
        s3.print_stats();

        SDBP_Policy sdbp;
        Simulator s4(&sdbp);
        workload_gen(s4);
        s4.print_stats();

        COALESCE_Policy coal;
        Simulator s5(&coal);
        workload_gen(s5);
        s5.print_stats();

        std::cout << "--------------------------------------------------------\n";
    };

    run_scenario("Database Scan (Pollution Resistance)", [](Simulator &sim) {
        for (int i = 0; i < 10000000; i++) {
            sim.access(100000 + i, 0xBAD, 0, EXCLUSIVE);
            sim.access(i % 64, 0xF00D, 2, SHARED);
        }
    });

    run_scenario("Graph Hub (Coherence Protection)", [](Simulator &sim) {
        for (int epoch = 0; epoch < 100000; epoch++) {
            for (int i = 0; i < 800; i++)
                sim.access(10000 + i + (epoch * 100), 0xD0015E, 0, EXCLUSIVE);

            for (int k = 0; k < 400; k++)
                sim.access(k % 50, 0x50B, 4, MODIFIED);
        }
    });

    run_scenario("Phase Change (Veto Adaptation)", [](Simulator &sim) {
        for (int i = 0; i < 10000000; i++) {
            sim.access(i % 100, 0x50B, 4, MODIFIED);
            sim.access(10000 + i, 0xD0015E, 0, EXCLUSIVE);
        }

        for (int i = 0; i < 10000000; i++) {
            sim.access(20000 + i, 0x50B, 0, EXCLUSIVE);
        }
    });

    return 0;
}
