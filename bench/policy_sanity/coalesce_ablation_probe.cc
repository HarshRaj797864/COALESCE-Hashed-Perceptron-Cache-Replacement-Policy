// Regression test: each COALESCE ablation must differ from the full policy in
// EXACTLY the feature it removes, and nothing else.
//
// Until 2026-09-23 they did not. Removing a feature also replaced it with extra
// PC bits -- coalesce_no_mesi's table0 hashed (pc ^ c0) ^ (pc >> 11), and
// coalesce_no_sharer's table1 hashed (pc ^ c1) ^ (pc >> 13), where the full
// policy hashes (pc ^ c0) ^ (state << 8) and (pc ^ c1) ^ (sharers << 4). So each
// ablation also got a DIFFERENT PC hash with less aliasing, and "the ablation
// beats the full policy" could not be attributed to the feature.
//
// A clean ablation is the full policy with the feature's term at zero:
//   no_mesi   table0 index == full get_hash0(pc, INVALID)   (INVALID == 0)
//   no_sharer table1 index == full get_hash1(pc, 0)
// and the table each ablation does NOT touch must match the full policy exactly.
//
// Links all three real policy objects. Build from simulator/ after `make`:
//   g++ @global.options @absolute.options
//       ../bench/policy_sanity/coalesce_ablation_probe.cc
//       .csconfig/replacement/coalesce/coalesce.o
//       .csconfig/replacement/coalesce_no_mesi/coalesce_no_mesi.o
//       .csconfig/replacement/coalesce_no_sharer/coalesce_no_sharer.o
//       -L vcpkg_installed/x64-linux/lib -lfmt -o /tmp/ablation_probe
#include "../../simulator/replacement/coalesce/coalesce.h"
#include "../../simulator/replacement/coalesce_no_mesi/coalesce_no_mesi.h"
#include "../../simulator/replacement/coalesce_no_sharer/coalesce_no_sharer.h"
#include <cstdio>
#include <random>

int main() {
    PerceptronBrain full; CNM_Brain nm; CNS_Brain ns;
    std::mt19937_64 rng(7);
    const MESI_State states[] = {INVALID, SHARED, EXCLUSIVE, MODIFIED};
    long t0_nm = 0, t1_nm = 0, t0_ns = 0, t1_ns = 0; const long N = 200000;
    for (long i = 0; i < N; ++i) {
        uint64_t pc = rng() & 0xffffffffffffULL;
        int sh = static_cast<int>(rng() % 17);
        MESI_State st = states[rng() % 4];
        // the table each ablation REMOVES a feature from: must equal feature = 0
        t0_nm += nm.get_hash0(pc)     != full.get_hash0(pc, INVALID);
        t1_ns += ns.get_hash1(pc)     != full.get_hash1(pc, 0);
        // the table each ablation does NOT touch: must be identical
        t1_nm += nm.get_hash1(pc, sh) != full.get_hash1(pc, sh);
        t0_ns += ns.get_hash0(pc, st) != full.get_hash0(pc, st);
    }
    int fails = 0;
    auto row = [&](const char* what, long bad) {
        std::printf("   %-58s %7ld / %ld differ%s\n", what, bad, N, bad ? "   <-- FAIL" : "");
        if (bad) ++fails;
    };
    std::printf("== each ablation vs the full policy, %ld random (pc, feature) pairs ==\n", N);
    row("no_mesi   table0  vs full get_hash0(pc, INVALID)", t0_nm);
    row("no_mesi   table1  vs full get_hash1(pc, sharers)   [untouched]", t1_nm);
    row("no_sharer table0  vs full get_hash0(pc, state)     [untouched]", t0_ns);
    row("no_sharer table1  vs full get_hash1(pc, 0)", t1_ns);

    // The ghost rescue trains the allocating PC it STORED, which is only its low
    // 12 bits (CompactGhostEntry::get_pc_sig). That is exact only if every
    // perceptron hash reads nothing above bit 11 of the PC -- otherwise the rescue
    // would train an entry the scoring path never consults. Checked for all six
    // hashes. The removed ablation hashes, which folded in pc >> 11 and pc >> 13,
    // would have failed this; the control below confirms the check can fail.
    std::printf("\n== every hash reads only the PC's low 12 bits (%ld random pcs) ==\n", N);
    long bad[6] = {0};
    for (long i = 0; i < N; ++i) {
        uint64_t pc = rng() & 0xffffffffffffULL, lo = pc & 0xFFF;
        int sh = static_cast<int>(rng() % 17);
        MESI_State st = states[rng() % 4];
        bad[0] += full.get_hash0(pc, st) != full.get_hash0(lo, st);
        bad[1] += full.get_hash1(pc, sh) != full.get_hash1(lo, sh);
        bad[2] += nm.get_hash0(pc)       != nm.get_hash0(lo);
        bad[3] += nm.get_hash1(pc, sh)   != nm.get_hash1(lo, sh);
        bad[4] += ns.get_hash0(pc, st)   != ns.get_hash0(lo, st);
        bad[5] += ns.get_hash1(pc)       != ns.get_hash1(lo);
    }
    const char* names[6] = {"coalesce  get_hash0", "coalesce  get_hash1", "no_mesi   get_hash0",
                            "no_mesi   get_hash1", "no_sharer get_hash0", "no_sharer get_hash1"};
    for (int k = 0; k < 6; ++k) row(names[k], bad[k]);
    long ctl = 0;
    for (long i = 0; i < N; ++i) {
        uint64_t pc = rng() & 0xffffffffffffULL;
        auto old_nm = [](uint64_t x) { return ((x ^ 0x9e3779b9ULL) ^ (x >> 11)) % 2048; };
        ctl += old_nm(pc) != old_nm(pc & 0xFFF);
    }
    std::printf("   %-58s %7ld / %ld differ   (must be non-zero: the check can fail)\n",
                "control: the removed no_mesi hash, (pc^c0)^(pc>>11)", ctl, N);
    if (ctl == 0) { std::printf("      <-- FAIL: the control did not trip, so the check has no teeth\n"); ++fails; }

    std::printf("\n%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
