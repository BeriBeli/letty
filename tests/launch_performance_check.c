#define _GNU_SOURCE
#include <assert.h>
#include <pwd.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
static unsigned lookups;
static char account_home[] = "/fixture/home";
static struct passwd account = { .pw_shell = "/bin/bash", .pw_dir = account_home, .pw_name = "fixture" };
static struct passwd *fixture_getpwuid(uid_t uid) { (void)uid; ++lookups; return &account; }
#define getpwuid fixture_getpwuid
#include "platform/launch_account.h"
#undef getpwuid
#include "platform/pty_fds.h"

static double micros(void) {
  struct timespec t; assert(!clock_gettime(CLOCK_MONOTONIC, &t));
  return (double)t.tv_sec * 1e6 + (double)t.tv_nsec / 1e3;
}
static double cleanup(int baseline, int high) {
  int result[2]; assert(!pipe(result));
  int low = open("/dev/null", O_RDONLY); assert(low >= 3);
  pid_t child = fork(); assert(child >= 0);
  if (!child) {
    if (dup2(result[1], STDOUT_FILENO) < 0) _exit(10);
    double begin = micros();
    if (baseline == 1) { for (int i = 3; i < 65536; ++i) close(i); }
    else if (baseline == 2) lt_close_fd_limit();
    else lt_close_extra_fds();
    double elapsed = micros() - begin;
    if (fcntl(low, F_GETFD) != -1 || errno != EBADF) _exit(11);
    if (baseline != 1 && high >= 0 && (fcntl(high, F_GETFD) != -1 || errno != EBADF)) _exit(12);
    for (int i = 0; i < 3; ++i) if (fcntl(i, F_GETFD) < 0) _exit(13);
    if (write(STDOUT_FILENO, &elapsed, sizeof elapsed) != sizeof elapsed) _exit(14);
    _exit(0);
  }
  close(result[1]); close(low);
  double elapsed = 0;
  assert(read(result[0], &elapsed, sizeof elapsed) == sizeof elapsed);
  close(result[0]);
  int status; assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  return elapsed;
}
int main(void) {
  const LtLaunchAccount *first = lt_launch_account();
  assert(first && !strcmp(first->home, "/fixture/home"));
  account_home[1] = 'X';
  for (int i = 0; i < 100; ++i) {
    const LtLaunchAccount *cached = lt_launch_account();
    assert(cached == first && !strcmp(cached->home, "/fixture/home"));
    assert(!strcmp(cached->shell, "/bin/bash") && !strcmp(cached->name, "fixture"));
  }
  assert(lookups == 1);
  puts("PASS 101 launches share one NSS query and own copies of borrowed account fields");
  int low = open("/dev/null", O_RDONLY); assert(low >= 3);
  int high = fcntl(low, F_DUPFD, 70000); close(low);
  double before = 0, after = 0;
  for (int i = 0; i < 9; ++i) { before += cleanup(1, high); after += cleanup(0, high); }
  (void)cleanup(2, high);
  puts("PASS descriptor-limit fallback also closes inherited descriptors and preserves stdio");
  if (high >= 0) { assert(fcntl(high, F_GETFD) >= 0); close(high); }
  printf("PASS child fd cleanup preserves stdio and parent fds; high_fd=%s\n", high >= 0 ? "checked" : "unavailable");
  printf("FD cleanup mean_us baseline=%.1f candidate=%.1f samples=9 (local syscall microbenchmark, not target X11 latency)\n", before / 9, after / 9);
}
