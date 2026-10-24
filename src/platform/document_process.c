/* Local terminal origin lookup. No candidate file is touched by this probe. */
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE
#include <sys/types.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef __APPLE__
#include <libproc.h>
#endif
int lt_document_foreground_process(int fd, char *name, size_t name_cap, char *cwd, size_t cwd_cap) {
  if (!name || !cwd || name_cap < 2 || cwd_cap < 2) return -1;
  name[0] = 0;
  cwd[0] = 0;
  pid_t group = tcgetpgrp(fd);
  if (group <= 0) return -1;
#ifdef __APPLE__
  /* Prefer the group leader. A non-interactive shell under the setuid login
     wrapper keeps login's group, so fall back to the newest own-user member. */
  pid_t chosen = 0;
  struct proc_bsdinfo bsd;
  if (proc_pidinfo(group, PROC_PIDTBSDINFO, 0, &bsd, sizeof bsd) == (int)sizeof bsd && bsd.pbi_uid == getuid()) chosen = group;
  if (!chosen) {
    pid_t members[64];
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)group, members, sizeof members);
    uint64_t newest = 0;
    for (int i = 0; bytes > 0 && i < bytes / (int)sizeof(pid_t); i++) {
      if (members[i] <= 0 || proc_pidinfo(members[i], PROC_PIDTBSDINFO, 0, &bsd, sizeof bsd) != (int)sizeof bsd || bsd.pbi_uid != getuid() || (pid_t)bsd.pbi_pgid != group) continue;
      uint64_t started = bsd.pbi_start_tvsec * 1000000ull + bsd.pbi_start_tvusec;
      if (!chosen || started >= newest) { chosen = members[i]; newest = started; }
    }
  }
  if (!chosen || proc_name(chosen, name, (uint32_t)name_cap) <= 0) { name[0] = 0; return -1; }
  name[name_cap - 1] = 0;
  struct proc_vnodepathinfo info;
  if (proc_pidinfo(chosen, PROC_PIDVNODEPATHINFO, 0, &info, sizeof info) == (int)sizeof info) {
    size_t n = strnlen(info.pvi_cdir.vip_path, sizeof info.pvi_cdir.vip_path);
    if (n > 0 && n < cwd_cap && info.pvi_cdir.vip_path[0] == '/') { memcpy(cwd, info.pvi_cdir.vip_path, n); cwd[n] = 0; }
  }
#else
  char path[64];
  snprintf(path, sizeof path, "/proc/%d/comm", (int)group);
  int file = open(path, O_RDONLY | O_CLOEXEC);
  if (file < 0) return -1;
  ssize_t n = read(file, name, name_cap - 1);
  close(file);
  if (n <= 0) { name[0] = 0; return -1; }
  while (n > 0 && name[n - 1] == '\n') n--;
  name[n] = 0;
  snprintf(path, sizeof path, "/proc/%d/cwd", (int)group);
  ssize_t m = readlink(path, cwd, cwd_cap - 1);
  /* Truncated or deleted directories are not trusted bases. */
  if (m <= 0 || (size_t)m >= cwd_cap - 1 || cwd[0] != '/' || (m >= 10 && !memcmp(cwd + m - 10, " (deleted)", 10))) cwd[0] = 0;
  else cwd[m] = 0;
#endif
  return (int)group;
}
