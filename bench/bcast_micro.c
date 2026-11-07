/*
 * bcast_micro: a thread 0 whose first pthread_cond_broadcast is at the same
 * instruction in every run, for check QR of the counter's BROADCAST line and
 * -base0 broadcast (bench/policy_sanity/heldout2_design_2026-11-04.md, Note 5).
 *
 *   bcast_micro SERIAL            one thread: nothing in it depends on timing
 *   bcast_micro SERIAL create     a worker is created after the first broadcast
 *
 * main: SERIAL iterations of register-only work; lock; broadcast (nobody
 * waits); a store; unlock; 2 M iterations; [create the worker;] a second
 * broadcast; 2 M iterations; [join]. The worker works 1 M iterations,
 * broadcasts once, and works 1 M more.
 *
 * Without "create", the tracer's -start0 K and N and the counter's BROADCAST
 * position and thread-0 total can be compared exactly. With it, thread 0's
 * second broadcast and its create come after the first: neither may move
 * -base0's base, and the worker's broadcast gets its own BROADCAST line.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE 64

struct line { volatile uint64_t v; char pad[LINE - sizeof(uint64_t)]; } __attribute__((aligned(LINE)));

static struct line mark[2];
static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t c = PTHREAD_COND_INITIALIZER;

static uint64_t work(uint64_t acc, long n) /* register-only: no memory access */
{
  for (long i = 0; i < n; i++)
    acc = acc * 6364136223846793005ULL + 1442695040888963407ULL;
  return acc;
}

static void *worker(void *arg)
{
  (void)arg;
  uint64_t acc = work(3, 1000000);
  pthread_cond_broadcast(&c);
  mark[1].v = work(acc, 1000000);
  return NULL;
}

int main(int argc, char **argv)
{
  const long serial = argc > 1 ? atol(argv[1]) : 1000000;
  const int create = argc > 2 && strcmp(argv[2], "create") == 0;
  pthread_t t;
  uint64_t acc = work(7, serial);
  pthread_mutex_lock(&m);
  pthread_cond_broadcast(&c); /* thread 0's first broadcast: the base */
  mark[0].v = acc;
  pthread_mutex_unlock(&m);
  acc = work(acc, 2000000);
  if (create && pthread_create(&t, NULL, worker, NULL)) {
    perror("pthread_create");
    return 1;
  }
  pthread_cond_broadcast(&c); /* a second one: no new line, no new base */
  acc = work(acc, 2000000);
  mark[0].v ^= acc;
  if (create)
    pthread_join(t, NULL);
  printf("bcast_micro serial %ld%s\n", serial, create ? " create" : "");
  return 0;
}
