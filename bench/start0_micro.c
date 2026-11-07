/*
 * start0_micro: the shape of facesim's start, for the tracer's -start0 broadcast
 * (bench/policy_sanity/heldout2_design_2026-11-04.md, Note 4, check QZ).
 *
 *   start0_micro SERIAL
 *
 * main creates three workers. Each takes the mutex, counts itself ready and
 * waits on the condition until go is set (TaskQ's waitForTasks). main runs a
 * serial phase (SERIAL iterations of register-only work), waits until all
 * three are waiting, then, as TaskQ's signalTasks does:
 *
 *     lock; go = 1; pthread_cond_broadcast; a store to its line; unlock
 *
 * That broadcast is main's FIRST pthread_cond_broadcast: with -start0
 * broadcast its trace starts there, inside the critical section (the lock
 * before it is not traced). Then every thread works, stores to its line, and
 * runs a register-only tail, so no trace ends early in a replay.
 */
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define NW 3          /* workers; main is the fourth thread */
#define LINE 64
#define W_WORK 100000 /* iterations of work after the broadcast */
#define W_TAIL 400000 /* iterations of the tail */

struct line { volatile uint64_t v; char pad[LINE - sizeof(uint64_t)]; } __attribute__((aligned(LINE)));

static struct line mark[NW + 1];
static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t avail = PTHREAD_COND_INITIALIZER;
static int ready, go;

static uint64_t work(uint64_t acc, long n) /* register-only: no memory access */
{
  for (long i = 0; i < n; i++)
    acc = acc * 6364136223846793005ULL + 1442695040888963407ULL;
  return acc;
}

static void finish(int id, uint64_t acc)
{
  acc = work(acc, W_WORK);
  mark[id].v = acc;
  acc = work(acc, W_TAIL);
  mark[id].v ^= acc;
}

static void *worker(void *arg)
{
  const int id = (int)(intptr_t)arg;
  pthread_mutex_lock(&m);
  ready++;
  while (!go)
    pthread_cond_wait(&avail, &m);
  pthread_mutex_unlock(&m);
  finish(id, (uint64_t)id);
  return NULL;
}

int main(int argc, char **argv)
{
  const long serial = argc > 1 ? atol(argv[1]) : 1000000;
  pthread_t t[NW];
  for (int i = 0; i < NW; i++)
    if (pthread_create(&t[i], NULL, worker, (void *)(intptr_t)(i + 1))) {
      perror("pthread_create");
      return 1;
    }
  uint64_t acc = work(7, serial); /* main's serial phase: not traced under -start0 */
  for (;;) {                      /* until every worker waits */
    pthread_mutex_lock(&m);
    const int r = ready;
    pthread_mutex_unlock(&m);
    if (r == NW)
      break;
    sched_yield();
  }
  pthread_mutex_lock(&m); /* signalTasks */
  go = 1;
  pthread_cond_broadcast(&avail);
  mark[0].v = acc;
  pthread_mutex_unlock(&m);
  finish(0, acc);
  for (int i = 0; i < NW; i++)
    pthread_join(t[i], NULL);
  printf("start0_micro serial %ld mark %p\n", serial, (void *)mark);
  return 0;
}
