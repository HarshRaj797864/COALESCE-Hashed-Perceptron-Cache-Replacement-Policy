#!/usr/bin/env python3
"""Tiny 4-core traces whose coherence counts can be worked out by hand.

    coherence_exact_traces.py CASE OUTDIR     -> OUTDIR/CASE{0..3}.champsimtrace
                                                 prints the instructions to SIMULATE

Used by check_coherence_exact.sh, which holds the expected counts. Every
instruction is a dependency-free ALU instruction except the few memory
accesses below, which are spaced so far apart that their order at the LLC is
certain.

FOUR TRAPS, all hit while writing these (2026-10-09/11):
  * A core that misses to DRAM every round falls behind the others a little
    each round, and after ~26 rounds another core overtakes it. So the roles
    ROTATE across the cores from round to round, and no core drifts.
  * The caches are indexed by PHYSICAL address, and each 4 KB page is mapped to
    an arbitrary physical page. Lines 64 KB apart collide in the L1D (its set
    bits lie inside the page offset) but not in the L2C. To push a line out of
    the L2C, sweep a region several times its size.
  * ChampSim reads ahead of what it executes, and a core that finishes early
    keeps running until the others finish. A trace exactly as long as the
    simulation therefore reaches its end and WRAPS -- silently replaying its
    start (S3, CLAUDE.md). So every trace carries a quiet tail beyond the
    simulated length, the cores do equal work, and the check refuses any wrap.
  * Physical pages are handed out in order of first touch. Two groups of cores
    first-touching their regions AT THE SAME TIME get interleaved page numbers,
    so a group's region no longer covers every L2C set evenly, and a sweep can
    miss the set it was meant to flush (2 of 12 rounds, 2026-10-11). So the
    second pair's whole schedule is shifted: it first touches its region after
    the first pair has finished.

Cases (R rounds, each on a fresh line X_j):
  order      p0 LOAD, p1 RMW, p2 LOAD, p3 RMW, by cores (p + j) % 4
  pingpong   A: RMW, B: RMW, A: RMW, B: RMW on X_j     (A, B = j%2, 1-j%2)
  wb_control A: RMW X_j ......................... B: RMW X_j
  wb_evict   A: RMW X_j, then A reads a 2 MB region; B: RMW X_j
             (the sweep is 4x the L2C: A's dirty X_j is written back to the LLC)
  forward    one core: RMW X_j, and RMW X_j again 4 instructions later
             (the first's store is still in the store queue, so the second
             load is forwarded and never reaches the cache); cores take turns
  upgrade    A: LOAD, B: LOAD, A: RMW, B: LOAD, A: RMW on X_j  (A, B = j%4, (j+1)%4)
             (both of A's RMWs HIT its own copy while B is listed: the upgrade
             of B3 v4, private_coherence 2)
  upgrade_l2 A: LOAD X_j, B: LOAD X_j, A: LOAD ten other lines of X_j's L1D
             set (same page offset, other pages), A: RMW X_j
             (the ten push X_j out of A's 8-way L1D set but not out of its
             L2C, so the RMW's RFO hits in the L2C: the upgrade is seen there)
  storm      all four cores: RMW X_j at the same instruction
             (the requests reach the LLC together and their fills cross: the
             stale-fill rule. Cycle-level order decides the counts, so the
             check asserts invariants and bounds only)
  silent_own (2026-10-27, amendment 2 of b3_g5rule_design_2026-10-19.md), R = 2,
             two pairs: A RMW X_j; A LOADs ten lines of X_j's L1D set (the
             dirty X_j goes to its L2C); A LOADs X_j (back into the L1D); A
             sweeps 2 MB with a LOAD of X_j every 32 lines (X_j stays in the
             L1D, the L2C writes it back to the LLC); A RMW X_j (an L1D hit).
             Round 0 only: then B RMW X_j. Roles swap in round 1.
  The wb cases run TWO independent pairs, cores (0,1) and (2,3), on separate
  lines and regions, so all four cores do the same work; pair (2,3) runs the
  same schedule SHIFT instructions later.
"""
import struct
import sys

REC = struct.Struct('<QBB2B4B2Q4Q')   # ip, is_branch, taken, 2 dst regs, 4 src regs, 2 dst mem, 4 src mem
X = 0x50000000                        # the contended lines, one per round
W = 0x60000000                        # the sweep region
H = 0x70000000                        # upgrade_l2's helper pages
PAIR = 0x08000000                     # the second pair's lines and region lie this far above
SWEEP = 32768                         # lines: 2 MB
SHIFT = 4_000_000                     # instructions the second pair starts later


