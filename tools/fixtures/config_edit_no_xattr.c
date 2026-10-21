/* Linked only into the isolated metadata regression executable. Exercise the
   production capture/copy code by replacing listxattr for one owned directory,
   including its atomic replacement inodes. No production runtime switch. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char fixture_directory[4096];
static int fixture_kind;
int lt_config_no_xattr_fixture(const char *directory, int kind) {
  struct stat st;
  if (!realpath(directory, fixture_directory) || stat(fixture_directory, &st)) return -1;
  if (!S_ISDIR(st.st_mode) || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700) {
    errno = EACCES; return -1;
  }
  fixture_kind = kind;
  return 0;
}
static int selected(int fd) {
  if (!fixture_kind) return 0;
  char path[4096];
#ifdef __APPLE__
  if (fcntl(fd, F_GETPATH, path)) return 0;
#else
  char link[64];
  snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
  ssize_t n = readlink(link, path, sizeof path - 1);
  if (n < 0) return 0;
  path[n] = 0;
#endif
  size_t len = strlen(fixture_directory);
  if (strncmp(path, fixture_directory, len) || path[len] != '/') return 0;
  if (fixture_kind == 7 && !strstr(path + len, ".theme-")) return 1;
  if (fixture_kind == 9) return strstr(path + len, ".theme-") ? 6 : 1;
  return fixture_kind;
}
#ifdef __APPLE__
static ssize_t fixture_list(int fd, char *buf, size_t cap, int options) {
#else
static ssize_t fixture_list(int fd, char *buf, size_t cap) {
#endif
  int kind = selected(fd);
  if (kind) {
    if (kind == 6) return 0; /* Supported empty differs from unsupported. */
    if (kind == 8) {
      static const char name[] = "user.letty-fixture";
      if (cap < sizeof name) { errno = ERANGE; return -1; }
      memcpy(buf, name, sizeof name);
      return sizeof name;
    }
    errno = kind == 1 || kind == 10 ? ENOTSUP : kind == 2 || kind == 7 ? EACCES :
            kind == 3 ? EIO : kind == 4 ? E2BIG : ENOSYS;
    return -1;
  }
#ifdef __APPLE__
  return flistxattr(fd, buf, cap, options);
#else
  return flistxattr(fd, buf, cap);
#endif
}
#ifdef __APPLE__
static ssize_t fixture_get(int fd, const char *name, void *buf, size_t cap, unsigned position, int options) {
#else
static ssize_t fixture_get(int fd, const char *name, void *buf, size_t cap) {
#endif
  int kind = selected(fd);
  if (kind == 8 || kind == 10) { errno = kind == 8 ? ENOTSUP : EACCES; return -1; }
#ifdef __APPLE__
  return fgetxattr(fd, name, buf, cap, position, options);
#else
  return fgetxattr(fd, name, buf, cap);
#endif
}
#define flistxattr fixture_list
#define fgetxattr fixture_get
#include "../../src/platform/config_edit.c"
#undef flistxattr
#undef fgetxattr
