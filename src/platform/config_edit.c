#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include "config_edit.h"
#include <sys/stat.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/xattr.h>
#ifdef __APPLE__
#include <sys/acl.h>
#endif
_Static_assert(sizeof(LtConfigFileInfo) == 72, "config metadata size");
_Static_assert(offsetof(LtConfigFileInfo, mode) == 56, "config metadata layout");
int lt_config_edit_info(int fd, LtConfigFileInfo *out) {
  struct stat st;
  if (fstat(fd, &st)) return -1;
  if (st.st_size < 0) { errno = EOVERFLOW; return -1; }
  *out = (LtConfigFileInfo){ .device = (uint64_t)st.st_dev,
    .inode = (uint64_t)st.st_ino, .size = (uint64_t)st.st_size,
    .mode = (uint32_t)st.st_mode, .uid = (uint32_t)st.st_uid,
    .gid = (uint32_t)st.st_gid };
#ifdef __APPLE__
  out->mtime_sec = st.st_mtimespec.tv_sec; out->mtime_nsec = st.st_mtimespec.tv_nsec;
  out->ctime_sec = st.st_ctimespec.tv_sec; out->ctime_nsec = st.st_ctimespec.tv_nsec;
#else
  out->mtime_sec = st.st_mtim.tv_sec; out->mtime_nsec = st.st_mtim.tv_nsec;
  out->ctime_sec = st.st_ctim.tv_sec; out->ctime_nsec = st.st_ctim.tv_nsec;
#endif
  return 0;
}
int lt_config_theme_scan(const char *directory, size_t max_entries,
                        LtThemeVisit visit, void *context,
                        size_t *scanned, int *truncated) {
  *scanned = 0; *truncated = 0;
  int fd = open(directory, O_RDONLY | O_DIRECTORY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return -1;
  DIR *dir = fdopendir(fd);
  if (!dir) { int e = errno; close(fd); errno = e; return -1; }
  int result = 0, saved = 0;
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (!entry) { if (errno) { result = -1; saved = errno; } break; }
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    if (*scanned == max_entries) { *truncated = 1; break; }
    ++*scanned;
    struct stat st;
    if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) {
      if (errno == ENOENT) continue; /* Disappeared while listing. */
      result = -1; saved = errno; break;
    }
    if (!S_ISREG(st.st_mode)) continue;
    size_t len = strlen(entry->d_name);
    if (visit(context, entry->d_name, len)) { result = -1; saved = ECANCELED; break; }
  }
  if (closedir(dir) && !result) { result = -1; saved = errno; }
  if (result) errno = saved;
  return result;
}

/* Preserve all names, including security/system namespaces. We never silently
   ignore an unreadable/unwritable attribute. Identical destination values are
   left alone (important for inherited SELinux labels a user cannot relabel). */