def accesses(case):
    """-> (instructions to simulate, records to write, {core: {index: (address, is_rmw)}})"""
    acc = {c: {} for c in range(4)}
    if case == 'order':
        R, G, lead = 50, 20000, 20000
        for j in range(R):
            for p in range(4):
                acc[(p + j) % 4][lead + (4 * j + p) * G] = (X + j * 64, p in (1, 3))
        n = lead + R * 4 * G + 20000
        return n, n + 300_000, acc
    if case == 'forward':
        R, G, lead = 50, 20000, 20000
        for j in range(R):
            acc[j % 4][lead + j * G] = (X + j * 64, True)
            acc[j % 4][lead + j * G + 4] = (X + j * 64, True)
        n = lead + R * G + 20000
        return n, n + 300_000, acc
    if case == 'upgrade':
        R, G, lead = 50, 20000, 20000
        for j in range(R):
            a, b = j % 4, (j + 1) % 4
            for p, (c, rmw) in enumerate(((a, False), (b, False), (a, True), (b, False), (a, True))):
                acc[c][lead + (5 * j + p) * G] = (X + j * 64, rmw)
        n = lead + R * 5 * G + 20000
        return n, n + 300_000, acc
    if case == 'upgrade_l2':
        R, G, lead = 50, 20000, 20000              # R <= 64: every X_j in one page, its own L1D set
        for j in range(R):
            a, b = j % 4, (j + 1) % 4
            base = lead + 4 * j * G
            acc[a][base] = (X + j * 64, False)
            acc[b][base + G] = (X + j * 64, False)
            for k in range(10):
                acc[a][base + 2 * G + 50 * k] = (H + ((k + 1) << 12) + j * 64, False)
            acc[a][base + 3 * G] = (X + j * 64, True)
        n = lead + R * 4 * G + 20000
        return n, n + 300_000, acc
    if case == 'storm':
        R, G, lead = 50, 20000, 20000
        for j in range(R):
            for c in range(4):
                acc[c][lead + j * G] = (X + j * 64, True)
        n = lead + R * G + 20000
        return n, n + 300_000, acc
    if case == 'pingpong':
        R, G, lead = 50, 20000, 20000
        for j in range(R):
            a, b = j % 2, 1 - j % 2
            for p in range(4):
                acc[a if p % 2 == 0 else b][lead + (4 * j + p) * G] = (X + j * 64, True)
        n = lead + R * 4 * G + 20000
        return n, n + 300_000, acc
    if case in ('wb_control', 'wb_evict'):
        R, rnd, b_at = 4, 4_200_000, 4_000_000
        pro = SWEEP + 100_000
        for pair in (0, 1):
            off, c0, t0 = pair * PAIR, 2 * pair, pair * SHIFT
            for c in (c0, c0 + 1):                     # prologue: both read the region once
                for i in range(SWEEP):
                    acc[c][t0 + i] = (W + off + i * 64, False)
            for j in range(R):
                a, b = c0 + j % 2, c0 + 1 - j % 2
                base = t0 + pro + j * rnd
                acc[a][base] = (X + off + j * 64, True)
                if case == 'wb_evict':
                    for i in range(SWEEP):
                        acc[a][base + 1 + i] = (W + off + i * 64, False)
                acc[b][base + b_at] = (X + off + j * 64, True)
        n = SHIFT + pro + R * rnd + 20000
        return n, n + 4_000_000, acc
    if case == 'silent_own':
        # The gem5-rule view's silent re-listing: A's writeback dropped it from
        # every view while its L1D kept X_j; A's store then re-lists it in the
        # gem5-rule view only. B's RMW (round 0) finds A there and nowhere else
        # but in presence; round 1's X_j is left re-listed at the end.
        R, rnd, b_at = 2, 8_400_000, 8_000_000
        pro = SWEEP + 100_000
        for pair in (0, 1):
            off, c0, t0 = pair * PAIR, 2 * pair, pair * SHIFT
            for c in (c0, c0 + 1):                     # prologue: both read the region once (first touch)
                for i in range(SWEEP):
                    acc[c][t0 + i] = (W + off + i * 64, False)
            for j in range(R):
                a, b = c0 + j % 2, c0 + 1 - j % 2
                base = t0 + pro + j * rnd
                x = X + off + j * 64
                acc[a][base] = (x, True)                                     # 1. X_j dirty in A's L1D
                for k in range(10):                                          # 2. ten lines of its L1D set: X_j to the L2C, dirty
                    acc[a][base + 20000 + 50 * k] = (H + off + ((k + 1) << 12) + j * 64, False)
                acc[a][base + 40000] = (x, False)                            # 3. back into the L1D from the L2C
                p = base + 60000                                             # 4. the sweep, X_j kept in the L1D
                for i in range(SWEEP):
                    acc[a][p] = (W + off + i * 64, False); p += 1
                    if i % 32 == 31:
                        acc[a][p] = (x, False); p += 1
                acc[a][p + 100_000] = (x, True)                              # 5. an L1D hit
                if j == 0:
                    acc[b][base + b_at] = (x, True)                          # 6. B, round 0 only
        n = SHIFT + pro + R * rnd + 20000
        return n, n + 4_000_000, acc
    if case in ('offchip', 'offchip_control'):
        # 2026-10-17, for the bounded protocol view (b3_bounded_design_2026-10-17.md).
        # offchip: A LOADs X_j, then reads a 4 MB region (twice the LLC, read
        # cyclically, so every LLC set takes about 32 new lines under LRU and
        # X_j leaves A's L1D, A's L2C and the LLC): X_j is held nowhere on
        # chip. Then B RMWs X_j. offchip_control: the same without the sweep,
        # so A still holds X_j. B's RMW comes 16 M instructions after A's read,
        # well after the sweep has finished (about 2 M cycles of misses).
        R, rnd, b_at, shift, sweep = 2, 17_000_000, 16_000_000, 8_000_000, 65536
        pro = sweep + 100_000
        for pair in (0, 1):
            off, c0, t0 = pair * PAIR, 2 * pair, pair * shift
            for c in (c0, c0 + 1):                     # prologue: both read the region once (first touch)
                for i in range(sweep):
                    acc[c][t0 + i] = (W + off + i * 64, False)
            for j in range(R):
                a, b = c0 + j % 2, c0 + 1 - j % 2
                base = t0 + pro + j * rnd
                acc[a][base] = (X + off + j * 64, False)
                if case == 'offchip':
                    for i in range(sweep):
                        acc[a][base + 1 + i] = (W + off + i * 64, False)
                acc[b][base + b_at] = (X + off + j * 64, True)
        n = shift + pro + R * rnd + 20000
        return n, n + 4_000_000, acc
    if case in ('sync_pingpong', 'sync_pingpong_nosync', 'sync_barrier', 'sync_barrier_nosync', 'sync_storepp', 'sync_storepp_nosync'):
        # 2026-10-18, synchronised replay (sync_replay_design_2026-10-18.md).
        # The order of the accesses is set ONLY by sync records: without them
        # (the _nosync controls, the same traces with the records left out)
        # the cores race and the counts change.
        return sync_accesses(case)
    if case in ('mx_handover', 'mx_excl', 'mx_cond'):
        # 2026-10-19, mutex order by simulated timing (sync_mutex_design_2026-10-19.md).
        return mx_accesses(case)
    sys.exit(f"unknown case {case!r}")


