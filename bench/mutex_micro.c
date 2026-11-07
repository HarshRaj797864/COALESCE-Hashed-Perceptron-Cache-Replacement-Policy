/*
 * mutex_micro: real pthread mutexes and condition variables, with coherence
 * counts known by hand under mutex order by simulated timing
 * (bench/policy_sanity/sync_mutex_design_2026-10-19.md, Q2b). Companion to
 * coherence_micro.c: the same conventions, so bench/micro_trim.py and
 * bench/micro_champsim.sh (MICRO_SRC=bench/mutex_micro.c) run it unchanged.
 *
 *   mutex_micro CASE ROUNDS
 *
 *   mx_lock     every thread takes the mutex ROUNDS times; inside: a locked
 *               add on X[0], ~3,000 instructions of register-only work, a
 *               locked add on X[0]. With mutual exclusion and a first-come
 *               queue (all four always waiting), every critical section after
 *               the first finds X[0] at the previous holder, another thread:
 *               level 2: 4 * ROUNDS - 1 ownership events on the X lines, no
 *               upgrade; level 0 (no invalidation): 3, the first-time holders.
 *   mx_condbar  ROUNDS barriers made of the mutex and a condition variable.
 *               In round j thread S = j % 4 sleeps 20 ms first, so it is LAST
 *               in the native run but, having almost no instructions, FIRST in
 *               a replay; the other three work ~3,000 instructions and LOAD
 *               X[j]. After the barrier S does a locked add on X[j]. If S's
 *               lock -- an ORDERED acquire, its native predecessor a condition
 *               wait -- holds it until the others arrive, the add finds three
 *               readers: one ownership event a round, at levels 0 and 2. Had S
 *               passed early: 0.
 *
 * Each thread stores to its line of start_mark after the start barrier and to
 * its line of end_mark at the end, then runs a long register-only tail, so no
 * thread exits inside the simulated window.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define NT 4
#define LINE 64
#define W_WORK 1000     /* iterations of work: about 3,000 instructions */
#define W_TAIL 400000   /* iterations after the end mark */

struct line { volatile uint64_t v; char pad[LINE - sizeof(uint64_t)]; } __attribute__((aligned(LINE)));

static struct line start_mark[NT], end_mark[NT], sink[NT];
static struct line *X;
static long ROUNDS;
static const char *CASE;
static pthread_barrier_t start;
static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int arrived;
static long gen;

static uint64_t work(uint64_t acc, long n) /* register-only: no memory access */
{
  for (long i = 0; i < n; i++)
    acc = acc * 6364136223846793005ULL + 1442695040888963407ULL;
  return acc;
}

static void cond_barrier(void)
{
  pthread_mutex_lock(&m);
  if (++arrived == NT) {
    arrived = 0;
    gen++;
    pthread_cond_broadcast(&cv);
  } else {
    const long g = gen;
    while (g == gen)
      pthread_cond_wait(&cv, &m);
  }
  pthread_mutex_unlock(&m);
}

static void *worker(void *arg)
{
  const int t = (int)(intptr_t)arg;
  uint64_t acc = (uint64_t)t + 1;
  pthread_barrier_wait(&start);
  start_mark[t].v = 1;
  if (!strcmp(CASE, "mx_lock")) {
    for (long j = 0; j < ROUNDS; j++) {
      pthread_mutex_lock(&m);
      __atomic_fetch_add(&X[0].v, 1, __ATOMIC_SEQ_CST);
      acc = work(acc, W_WORK);
      __atomic_fetch_add(&X[0].v, 1, __ATOMIC_SEQ_CST);
      pthread_mutex_unlock(&m);
    }
  } else {
    for (long j = 0; j < ROUNDS; j++) {
      if (t == (int)(j % NT)) {
        usleep(20000);
      } else {
        acc = work(acc, W_WORK);
        acc += X[j].v;
      }
      cond_barrier();
      if (t == (int)(j % NT))
        __atomic_fetch_add(&X[j].v, 1, __ATOMIC_SEQ_CST);
    }
  }
  end_mark[t].v = 1;
  acc = work(acc, W_TAIL);
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
  if (strcmp(CASE, "mx_lock") && strcmp(CASE, "mx_condbar")) {
    fprintf(stderr, "unknown case %s\n", CASE);
    return 2;
  }
  X = aligned_alloc(4096, 4096 * (size_t)(ROUNDS / 64 + 1)); /* never touched before its round */
  printf("start_mark %p end_mark %p X %p case %s rounds %ld\n", (void *)start_mark, (void *)end_mark, (void *)X, CASE, ROUNDS);
  fflush(stdout);
  pthread_barrier_init(&start, NULL, NT);
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
