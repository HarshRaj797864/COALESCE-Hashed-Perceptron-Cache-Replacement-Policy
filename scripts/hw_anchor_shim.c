/* hw_anchor_shim: D (bench/policy_sanity/hw_direction_design_2026-11-18.md).
 *
 * LD_PRELOAD shim for `perf stat --delay=-1 --control=fifo:CTL,ACK`: perf starts
 * with its counters disabled; this shim enables them when the N-th
 * pthread_create of the process returns, the point where the program's workers
 * all exist (the traces were cut at thread 0's last pthread_create,
 * scripts/sync_anchor.py). Counting then runs to the end of the program.
 *
 *   HW_CTL_FIFO=ctl.fifo HW_ACK_FIFO=ack.fifo HW_ANCHOR_N=3 \
 *     LD_PRELOAD=./hw_anchor_shim.so perf stat --delay=-1 --control=fifo:ctl.fifo,ack.fifo -e ... -- prog args
 *
 * HW_ANCHOR_N = 0 enables at the first pthread_create's call instead (a program
 * whose workers are not created by pthread_create is not counted: the shim
 * never enables, and hw_run.sh rejects a run whose instructions read 0).
 * Writes one line to stderr when it enables: "HW_ANCHOR enabled after create N", and one at exit:
 * "HW_ANCHOR total creates K" (hw_score.py rejects a run whose K is not its N: the anchor must be the last create).
 *
 * Build: gcc -O2 -fPIC -shared -o hw_anchor_shim.so hw_anchor_shim.c -ldl -lpthread
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*create_fn)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);

static long creates;
static int enabled;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

static void enable(long after)
{
  const char *ctl = getenv("HW_CTL_FIFO"), *ack = getenv("HW_ACK_FIFO");
  if (!ctl)
    return;
  int fd = open(ctl, O_WRONLY);
  if (fd < 0) {
    fprintf(stderr, "HW_ANCHOR cannot open %s\n", ctl);
    return;
  }
  if (write(fd, "enable\n", 7) != 7)
    fprintf(stderr, "HW_ANCHOR write to %s failed\n", ctl);
  close(fd);
  if (ack) {                       /* wait for perf's ack, so nothing runs uncounted after the anchor */
    char buf[16];
    int fa = open(ack, O_RDONLY);
    if (fa >= 0) {
      if (read(fa, buf, sizeof buf) <= 0)
        fprintf(stderr, "HW_ANCHOR no ack on %s\n", ack);
      close(fa);
    }
  }
  fprintf(stderr, "HW_ANCHOR enabled after create %ld\n", after);
}

int pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*f)(void *), void *arg)
{
  static create_fn real;
  if (!real)
    real = (create_fn)dlsym(RTLD_NEXT, "pthread_create");
  const char *n_s = getenv("HW_ANCHOR_N");
  const long n = n_s ? atol(n_s) : -1;
  pthread_mutex_lock(&mu);
  const long k = ++creates;
  const int first_call = (n == 0 && k == 1 && !enabled);
  if (first_call)
    enabled = 1;
  pthread_mutex_unlock(&mu);
  if (first_call)
    enable(0);
  int rc = real(t, a, f, arg);
  if (n > 0 && k == n) {
    pthread_mutex_lock(&mu);
    const int go = !enabled;
    enabled = 1;
    pthread_mutex_unlock(&mu);
    if (go)
      enable(k);
  }
  return rc;
}

__attribute__((destructor)) static void at_exit_report(void)
{
  if (getenv("HW_ANCHOR_N"))
    fprintf(stderr, "HW_ANCHOR total creates %ld\n", creates);
}
