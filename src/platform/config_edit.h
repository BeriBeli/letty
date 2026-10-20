#ifndef LETTY_CONFIG_EDIT_H
#define LETTY_CONFIG_EDIT_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
  uint64_t device, inode, size;
  int64_t mtime_sec, mtime_nsec, ctime_sec, ctime_nsec;
  uint32_t mode, uid, gid, reserved;
} LtConfigFileInfo;
/* 0 success, -1 failure with errno. Does not allocate or retain pointers. */
int lt_config_edit_info(int fd, LtConfigFileInfo *out);
/* Canonical bounded snapshot/copy of ACL and every extended attribute.
   256KiB total, 16KiB name list, 256 names; E2BIG refuses larger metadata.
   Metadata copy affects only destination. Failure must precede rename. */
#define LT_CONFIG_METADATA_MAX (256u * 1024u)
int lt_config_edit_metadata(int fd, unsigned char *out, size_t cap, size_t *len);
int lt_config_edit_copy_metadata(int from_fd, int to_fd);
typedef int (*LtThemeVisit)(void *, const char *, size_t);
/* Count every non-dot entry against max_entries. Visit regular files only;
   symlinks and subdirectories are skipped. Callback strings are borrowed only
   during that call. Callback nonzero stops with ECANCELED. Missing directories
   preserve ENOENT/ENOTDIR; callers decide whether a scan root is optional. */
int lt_config_theme_scan(const char *directory, size_t max_entries,
                        LtThemeVisit visit, void *context,
                        size_t *scanned, int *truncated);
#endif
