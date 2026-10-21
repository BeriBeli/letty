#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <sys/stat.h>
#include <sys/xattr.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#ifdef __APPLE__
#include <sys/acl.h>
#include <membership.h>
#include <uuid/uuid.h>
#endif
int lt_config_fixture_write(const char *path, const void *bytes, size_t len, unsigned mode) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, mode);
  if (fd < 0) return -1;
  size_t at = 0;
  while (at < len) {
    ssize_t n = write(fd, (const char *)bytes + at, len - at);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { close(fd); return -1; }
    at += n;
  }
  int rc = fchmod(fd, mode); int e = errno; close(fd); errno = e; return rc;
}
int lt_config_fixture_xattr(const char *path, const char *value) {
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC); if (fd < 0) return -1;
  size_t len = 0; while (value[len]) ++len;
#ifdef __APPLE__
  int rc = fsetxattr(fd, "com.letty.native-fixture", value, len, 0, 0);
#else
  int rc = fsetxattr(fd, "user.letty.native-fixture", value, len, 0);
#endif
  int e = errno; close(fd); errno = e; return rc;
}
int lt_config_fixture_acl_variant(const char *path, int writable) {
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC); if (fd < 0) return -1;
#ifdef __APPLE__
  uuid_t user; int rc = mbr_uid_to_uuid(geteuid(), user);
  if (rc) { close(fd); errno = rc; return -1; }
  acl_t acl = acl_init(1); if (!acl) { close(fd); return -1; }
  acl_entry_t entry; acl_permset_t permissions;
  rc = acl_create_entry(&acl, &entry) || acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) ||
       acl_set_qualifier(entry, user) || acl_get_permset(entry, &permissions) ||
       acl_add_perm(permissions, ACL_READ_DATA) ||
       (writable && acl_add_perm(permissions, ACL_WRITE_DATA)) || acl_set_permset(entry, permissions) ||
       acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED);
  int e = errno; acl_free(acl); close(fd); errno = e; return rc ? -1 : 0;
#else
  /* Linux POSIX ACL xattr version2, LE host target x86_64; owner rw, named
     mapped current user r, group r, mask r, other none. No libacl dependency. */
  unsigned char acl[] = {
    2,0,0,0, 1,0,6,0,255,255,255,255, 2,0,4,0,254,255,0,0,
    4,0,4,0,255,255,255,255, 16,0,4,0,255,255,255,255, 32,0,0,0,255,255,255,255 };
  uint32_t named_uid = (uint32_t)geteuid();
  for (unsigned i = 0; i < 4; ++i) acl[16 + i] = (unsigned char)(named_uid >> (8 * i));
  if (writable) { acl[14] = 6; acl[30] = 6; }
  int rc = fsetxattr(fd, "system.posix_acl_access", acl, sizeof acl, 0);
  int e = errno; close(fd); errno = e; return rc;
#endif
}
int lt_config_fixture_acl(const char *path) { return lt_config_fixture_acl_variant(path, 0); }
int lt_config_fixture_acl_count(const char *path) {
  int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC); if (fd < 0) return -1;
#ifdef __APPLE__
  acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED); if (!acl) { close(fd); return -1; }
  acl_entry_t entry; int count = 0, which = ACL_FIRST_ENTRY;
  while (!acl_get_entry(acl, which, &entry)) { ++count; which = ACL_NEXT_ENTRY; }
  acl_free(acl); close(fd); return count;
#else
  ssize_t size = fgetxattr(fd, "system.posix_acl_access", NULL, 0); close(fd);
  return size >= 4 ? (int)(size - 4) / 8 : -1;
#endif
}

/* Explicitly selected reader for owned fixture inodes only. Production reads
   never call this function; there is no global syscall or environment hook. */
#include "../../src/platform/config_edit.h"
static dev_t metadata_fault_device;
static ino_t metadata_fault_inode;
static int metadata_fault_kind;
int lt_config_fixture_metadata_fault(const char *path, int kind) {
  struct stat st;
  if (stat(path, &st)) return -1;
  metadata_fault_device = st.st_dev; metadata_fault_inode = st.st_ino;
  metadata_fault_kind = kind;
  return 0;
}
int lt_config_fixture_metadata_read(int fd, unsigned char *out, size_t cap, size_t *len) {
  struct stat st;
  if (fstat(fd, &st)) return -1;
  if (metadata_fault_kind && st.st_dev == metadata_fault_device && st.st_ino == metadata_fault_inode) {
    errno = metadata_fault_kind == 1 ? ENOTSUP : metadata_fault_kind == 2 ? EACCES : EIO;
    return -1;
  }
  return lt_config_edit_metadata(fd, out, cap, len);
}