SYNC_MAGIC = 0x53594E4353594E43
SYNC = {}   # filled by sync_accesses / mx_accesses: {core: {index: (release_id, wait_id, kind[, mutex, ordered])}}
MUTEX = 0x7F000040                    # the mutex's address: only a name, never accessed


def sync_accesses(case):
    """sync_pingpong, R = 50: A RMW, B RMW, A RMW, B RMW on X_j, each turn
    waiting for the turn before it (an acquire on the previous turn's
    release), with no spacing at all; A, B = cores j%2, 1-j%2.
    sync_barrier, R = 50: core W = j%4 does 30,000 instructions of work and
    LOADs X_j; then all four meet at a barrier (each arrives with a release,
    and leaves waiting for W's arrival, the last in the native run); then core
    (j+1)%4 RMWs X_j right away. With the barrier its store finds W."""
    acc = {c: {} for c in range(4)}
    SYNC.clear()
    for c in range(4):
        SYNC[c] = {}
    seq = [0]
    def rel_id(core):
        seq[0] += 1
        return (seq[0] << 8) | core
    keep = not case.endswith('_nosync')
    R, lead = 50, 20000
    pos = {c: lead for c in range(4)}               # next free record index per core
    if case.startswith('sync_pingpong') or case.startswith('sync_storepp'):
        # sync_storepp: the same turns with plain STOREs. A store retires
        # before it reaches the cache, so this holds only if a release waits
        # for its core's stores to be performed (a fence).
        kind = 'st' if case.startswith('sync_storepp') else True
        for j in range(R):
            a, b = j % 2, 1 - j % 2
            last = None
            for turn in range(4):
                c = a if turn % 2 == 0 else b
                i = pos[c]
                if last is not None and keep:
                    SYNC[c][i] = (0, last, 2); i += 1
                acc[c][i] = (X + j * 64, kind); i += 1
                rid = rel_id(c)
                if keep:
                    SYNC[c][i] = (rid, 0, 1); i += 1
                last = rid
                pos[c] = i + 2
        n = max(pos.values()) + 20000
    else:
        for j in range(R):
            w, nx = j % 4, (j + 1) % 4
            start = max(pos.values())
            for c in range(4):
                pos[c] = start
            pos[w] += 30000                              # W's work: 30,000 ALU instructions
            acc[w][pos[w]] = (X + j * 64, False); pos[w] += 1
            arrivals = {}
            for c in sorted(range(4), key=lambda c: c == w):   # W arrives last
                arrivals[c] = rel_id(c)
            for c in range(4):
                if keep:
                    SYNC[c][pos[c]] = (arrivals[c], 0, 1); pos[c] += 1
                    SYNC[c][pos[c]] = (0, arrivals[w], 2); pos[c] += 1
            acc[nx][pos[nx]] = (X + j * 64, True); pos[nx] += 1
            for c in range(4):
                pos[c] += 100
        n = max(pos.values()) + 20000
    return n, n + 300_000, acc


