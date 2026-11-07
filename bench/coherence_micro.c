/* coherence_micro: sharing patterns whose coherence counts can be worked out
 * by hand, run as a real 4-thread program, so that gem5 and the traced
 * ChampSim are checked against the same known answer
 * (validation round, 2026-10-17; bench/policy_sanity/micro_design_2026-10-17.md).
 *
 *   coherence_micro CASE ROUNDS     (ROUNDS = 0 is the control: the same program without the pattern)
 *
 * Built for a SMALL cache hierarchy, set the same way in both simulators
 * (scripts/micro_all.sh): L1D 2 KB (4 sets x 8), L1I 32 KB, private L2 8 KB
 * (16 sets x 8), shared cache 256 KB (256 sets x 16). Small caches make a
 * line easy to push out, and make the timing below independent of where the
 * pages land in physical memory.
 *
 * Four threads; the main thread is thread 0 and works, as SPLASH programs do.
 * Every thread runs the same schedule of steps. In a step a few threads act
 * on the round's line X_j (a fresh line every round), then EVERY thread
 * waits. The wait chases dependent loads around a private 4 KB ring: 64 lines,
 * 16 to each L1D set (8 ways: every load misses the L1D) and 4 to each L2 set
 * (every load hits the private L2), wherever the pages land, since the L1D's
 * and the L2's set bits lie inside the page offset. So every thread's wait
 * runs at the same speed, and the threads stay in step: the order of the
 * accesses to X_j is set by the schedule. (A first version used a 256 KB ring
 * in the default hierarchy; its speed depended on the physical pages, threads
 * drifted 1.7x apart, and steps overtook each other -- 2026-10-17.)
 *
 * Bulk reads are symmetric where they can be, so no thread falls behind:
 *   FLUSH  every thread reads its own 16 KB (twice its private L2): each
 *          thread's private caches lose X_j; the shared cache, 256 KB, keeps it
 *   SWEEP  every thread reads its own 128 KB: 512 KB in all, twice the shared
 *          cache: X_j is then held nowhere
 *   in llc_out only B, C and D sweep: X_j leaves the shared cache while A's
 *          private copy can stay
 *
 * Roles rotate: in round j, A = j % 4, B = (j+1) % 4, C = (j+2) % 4,
 * D = (j+3) % 4. Hand counts per round are in micro_design_2026-10-17.md.
 *   pp_lock   A, B, A, B: locked increment of X_j (lock add)
 *   pp_store  A, B, A, B: store
 *   pp_rmw    A, B, A, B: plain read-modify-write (add [mem], 1)
 *   readers   A, B, C load; D stores
 *   upgrade   A, B load; A stores
 *   ctl       A loads; (nothing); B stores
 *   priv_E    A loads; FLUSH; B stores
 *   priv_S    A, C load; FLUSH; B stores
 *   llc_out   A loads; B, C, D sweep; B stores
 *   offchip   A loads; SWEEP; B stores
 *
 * Markers: right after the start barrier each thread stores to its own line
 * of start_mark[], right after its last step to end_mark[]; micro_trim.py cuts
 * the traces there. Built with -DM5OPS (the gem5 binary only), thread 0 resets
 * gem5's statistics at its start mark and dumps them at its end mark.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NT 4
#define LINE 64
#define WPL (LINE / sizeof(uint64_t))
#define RING_LINES 64        /* 4 KB */
#define FLUSH_LINES 256      /* 16 KB */
#define SWEEP_LINES 2048     /* 128 KB */
#define W_STEP 100000        /* ring loads after a step */
#define W_BULK 200000        /* after a step with bulk reads */
#define W_TAIL 400000        /* after the end mark: long, so no thread exits inside the simulated window */

