/*
 * splash_barrier_micro: SPLASH-3's own synchronisation, verbatim in shape, to
 * reproduce the 2026-10-19 SYNC DEADLOCK of the mutex-order replay on every
 * SPLASH-3 program (sync_mutex_design_2026-10-19.md). Thread 0 creates three
 * workers and works itself; each takes its id under a lock (LOCK(idlock);
 * id = Global->id++), then passes BARRIER(bar, 4) several times with unequal
 * work between them. BARRIER is SPLASH's pthread macro: a mutex, a condition
 * variable, a counter and a cycle flag, cancellation disabled around it, and
 * a while-loop around pthread_cond_wait.
 *
 *   splash_barrier_micro ROUNDS
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define NT 4

struct barrier {
  pthread_mutex_t mutex;
  pthread_cond_t cv;
  unsigned long counter;
  unsigned long cycle;
};

static struct barrier bar;
static pthread_mutex_t idlock = PTHREAD_MUTEX_INITIALIZER;
static int gid;
static long ROUNDS;
static volatile uint64_t sink[NT * 8];

static void BARRIER(struct barrier *b, unsigned long n)
{
  unsigned long Cycle;
  int Cancel, Temp;
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &Cancel);
  pthread_mutex_lock(&b->mutex);
  Cycle = b->cycle;
  if (++b->counter != n) {
    pthread_cleanup_push((void (*)(void *))pthread_mutex_unlock, (void *)&b->mutex);
    while (Cycle == b->cycle) {
      if (pthread_cond_wait(&b->cv, &b->mutex) != 0)
        break;
    }
    pthread_cleanup_pop(0);
  } else {
    b->cycle = !b->cycle;
    b->counter = 0;
    pthread_cond_broadcast(&b->cv);
  }
  pthread_mutex_unlock(&b->mutex);
  pthread_setcancelstate(Cancel, &Temp);
}

static uint64_t work(uint64_t acc, long n)
{
  for (long i = 0; i < n; i++)
    acc = acc * 6364136223846793005ULL + 1442695040888963407ULL;
  return acc;
}

static void *worker(void *arg)
{
  (void)arg;
  int id;
  pthread_mutex_lock(&idlock);
  id = gid++;
  pthread_mutex_unlock(&idlock);
  uint64_t acc = (uint64_t)id + 1;
  for (long r = 0; r < ROUNDS; r++) {
    acc = work(acc, 20000 + 7000 * ((id + r) % NT));   /* unequal work */
    BARRIER(&bar, NT);
  }
  acc = work(acc, 2000000);                              /* a tail */
  sink[id * 8] = acc;
  return NULL;
}

int main(int argc, char **argv)
{
  ROUNDS = argc > 1 ? atol(argv[1]) : 20;
  pthread_mutex_init(&bar.mutex, NULL);
  pthread_cond_init(&bar.cv, NULL);
  bar.counter = 0;
  bar.cycle = 0;
  pthread_t th[NT];
  for (int t = 1; t < NT; t++)
    pthread_create(&th[t], NULL, worker, NULL);
  worker(NULL);
  for (int t = 1; t < NT; t++)
    pthread_join(th[t], NULL);
  uint64_t s = 0;
  for (int t = 0; t < NT; t++)
    s += sink[t * 8];
  printf("done %llu\n", (unsigned long long)s);
  return 0;
}
