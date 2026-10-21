#ifndef LETTY_PTY_FDS_H
#define LETTY_PTY_FDS_H
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/resource.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
/* Linux 3.10 has getdents64. Use a stack buffer after fork, without allocating
   a libc directory stream, and close only descriptors which actually exist. */
static int lt_close_proc_fds(void) {
  int directory = open("/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (directory < 0) return 0;
  struct entry { uint64_t ino; int64_t offset; unsigned short length;
                 unsigned char type; char name[]; };
  union { uint64_t align; char bytes[4096]; } buffer;
  int ok = 1;
  for (;;) {
    long size = syscall(SYS_getdents64, directory, buffer.bytes, sizeof buffer.bytes);
    if (size < 0 && errno == EINTR) continue;
    if (size <= 0) { if (size < 0) ok = 0; break; }
    for (size_t at = 0; at < (size_t)size;) {
      struct entry *entry = (struct entry *)(buffer.bytes + at);
      if ((size_t)size - at < offsetof(struct entry, name) + 1 ||
          entry->length < offsetof(struct entry, name) + 1 || entry->length > (size_t)size - at) {
        ok = 0; break;
      }
      unsigned fd = 0; size_t n = 0, cap = entry->length - offsetof(struct entry, name);
      while (n < cap && entry->name[n] >= '0' && entry->name[n] <= '9') {
        unsigned digit = (unsigned)(entry->name[n++] - '0');
        if (fd > (INT_MAX - digit) / 10u) { n = cap; break; }
        fd = fd * 10u + digit;
      }
      if (n > 0 && n < cap && entry->name[n] == 0 && fd >= 3 && (int)fd != directory) close((int)fd);
      at += entry->length;
    }
    if (!ok) break;
  }
  close(directory);
  return ok;
}
#endif
static void lt_close_fd_limit(void) {
  /* The soft limit bounds normal allocations. In particular, an unlimited
     Darwin hard limit must not turn shell startup into billions of closes. */
  struct rlimit limit;
  rlim_t end = 65536;
  if (!getrlimit(RLIMIT_NOFILE, &limit) && limit.rlim_cur != RLIM_INFINITY) end = limit.rlim_cur;
  if (end > INT_MAX) end = INT_MAX;
  for (int fd = 3; (rlim_t)fd < end; ++fd) close(fd);
}
static void lt_close_extra_fds(void) {
#ifdef __linux__
  if (lt_close_proc_fds()) return;
#endif
  lt_close_fd_limit();
}
#endif