#ifdef M5OPS
static inline void m5_reset_stats(void) { __asm__ volatile(".byte 0x0f, 0x04\n\t.word 0x40" : : "D"(0), "S"(0) : "memory"); }
static inline void m5_dump_stats(void) { __asm__ volatile(".byte 0x0f, 0x04\n\t.word 0x41" : : "D"(0), "S"(0) : "memory"); }
#else
static inline void m5_reset_stats(void) {}
static inline void m5_dump_stats(void) {}
#endif

enum op { NONE, LD, ST, RMW, LOCK, FLUSH, SWEEP };

struct line { volatile uint64_t v; char pad[LINE - sizeof(uint64_t)]; } __attribute__((aligned(LINE)));

static struct line start_mark[NT], end_mark[NT], sink[NT];
static struct line *X;
static uint64_t *ring[NT];
static volatile uint64_t *flushbuf[NT], *sweepbuf[NT];
static long ROUNDS;
static const char *CASE;
static pthread_barrier_t start;
#ifdef BARRIER_STEPS
/* Synchronised-replay test (sync_replay_design_2026-10-18.md, Q2): every step
 * ends at a real barrier instead of a timed wait, so the order holds however
 * unequal the work -- in the program, and in ChampSim only if the replay
 * honours the barrier. */
static pthread_barrier_t step_barrier;
#define STEP_WAIT(t, w) (pthread_barrier_wait(&step_barrier), (uint64_t)0)
#else
#define STEP_WAIT(t, w) chase((t), (w))
#endif

struct step { enum op op[4]; long wait; };

static int schedule(const char *c, struct step *s)
{
#define S(a, b, cc, d, w) (s[n].op[0] = a, s[n].op[1] = b, s[n].op[2] = cc, s[n].op[3] = d, s[n].wait = w, n++)
  int n = 0;
  if (!strcmp(c, "pp_lock")) { S(LOCK, NONE, NONE, NONE, W_STEP); S(NONE, LOCK, NONE, NONE, W_STEP); S(LOCK, NONE, NONE, NONE, W_STEP); S(NONE, LOCK, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "pp_store")) { S(ST, NONE, NONE, NONE, W_STEP); S(NONE, ST, NONE, NONE, W_STEP); S(ST, NONE, NONE, NONE, W_STEP); S(NONE, ST, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "pp_rmw")) { S(RMW, NONE, NONE, NONE, W_STEP); S(NONE, RMW, NONE, NONE, W_STEP); S(RMW, NONE, NONE, NONE, W_STEP); S(NONE, RMW, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "readers")) { S(LD, NONE, NONE, NONE, W_STEP); S(NONE, LD, NONE, NONE, W_STEP); S(NONE, NONE, LD, NONE, W_STEP); S(NONE, NONE, NONE, ST, W_STEP); }
  else if (!strcmp(c, "upgrade")) { S(LD, NONE, NONE, NONE, W_STEP); S(NONE, LD, NONE, NONE, W_STEP); S(ST, NONE, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "ctl")) { S(LD, NONE, NONE, NONE, W_STEP); S(NONE, NONE, NONE, NONE, W_BULK); S(NONE, ST, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "priv_E")) { S(LD, NONE, NONE, NONE, W_STEP); S(FLUSH, FLUSH, FLUSH, FLUSH, W_BULK); S(NONE, ST, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "priv_S")) { S(LD, NONE, NONE, NONE, W_STEP); S(NONE, NONE, LD, NONE, W_STEP); S(FLUSH, FLUSH, FLUSH, FLUSH, W_BULK); S(NONE, ST, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "llc_out")) { S(LD, NONE, NONE, NONE, W_STEP); S(NONE, SWEEP, SWEEP, SWEEP, W_BULK); S(NONE, ST, NONE, NONE, W_STEP); }
  else if (!strcmp(c, "offchip")) { S(LD, NONE, NONE, NONE, W_STEP); S(SWEEP, SWEEP, SWEEP, SWEEP, W_BULK); S(NONE, ST, NONE, NONE, W_STEP); }
  else return -1;
  return n;
#undef S
}