def mx_accesses(case):
    """Mutex records as the tracer writes them (champsim_tracer.cpp, -sync 1):
    every acquire of the mutex carries its address and its recorded wait (the
    mutex's previous release in the native run, or 0); ordered = that release
    was a condition wait's. A release is numbered when its call is entered.

    mx_handover, R = 50: cores A = 0 and B = 1 take turns on the mutex, A, B,
      A, B, each turn an RMW of X_j; the native order alternates. B first runs
      1,000,000 instructions alone. Timing order: A takes all its turns, then B
      (one handover a round). Recorded order: the alternation (as
      sync_pingpong).
    mx_excl, R = 50: four cores, 50 critical sections each: RMW Y, 3,000
      instructions, RMW Y; 10 instructions between sections. The native order
      rotates 0, 1, 2, 3. Under exclusion every section after the first finds Y
      at the previous holder, another core.
    mx_cond, R = 50: a barrier made of the mutex and a condition variable.
      Per round, waiters (j+1)%4, (j+2)%4, (j+3)%4 work 30,000 instructions,
      LOAD Z_j, lock, and wait on the condition (in that native order); the
      last, j%4, arrives after 10 instructions, locks (an ORDERED acquire: its
      predecessor was a condition wait), broadcasts, unlocks and RMWs Z_j. If it
      waits for the others, its RFO finds three readers. The readers' misses
      can merge at the LLC, and the LLC's own mask (v1) records only the
      miss's owner: v1 is not asserted (2026-10-19, the event log: two LOADs
      130 cycles apart, the second merged; v1 read 101 and, staggered, 100 of
      150, while presence and the protocol view listed all three)."""
    acc = {c: {} for c in range(4)}
    SYNC.clear()
    for c in range(4):
        SYNC[c] = {}
    seq = [0]
    def rel_id(core):
        seq[0] += 1
        return (seq[0] << 8) | core
    R, lead = 50, 20000
    pos = {c: lead for c in range(4)}
    if case == 'mx_handover':
        A, B = 0, 1
        pos[B] += 1_000_000
        last = 0
        for j in range(R):
            for turn in range(4):
                c = A if turn % 2 == 0 else B
                i = pos[c]
                SYNC[c][i] = (0, last, 2, MUTEX, 0); i += 1
                acc[c][i] = (X + j * 64, True); i += 1
                last = rel_id(c)
                SYNC[c][i] = (last, 0, 1, MUTEX, 0); i += 1
                pos[c] = i + 2
    elif case == 'mx_excl':
        Y, last = X, 0
        for k in range(4 * R):
            c = k % 4
            i = pos[c]
            SYNC[c][i] = (0, last, 2, MUTEX, 0)
            acc[c][i + 1] = (Y, True)
            acc[c][i + 2 + 3000] = (Y, True)
            last = rel_id(c)
            SYNC[c][i + 3 + 3000] = (last, 0, 1, MUTEX, 0)
            pos[c] = i + 4 + 3000 + 10
    else:   # mx_cond
        last, last_cond = 0, False                   # the mutex's last release, and whether a condition wait made it
        for j in range(R):
            L, waiters = j % 4, [(j + 1) % 4, (j + 2) % 4, (j + 3) % 4]
            start = max(pos.values())
            for c in range(4):
                pos[c] = start
            cond_rel = {}
            for w in waiters:                        # arrivals, in native order
                pos[w] += 30000                      # the work
                acc[w][pos[w]] = (X + j * 64, False); pos[w] += 1
                SYNC[w][pos[w]] = (0, last, 2, MUTEX, 1 if (last and last_cond) else 0); pos[w] += 1
                cond_rel[w] = rel_id(w)              # pthread_cond_wait: the mutex released on entry
                last, last_cond = cond_rel[w], True
            pos[L] += 10
            SYNC[L][pos[L]] = (0, last, 2, MUTEX, 1 if (last and last_cond) else 0); pos[L] += 1
            bcast = rel_id(L)                        # pthread_cond_broadcast
            SYNC[L][pos[L]] = (bcast, 0, 1); pos[L] += 1
            unlock = rel_id(L)                       # pthread_mutex_unlock
            last, last_cond = unlock, False
            SYNC[L][pos[L]] = (unlock, 0, 1, MUTEX, 0); pos[L] += 1
            acc[L][pos[L]] = (X + j * 64, True); pos[L] += 1
            for w in waiters:                        # departures, in native order: the condition wait returns
                SYNC[w][pos[w]] = (cond_rel[w], 0, 1, MUTEX, 0); pos[w] += 1     # its release, written on exit
                SYNC[w][pos[w]] = (0, bcast, 2); pos[w] += 1                     # the broadcast that woke it
                w2 = 0 if last == cond_rel[w] else last
                SYNC[w][pos[w]] = (0, w2, 2, MUTEX, 1 if (w2 and last_cond) else 0); pos[w] += 1   # re-acquire
                u = rel_id(w)                        # pthread_mutex_unlock
                last, last_cond = u, False
                SYNC[w][pos[w]] = (u, 0, 1, MUTEX, 0); pos[w] += 1
            for c in range(4):
                pos[c] += 100
    n = max(pos.values()) + 20000
    # mx_handover in recorded order: A waits through B's 1 M alone, then needs
    # about 1 M more after B is done, and B keeps running meanwhile: its tail
    # must outlast that (a wrap, 2026-10-19).
    return n, n + (2_000_000 if case == 'mx_handover' else 300_000), acc