#define NAME_BYTES (16u * 1024u)
#define NAME_COUNT 256u
static ssize_t names_get(int fd, char *buf, size_t cap) {
#ifdef __APPLE__
  return flistxattr(fd, buf, cap, 0);
#else
  return flistxattr(fd, buf, cap);
#endif
}
static ssize_t value_get(int fd, const char *name, void *buf, size_t cap) {
#ifdef __APPLE__
  return fgetxattr(fd, name, buf, cap, 0, 0);
#else
  return fgetxattr(fd, name, buf, cap);
#endif
}
static int value_set(int fd, const char *name, const void *buf, size_t len) {
#ifdef __APPLE__
  return fsetxattr(fd, name, buf, len, 0, 0);
#else
  return fsetxattr(fd, name, buf, len, 0);
#endif
}
static int value_remove(int fd, const char *name) {
#ifdef __APPLE__
  return fremovexattr(fd, name, 0);
#else
  return fremovexattr(fd, name);
#endif
}
static int names_compare(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}
static int names_sorted(int fd, char *buf, char **names, size_t *count, int *unsupported) {
  ssize_t size = names_get(fd, buf, NAME_BYTES);
  *count = 0;
  *unsupported = 0;
  if (size < 0) {
    if (errno != ENOTSUP && errno != EOPNOTSUPP) return -1;
    /* NFS can reject xattr enumeration even for writable ordinary files.
       Record this capability separately from a supported, empty list. Never
       treat access, IO, size, or an individual attribute's error as empty. */
    *unsupported = 1;
#ifndef __APPLE__
    /* ACLs may have their own NFS protocol even without generic xattrs.
       Probe them explicitly so a replacement cannot silently discard them. */
    static const char *const acl_names[] = { "system.posix_acl_access", "system.nfs4_acl" };
    size_t at = 0;
    for (size_t i = 0; i < sizeof acl_names / sizeof *acl_names; ++i) {
      ssize_t acl_size = value_get(fd, acl_names[i], NULL, 0);
      if (acl_size < 0) {
        if (errno == ENODATA || errno == ENOTSUP || errno == EOPNOTSUPP) continue;
        return -1;
      }
      size_t len = strlen(acl_names[i]) + 1;
      memcpy(buf + at, acl_names[i], len);
      names[(*count)++] = buf + at;
      at += len;
    }
#endif
    qsort(names, *count, sizeof *names, names_compare);
    return 0;
  }
  for (size_t at = 0; at < (size_t)size;) {
    size_t len = strnlen(buf + at, (size_t)size - at);
    if (!len || len == (size_t)size - at) { errno = EIO; return -1; }
    if (*count == NAME_COUNT) { errno = E2BIG; return -1; }
    names[(*count)++] = buf + at;
    at += len + 1;
  }
  qsort(names, *count, sizeof *names, names_compare);
  return 0;
}
static int append(unsigned char *out, size_t cap, size_t *at, const void *data, size_t len) {
  if (*at > cap || len > cap - *at) { errno = E2BIG; return -1; }
  if (len) memcpy(out + *at, data, len);
  *at += len;
  return 0;
}
static int append_u32(unsigned char *out, size_t cap, size_t *at, uint32_t value) {
  unsigned char bytes[4] = { value, value >> 8, value >> 16, value >> 24 };
  return append(out, cap, at, bytes, sizeof bytes);
}
int lt_config_edit_metadata(int fd, unsigned char *out, size_t cap, size_t *len) {
  char buffer[NAME_BYTES], *names[NAME_COUNT]; size_t count, at = 0;
  int unsupported;
  if (cap > LT_CONFIG_METADATA_MAX) cap = LT_CONFIG_METADATA_MAX;
  if (names_sorted(fd, buffer, names, &count, &unsupported)) return -1;
  if (append_u32(out, cap, &at, (uint32_t)count | (unsupported ? 0x80000000u : 0))) return -1;
  for (size_t i = 0; i < count; ++i) {
    size_t name_len = strlen(names[i]);
    ssize_t size = value_get(fd, names[i], NULL, 0);
    if (size < 0) return -1;
    if ((size_t)size > LT_CONFIG_METADATA_MAX) { errno = E2BIG; return -1; }
    if (append_u32(out, cap, &at, (uint32_t)name_len) || append(out, cap, &at, names[i], name_len) ||
        append_u32(out, cap, &at, (uint32_t)size)) return -1;
    if ((size_t)size > cap - at) { errno = E2BIG; return -1; }
    ssize_t got = value_get(fd, names[i], out + at, (size_t)size);
    if (got < 0) return -1;
    if (got != size) { errno = EAGAIN; return -1; }
    at += (size_t)got;
  }
#ifdef __APPLE__
  acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
  if (!acl && errno != ENOENT) return -1;
  /* Darwin reports an ordinary file without an extended ACL as ENOENT. */
  if (!acl) {
    if (append_u32(out, cap, &at, 0)) return -1;
    *len = at;
    return 0;
  }
  ssize_t acl_len = 0;
  char *text = acl_to_text(acl, &acl_len);
  if (!text) { int e = errno; acl_free(acl); errno = e; return -1; }
  int failed = acl_len < 0 || (uint64_t)acl_len > LT_CONFIG_METADATA_MAX;
  if (failed) errno = E2BIG;
  else failed = append_u32(out, cap, &at, (uint32_t)acl_len) || append(out, cap, &at, text, (size_t)acl_len);
  int e = errno; acl_free(text); acl_free(acl); errno = e;
  if (failed) return -1;
#else
  /* Linux POSIX ACL is already present as system.posix_acl_access xattr. */
  if (append_u32(out, cap, &at, 0)) return -1;
#endif
  *len = at;
  return 0;
}
int lt_config_edit_copy_metadata(int from_fd, int to_fd) {
  char src_buf[NAME_BYTES], dst_buf[NAME_BYTES], *src[NAME_COUNT], *dst[NAME_COUNT];
  size_t src_count, dst_count;
  int src_unsupported, dst_unsupported;
  if (names_sorted(from_fd, src_buf, src, &src_count, &src_unsupported) ||
      names_sorted(to_fd, dst_buf, dst, &dst_count, &dst_unsupported)) return -1;
  /* A sibling replacement must have the same metadata capability. A change
     is a conflict, not permission to erase attributes on either inode. */
  if (src_unsupported != dst_unsupported) { errno = EAGAIN; return -1; }
  for (size_t i = 0; i < dst_count; ++i) {
    int found = 0;
    for (size_t j = 0; j < src_count; ++j) if (!strcmp(dst[i], src[j])) { found = 1; break; }
    if (!found && value_remove(to_fd, dst[i])) return -1;
  }
  unsigned char *value = malloc(LT_CONFIG_METADATA_MAX), *existing = malloc(LT_CONFIG_METADATA_MAX);
  if (!value || !existing) { free(value); free(existing); errno = ENOMEM; return -1; }
  int result = 0, saved = 0;
  size_t total = 0;
  for (size_t i = 0; i < src_count; ++i) {
    ssize_t size = value_get(from_fd, src[i], value, LT_CONFIG_METADATA_MAX);
    if (size < 0) { result = -1; saved = errno; break; }
    if ((size_t)size > LT_CONFIG_METADATA_MAX - total) { result = -1; saved = E2BIG; break; }
    total += (size_t)size;
    ssize_t same = value_get(to_fd, src[i], existing, LT_CONFIG_METADATA_MAX);
    if (same == size && !memcmp(value, existing, (size_t)size)) continue;
    if (value_set(to_fd, src[i], value, (size_t)size)) { result = -1; saved = errno; break; }
  }
  free(value); free(existing);
  if (result) { errno = saved; return -1; }
#ifdef __APPLE__
  acl_t acl = acl_get_fd_np(from_fd, ACL_TYPE_EXTENDED);
  if (!acl && errno != ENOENT) return -1;
  /* Explicitly clear any ACL inherited by the replacement inode. */
  if (!acl) acl = acl_init(0);
  if (!acl) return -1;
  result = acl_set_fd_np(to_fd, acl, ACL_TYPE_EXTENDED);
  saved = errno; acl_free(acl); errno = saved;
#endif
  return result;
}