static uint64_t chase(int t, long n)
{
  uint64_t i = 0, *r = ring[t];
  for (long k = 0; k < n; k++)
    i = r[i * WPL];
  return i;
}

static uint64_t reads(volatile uint64_t *buf, long lines)
{
  uint64_t s = 0;
  for (long k = 0; k < lines; k++)
    s += buf[k * WPL];
  return s;
}

static void *worker(void *arg)
{
  const int t = (int)(intptr_t)arg;
  struct step st[8];
  const int ns = schedule(CASE, st);
  uint64_t acc = 0;
  ring[t] = aligned_alloc(4096, (size_t)RING_LINES * LINE);
  for (long k = 0; k < RING_LINES; k++)                 /* an LCG of full period 64: each load depends on the last */
    ring[t][k * WPL] = (uint64_t)((k * 29 + 1) % RING_LINES);
  flushbuf[t] = aligned_alloc(4096, (size_t)FLUSH_LINES * LINE);
  sweepbuf[t] = aligned_alloc(4096, (size_t)SWEEP_LINES * LINE);
  memset((void *)flushbuf[t], 1, (size_t)FLUSH_LINES * LINE);
  memset((void *)sweepbuf[t], 1, (size_t)SWEEP_LINES * LINE);
  pthread_barrier_wait(&start);

  start_mark[t].v = 1;
  if (t == 0)
    m5_reset_stats();
  acc += chase(t, W_STEP);                              /* warm the ring (the traces start cold) */
  for (long j = 0; j < ROUNDS; j++) {
    const int role = (int)((t - j % NT + NT) % NT);     /* 0 = A, 1 = B, 2 = C, 3 = D */
    volatile uint64_t *x = &X[j].v;
    for (int s = 0; s < ns; s++) {
      switch (st[s].op[role]) {
      case LD: acc += *x; break;
      case ST: *x = (uint64_t)j; break;
      case RMW: __asm__ volatile("addq $1, %0" : "+m"(*x)); break;
      case LOCK: __atomic_fetch_add(x, 1, __ATOMIC_SEQ_CST); break;
      case FLUSH: acc += reads(flushbuf[t], FLUSH_LINES); break;
      case SWEEP: acc += reads(sweepbuf[t], SWEEP_LINES); break;
      case NONE: break;
      }
      acc += STEP_WAIT(t, st[s].wait);
    }
  }
  end_mark[t].v = 1;
  if (t == 0)
    m5_dump_stats();
  acc += chase(t, W_TAIL);
  sink[t].v = acc;
  return NULL;
}

int main(int argc, char **argv)
{
  if (argc != 3) {
    fprintf(stderr, "usage: %s CASE ROUNDS\n", argv[0]);
    return 2;
  }
  CASE = argv[1];
  ROUNDS = atol(argv[2]);
  struct step tmp[8];
  if (schedule(CASE, tmp) < 0) {
    fprintf(stderr, "unknown case %s\n", CASE);
    return 2;
  }
  X = aligned_alloc(4096, 4096 * (size_t)(ROUNDS / 64 + 1));   /* never touched before its round */
  printf("start_mark %p end_mark %p X %p case %s rounds %ld\n", (void *)start_mark, (void *)end_mark, (void *)X, CASE, ROUNDS);
  fflush(stdout);
  pthread_barrier_init(&start, NULL, NT);
#ifdef BARRIER_STEPS
  pthread_barrier_init(&step_barrier, NULL, NT);
#endif
  pthread_t th[NT];
  for (int t = 1; t < NT; t++)
    pthread_create(&th[t], NULL, worker, (void *)(intptr_t)t);
  worker((void *)0);
  for (int t = 1; t < NT; t++)
    pthread_join(th[t], NULL);
  uint64_t s = 0;
  for (int t = 0; t < NT; t++)
    s += sink[t].v;
  printf("done %llu\n", (unsigned long long)s);
  return 0;
}