def main():
    case, out = sys.argv[1], sys.argv[2]
    n_sim, n, acc = accesses(case)
    # ALU record i has ip 0x400000 + 4 * (i % 64): 64 records repeat. Runs of
    # them are written from one big periodic buffer, in whole periods.
    period = b''.join(REC.pack(0x400000 + 4 * k, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) for k in range(64))
    big = period * 4096

    def alu_run(f, i0, i1):                           # records [i0, i1)
        head = min(i1 - i0, (-i0) % 64)
        f.write(period[(i0 % 64) * 64:(i0 % 64 + head) * 64])
        i0 += head
        while i1 - i0 >= 64:
            k = min((i1 - i0) // 64, 4096)
            f.write(big[:k * 64 * 64])
            i0 += k * 64
        f.write(period[:(i1 - i0) * 64])

    for c in range(4):
        with open(f'{out}/{case}{c}.champsimtrace', 'wb') as f:
            sy = SYNC.get(c, {})
            if any(SYNC.values()):
                # the base record: this thread's first release (or none: a seq past every release)
                rels = sorted(v[0] for v in sy.values() if v[0])
                base = rels[0] if rels else ((1 << 40) << 8) | c
                f.write(REC.pack(0x400000, 0, 0, 0, 0, 0, 0, 0, 0, base, SYNC_MAGIC, 0, 3, 0, 0))
            at = 0
            for i in sorted(set(acc[c]) | set(sy)):
                alu_run(f, at, i)
                if i in sy:
                    rid, wid, kind = sy[i][:3]
                    mtx, ordf = (sy[i][3], sy[i][4]) if len(sy[i]) > 3 else (0, 0)
                    f.write(REC.pack(0x400000 + 4 * (i % 64), 0, 0, 0, 0, 0, 0, 0, 0, rid, SYNC_MAGIC, wid, kind, mtx, ordf))
                else:
                    addr, rmw = acc[c][i]
                    if rmw == 'st':   # a plain store
                        f.write(REC.pack(0x400000 + 4 * (i % 64), 0, 0, 0, 0, 0, 0, 0, 0, addr, 0, 0, 0, 0, 0))
                    else:
                        f.write(REC.pack(0x400000 + 4 * (i % 64), 0, 0, 0, 0, 0, 0, 0, 0, addr if rmw else 0, 0, addr, 0, 0, 0))
                at = i + 1
            alu_run(f, at, n)
    print(n_sim)


if __name__ == '__main__':
    main()
