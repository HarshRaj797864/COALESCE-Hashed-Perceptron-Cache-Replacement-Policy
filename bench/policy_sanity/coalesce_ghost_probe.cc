// Regression test for COALESCE's ghost-tag rescue, against the REAL compiled
// BloomFilter and CompactGhostEntry -- not a replica.
//
// Semantics as of 2026-09-23 (bench/policy_sanity/coalesce_ghost_defect_2026-09-23.md,
// coalesce_preaudit_2026-09-23.md):
//   * the ghost is keyed on the LINE ADDRESS alone -- the rescue means "this line
//     came back after we threw it out", whichever PC brings it back
//   * the evicted line's ALLOCATING PC is stored in the entry and returned by
//     lookup(), and the rescue trains that PC
//   * callers pass the true tag, (line_addr >> set_bits): the set index is
//     identical for every line a per-set structure holds, so leaving it in the
//     tag erases the partial tag
//
// WHY THE TESTS ARE SHAPED THIS WAY. Once the Bloom filter mixes the full tag, a
// filter holding a single entry rejects a different line on the Bloom check
// alone, so an end-to-end "different line" test can no longer see the partial
// tag -- a caller reverted to passing the full line address would still pass it.
// The partial tag is therefore tested DIRECTLY on CompactGhostEntry::matches(),
// and a filter is also tested LOADED to its reset threshold, where Bloom false
// positives occur and the entry match is what rejects them.
//
// -DCALLER_PASSES_LINE_ADDR reproduces the pre-fix caller convention against
// the current object. That build MUST fail (test 3): a test that passes on the
// defective convention proves nothing about the fixed one.
//
// Build from simulator/ after `make`:
//   g++ @global.options @absolute.options
//       ../bench/policy_sanity/coalesce_ghost_probe.cc
//       .csconfig/replacement/coalesce/coalesce.o
//       -L vcpkg_installed/x64-linux/lib -lfmt -o /tmp/ghost_probe
#include "../../simulator/replacement/coalesce/coalesce.h"
#include <cstdio>
#include <random>

#ifdef CALLER_PASSES_LINE_ADDR
static uint64_t caller_tag(uint64_t line_addr, int) { return line_addr; }          // pre-fix
#else
static uint64_t caller_tag(uint64_t line_addr, int set_bits) { return line_addr >> set_bits; }
#endif

static int fails = 0;
static void check(const char* what, bool ok, const char* detail = "") {
    std::printf("   %-58s %s%s\n", what, ok ? "ok" : "FAIL", detail);
    if (!ok) ++fails;
}

int main() {
    std::mt19937_64 rng(1);
    const int SB[] = {11, 13, 14, 15};

    std::printf("== 1. controls, 2048 sets ==\n");
    {
        const int sb = 11; const uint64_t set = 77, pcX = 0x401a2c, pcY = 0x402f18;
        const uint64_t A = (12345ULL << sb) | set, B = (67890ULL << sb) | set;
        BloomFilter f; uint64_t apc; int sh; MESI_State st;
        f.insert(caller_tag(A, sb), pcX, 2, MODIFIED);
        bool hit = f.lookup(caller_tag(A, sb), apc, sh, st);
        check("same line comes back -> rescue", hit);
        check("rescue returns the STORED allocating PC", hit && apc == (pcX & 0xFFF));
        check("stored sharers and state round-trip", hit && sh == 2 && st == MODIFIED);
        check("different line, same set -> no rescue", !f.lookup(caller_tag(B, sb), apc, sh, st));
        f.insert(caller_tag(A, sb), pcY, 1, EXCLUSIVE);   // re-evicted, new allocator
        hit = f.lookup(caller_tag(A, sb), apc, sh, st);
        check("re-eviction replaces the stored PC with the new one", hit && apc == (pcY & 0xFFF));
    }

    std::printf("\n== 2. end-to-end, single-entry filter (20000 trials per geometry) ==\n");
    for (int sb : SB) {
        long fr = 0, tr = 0, pcok = 0; const long N = 20000;
        for (long t = 0; t < N; ++t) {
            uint64_t set = rng() & ((1ULL << sb) - 1), pc = rng() & 0xffffffffffffULL;
            uint64_t ahi = rng() & 0xfffff, bhi = rng() & 0xfffff; if (bhi == ahi) bhi ^= 1;
            uint64_t A = (ahi << sb) | set, B = (bhi << sb) | set;
            BloomFilter f; uint64_t apc; int sh; MESI_State st;
            f.insert(caller_tag(A, sb), pc, 1, EXCLUSIVE);
            fr += f.lookup(caller_tag(B, sb), apc, sh, st);
            if (f.lookup(caller_tag(A, sb), apc, sh, st)) { ++tr; pcok += (apc == (pc & 0xFFF)); }
        }
        char d[96]; std::snprintf(d, sizeof d, "   false %.3f%%  true %.1f%%  pc %.1f%%", 100.0*fr/N, 100.0*tr/N, 100.0*pcok/N);
        char w[64]; std::snprintf(w, sizeof w, "%d sets", 1 << sb);
        check(w, fr == 0 && tr == N && pcok == N, d);
    }

    std::printf("\n== 3. the partial tag itself: two different lines, one set (200000 pairs) ==\n");
    std::printf("   (this is where the caller's tag convention shows; see header)\n");
    for (int sb : SB) {
        long coll = 0; const long N = 200000;
        for (long t = 0; t < N; ++t) {
            uint64_t set = rng() & ((1ULL << sb) - 1);
            uint64_t ahi = rng() & 0xffffff, bhi = rng() & 0xffffff; if (bhi == ahi) bhi ^= 1;
            CompactGhostEntry e(caller_tag((ahi << sb) | set, sb), 0x401000, 1, EXCLUSIVE);
            coll += e.matches(caller_tag((bhi << sb) | set, sb));
        }
        // 14 partial-tag bits above the set index: 1 in 16384 is the design floor.
        double r = 100.0 * coll / N;
        char d[64]; std::snprintf(d, sizeof d, "   collisions %.4f%%  (floor 0.0061%%)", r);
        char w[64]; std::snprintf(w, sizeof w, "%d sets", 1 << sb);
        check(w, r < 0.05, d);
    }

    std::printf("\n== 4. loaded filter: 150 lines inserted, 20000 absent lines queried ==\n");
    {
        const int sb = 11; const uint64_t set = 5; long fr = 0; const long N = 20000;
        BloomFilter f; uint64_t apc; int sh; MESI_State st;
        for (int i = 0; i < 150; ++i) f.insert(caller_tag(((uint64_t)(1000 + i) << sb) | set, sb), 0x400000 + i, 1, EXCLUSIVE);
        for (long t = 0; t < N; ++t) fr += f.lookup(caller_tag(((5000000 + (uint64_t)t) << sb) | set, sb), apc, sh, st);
        char d[64]; std::snprintf(d, sizeof d, "   false rescues %.3f%%", 100.0 * fr / N);
        // Threshold 0.05%, not looser. Loaded to the reset threshold the Bloom
        // filter's false-positive rate is ~4.5% (occupancy ~36%, cubed), and the
        // entry's partial tag must reject those. Correct callers: 4.5% x 1/16384,
        // effectively zero. The pre-fix caller at 2048 sets: 4.5% x 12.5% ~ 0.56%,
        // measured at 0.465%. A 0.5% cut -- the first version of this line --
        // passed the defect.
        check("absent lines rejected under load", 100.0 * fr / N < 0.05, d);
    }

    std::printf("\n%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
