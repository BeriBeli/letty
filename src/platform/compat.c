#define _GNU_SOURCE
#include "compat.h"
#include "shell_launch.h"
#include "launch_account.h"
#include "pty_fds.h"
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pwd.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#else
#include <gnu/libc-version.h>
#include <pty.h>
#include <sys/utsname.h>
#endif
int lt_open(const char *p) { return open(p, O_RDONLY | O_CLOEXEC); }
int lt_config_open(const char *p) {
  int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return -1;
  struct stat info;
  if (fstat(fd, &info)) {
    int error = errno;
    close(fd);
    errno = error;
    return -1;
  }
  if (!S_ISREG(info.st_mode)) {
    close(fd);
    errno = EINVAL;
    return -1;
  }
  return fd;
}
int64_t lt_length(int fd) {
  struct stat s;
  return fstat(fd, &s) == 0 ? s.st_size : -1;
}
ssize_t lt_pread(int fd, void *b, size_t n, uint64_t o) {
  ssize_t r;
  do {
    r = pread(fd, b, n, (off_t)o);
  } while (r < 0 && errno == EINTR);
  return r;
}
void lt_close(int fd) {
  if (fd >= 0)
    close(fd);
}
static void scan(const char *p, void *ctx, void (*cb)(void *, const char *),
                 unsigned depth) {
  if (depth > 24)
    return;
  DIR *d = opendir(p);
  if (!d)
    return;
  struct dirent *e;
  char path[4096];
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.')
      continue;
    if (snprintf(path, sizeof path, "%s/%s", p, e->d_name) >= (int)sizeof path)
      continue;
    struct stat s;
    if (lstat(path, &s))
      continue;
    if (S_ISDIR(s.st_mode))
      scan(path, ctx, cb, depth + 1);
    else {
      const char *ext = strrchr(path, '.');
      if (ext && (!strcasecmp(ext, ".ttf") || !strcasecmp(ext, ".ttc")))
        cb(ctx, path);
    }
  }
  closedir(d);
}
void lt_scan_fonts(const char *p, void *ctx, void (*cb)(void *, const char *)) {
  scan(p, ctx, cb, 0);
}
const char *lt_env(const char *n) {
  const char *v = getenv(n);
  return v ? v : "";
}
uint64_t lt_millis(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int nonblock(int fd) {
  return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}
static int integration_directory(char *out, size_t cap) {
  char exe[4096];
#ifdef __APPLE__
  uint32_t size = sizeof exe;
  if (_NSGetExecutablePath(exe, &size)) return 0;
#else
  ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
  if (n < 0) return 0;
  exe[n] = 0;
#endif
  char *slash = strrchr(exe, '/');
  if (!slash) return 0;
  *slash = 0;
  const char *paths[] = {"../share/letty/shell-integration", "../Resources/shell-integration"};
  for (unsigned i = 0; i < sizeof paths / sizeof *paths; i++) {
    char check[4096];
    if (snprintf(out, cap, "%s/%s", exe, paths[i]) >= (int)cap) continue;
    if (snprintf(check, sizeof check, "%s/bash", out) >= (int)sizeof check) continue;
    if (!access(check, R_OK)) return 1;
  }
  return 0;
}
/* Capture launch context before setting TERM_PROGRAM in any PTY child.
   Finder/open are parented by launchd, matching Ghostty's desktop heuristic. */
static bool probable_cli;
void lt_launch_context(size_t argc) {
  (void)lt_launch_account();
#ifdef __APPLE__
  probable_cli = lt_probable_cli(true, getppid() == 1, getenv("TERM_PROGRAM"), argc);
#else
  probable_cli = lt_probable_cli(false, false, getenv("TERM_PROGRAM"), argc);
#endif
}
const char *lt_default_shell(void) {
  const char *shell = probable_cli ? getenv("SHELL") : NULL;
  if (shell && *shell) return shell;
  const LtLaunchAccount *account = lt_launch_account();
  return account && account->shell && *account->shell ? account->shell : "/bin/sh";
}
int lt_spawn_integrated(const char *shell, const char *cmd, const char *cwd, unsigned cols,
             unsigned rows, int *pid, bool integrate, bool *integrated) {
  const LtLaunchAccount *account = lt_launch_account();
  if (!account) return -1;
  const char *start_dir = lt_initial_directory(cwd, probable_cli,
      account ? account->home : NULL);
  char resources[4096] = {0};
  const char *name = strrchr(shell, '/'); name = name ? name + 1 : shell;
  bool zsh = !strcmp(name, "zsh"), bash = !strcmp(name, "bash");
#ifdef __APPLE__
  /* Apple's Bash 3.2 cannot reliably bootstrap through ENV/POSIX mode. */
  bash = false;
#endif
  const bool have_resources = integration_directory(resources, sizeof resources);
  integrate = integrate && (!cmd || !*cmd) && (zsh || bash) && have_resources;
  if (integrated) *integrated = integrate;
  bool quiet = false;
#ifdef __APPLE__
  char hush[4096];
  if (account && account->home &&
      snprintf(hush, sizeof hush, "%s/.hushlogin", account->home) < (int)sizeof hush)
    quiet = access(hush, F_OK) == 0;
  const bool darwin = true;
#else
  const bool darwin = false;
#endif
  const LtShellLaunch launch = lt_shell_launch(darwin,
      account ? account->name : NULL, quiet, shell, cmd, integrate && bash);
  int fd;
  struct winsize ws = {.ws_row = rows, .ws_col = cols};
  /* forkpty establishes a new session and controlling terminal in the child. */
  pid_t p = forkpty(&fd, NULL, NULL, &ws);
  if (p < 0)
    return -1;
  if (p == 0) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_DFL;
    for (int i = 1; i < NSIG; i++)
      sigaction(i, &sa, NULL);
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
    lt_close_extra_fds();
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    setenv("TERM_PROGRAM", "letty", 1);
    /* Manual integration (e.g. tcsh) needs the resource path too. */
    if (have_resources) setenv("LETTY_SHELL_DIR", resources, 1);
    if (integrate) {
      char entry[4096];
      if (zsh) {
        const char *old = getenv("ZDOTDIR");
        setenv("LETTY_ZDOTDIR_SET", old ? "1" : "0", 1);
        setenv("LETTY_ORIGINAL_ZDOTDIR", old ? old : (getenv("HOME") ? getenv("HOME") : "/"), 1);
        snprintf(entry, sizeof entry, "%s/zsh", resources);
        setenv("ZDOTDIR", entry, 1);
      } else {
        const char *old = getenv("ENV");
        setenv("LETTY_ENV_SET", old ? "1" : "0", 1);
        setenv("LETTY_ORIGINAL_ENV", old ? old : "", 1);
        snprintf(entry, sizeof entry, "%s/bash", resources);
        setenv("ENV", entry, 1);
        setenv("LETTY_BASH_BOOTSTRAP", "1", 1);
      }
    }
    unsetenv("LINES");
    unsetenv("COLUMNS");
    if (start_dir && *start_dir && chdir(start_dir)) {
      perror("letty: chdir");
      _exit(126);
    }
    /* Ghostty Exec.init passes PWD as well as cwd to preserve symlink paths. */
    if (start_dir && *start_dir) setenv("PWD", start_dir, 1);
    execvp(launch.argv[0], (char *const *)launch.argv);
    perror("letty: exec session");
    _exit(127);
  }
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  if (nonblock(fd)) {
    close(fd);
    kill(p, SIGKILL);
    waitpid(p, NULL, 0);
    return -1;
  }
  *pid = p;
  return fd;
}
int lt_spawn(const char *shell, const char *cmd, const char *cwd, unsigned cols, unsigned rows, int *pid) {
  return lt_spawn_integrated(shell, cmd, cwd, cols, rows, pid, false, NULL);
}
int lt_resize(int fd, unsigned c, unsigned r, unsigned cw, unsigned ch) {
  struct winsize ws = {
      .ws_col = c, .ws_row = r, .ws_xpixel = c * cw, .ws_ypixel = r * ch};
  return ioctl(fd, TIOCSWINSZ, &ws);
}
/* -2 means would block; zero is EOF (including Linux PTY EIO). */
ssize_t lt_read(int fd, void *b, size_t n) {
  ssize_t r;
  do {
    r = read(fd, b, n);
  } while (r < 0 && errno == EINTR);
  if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    return -2;
  if (r < 0 && errno == EIO)
    return 0;
  return r;
}
ssize_t lt_write(int fd, const void *b, size_t n) {
  ssize_t r;
  do {
    r = write(fd, b, n);
  } while (r < 0 && errno == EINTR);
  return r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? -2 : r;
}
int lt_wait(int p, int *s) {
  int r;
  do {
    r = waitpid(p, s, WNOHANG);
  } while (r < 0 && errno == EINTR);
  return r;
}
void lt_signal(int p, int s) {
  if (p > 0) {
    kill(-p, s);
    kill(p, s);
  }
}
int lt_write_atomic(const char *path, const void *data, size_t len) {
  char tmp[4096];
  if (snprintf(tmp, sizeof tmp, "%s.XXXXXX", path) >= (int)sizeof tmp)
    return -1;
  int fd = mkstemp(tmp);
  if (fd < 0)
    return -1;
  fchmod(fd, 0600);
  size_t at = 0;
  int ok = 0;
  while (at < len) {
    ssize_t n = write(fd, (const char *)data + at, len - at);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0)
      goto done;
    at += n;
  }
  if (fsync(fd))
    goto done;
  int closed = close(fd);
  fd = -1;
  if (closed)
    goto done;
  if (rename(tmp, path))
    goto done;
  ok = 1;
done:
  if (fd >= 0)
    close(fd);
  if (!ok)
    unlink(tmp);
  return ok ? 0 : -1;
}
#ifndef __APPLE__
static void *glib(void) {
  static void *lib;
  if (!lib)
    lib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_LOCAL);
  return lib;
}
unsigned lt_fd_watch(int fd, unsigned flags, int (*cb)(int, unsigned, void *),
                     void *ctx) {
  typedef unsigned (*Fn)(int, int, unsigned, int (*)(int, unsigned, void *),
                         void *, void (*)(void *));
  Fn f = (Fn)dlsym(glib(), "g_unix_fd_add_full");
  /* Match redraw idle priority: a continuously readable PTY must not starve
     paint. GDK input remains at its higher default priority. */
  return f ? f(200, fd, flags, cb, ctx, NULL) : 0;
}
unsigned lt_child_watch(int pid, void (*cb)(int, int, void *), void *ctx) {
  typedef unsigned (*Fn)(int, void (*)(int, int, void *), void *);
  Fn f = (Fn)dlsym(glib(), "g_child_watch_add");
  return f ? f(pid, cb, ctx) : 0;
}
unsigned lt_timeout(unsigned ms, int (*cb)(void *), void *ctx) {
  typedef unsigned (*Fn)(int, unsigned, int (*)(void *), void *, void (*)(void *));
  Fn f = (Fn)dlsym(glib(), "g_timeout_add_full");
  return f ? f(0, ms, cb, ctx, NULL) : 0;
}
void lt_unwatch(unsigned id) {
  typedef int (*Fn)(unsigned);
  Fn f = (Fn)dlsym(glib(), "g_source_remove");
  if (id && f)
    f(id);
}
#else
unsigned lt_fd_watch(int f, unsigned x, int (*cb)(int, unsigned, void *),
                     void *ctx) {
  (void)f;
  (void)x;
  (void)cb;
  (void)ctx;
  return 0;
}
unsigned lt_child_watch(int p, void (*cb)(int, int, void *), void *ctx) {
  (void)p;
  (void)cb;
  (void)ctx;
  return 0;
}
unsigned lt_timeout(unsigned ms, int (*cb)(void *), void *ctx) {
  (void)ms; (void)cb; (void)ctx;
  return 0;
}
void lt_unwatch(unsigned id) { (void)id; }
#endif
static int fonts;
static void font_probe(void *ctx, const char *p) {
  (void)ctx;
  if (fonts)
    return;
  int fd = lt_open(p);
  if (fd < 0)
    return;
  unsigned char b[12];
  int64_t n = lt_length(fd);
  ssize_t got = lt_pread(fd, b, sizeof b, 0);
  lt_close(fd);
  if (n > 12 && got == 12) {
    fonts = 1;
    printf("PASS font open/fstat/pread: %s (%lld bytes)\n", p, (long long)n);
  }
}
int lt_probe(int gui) {
  int failures = 0;
#ifndef __APPLE__
  struct utsname u;
  if (!uname(&u))
    printf("kernel=%s arch=%s glibc=%s\n", u.release, u.machine,
           gnu_get_libc_version());
#endif
  int fd = lt_open("/etc/passwd");
  char b[32];
  if (fd >= 0 && lt_length(fd) > 0 && lt_pread(fd, b, sizeof b, 0) > 0)
    puts("PASS file open/fstat/pread");
  else {
    puts("FAIL file I/O");
    failures++;
  }
  lt_close(fd);
  fonts = 0;
  lt_scan_fonts("/usr/share/fonts", NULL, font_probe);
#ifdef __APPLE__
  lt_scan_fonts("/System/Library/Fonts", NULL, font_probe);
#endif
  const char *home = getenv("HOME");
  if (home) {
    char p[4096];
    snprintf(p, sizeof p, "%s/.local/share/fonts", home);
    lt_scan_fonts(p, NULL, font_probe);
    snprintf(p, sizeof p, "%s/.fonts", home);
    lt_scan_fonts(p, NULL, font_probe);
  }
  if (!fonts) {
    puts("FAIL no readable TTF/TTC font");
    failures++;
  }
#ifndef __APPLE__
  if (gui) {
    const char *libs[] = {"libgtk-3.so.0", "libgdk-3.so.0", "libglib-2.0.so.0",
                          "libgobject-2.0.so.0", "libcairo.so.2"};
    for (unsigned i = 0; i < sizeof libs / sizeof *libs; i++) {
      void *h = dlopen(libs[i], RTLD_NOW | RTLD_LOCAL);
      if (h) {
        printf("PASS dlopen %s\n", libs[i]);
        dlclose(h);
      } else {
        printf("FAIL %s: %s\n", libs[i], dlerror());
        failures++;
      }
    }
    printf("DISPLAY=%s GTK_IM_MODULE=%s XMODIFIERS=%s\n", lt_env("DISPLAY"),
           lt_env("GTK_IM_MODULE"), lt_env("XMODIFIERS"));
  }
#else
  (void)gui;
#endif
  return failures ? 1 : 0;
}
void lt_reap(int pid) {
  int r;
  do {
    r = waitpid(pid, NULL, 0);
  } while (r < 0 && errno == EINTR);
}
int lt_mkdirs(const char *path) {
  char p[4096];
  if (strlen(path) >= sizeof p)
    return -1;
  strcpy(p, path);
  for (char *q = p + 1; *q; q++)
    if (*q == '/') {
      *q = 0;
      if (mkdir(p, 0700) && errno != EEXIST)
        return -1;
      *q = '/';
    }
  return mkdir(p, 0700) && errno != EEXIST ? -1 : 0;
}
void lt_pause_ms(unsigned ms) {
  struct timespec t = {.tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000};
  while (nanosleep(&t, &t) && errno == EINTR) {
  }
}
#ifndef __APPLE__
int lt_clipboard_request_location(void *ctx, bool primary, void (*cb)(void *, const char *, void *)) {
  void *lib = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib) return -1;
  typedef void *(*Atom)(const char *, int);
  typedef void *(*Get)(void *);
  typedef void (*Request)(void *, void (*)(void *, const char *, void *), void *);
  Atom atom = (Atom)dlsym(lib, "gdk_atom_intern");
  Get get = (Get)dlsym(lib, "gtk_clipboard_get");
  Request request = (Request)dlsym(lib, "gtk_clipboard_request_text");
  if (!atom || !get || !request) { dlclose(lib); return -1; }
  request(get(atom(primary ? "PRIMARY" : "CLIPBOARD", 0)), cb, ctx);
  dlclose(lib); return 0;
}
int lt_primary_write(const char *text, size_t len) {
  void *lib = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_LOCAL);
  if (!lib || len > 1024 * 1024) { if (lib) dlclose(lib); return -1; }
  typedef void *(*Atom)(const char *, int);
  typedef void *(*Get)(void *);
  typedef void (*Set)(void *, const char *, int);
  Atom atom = (Atom)dlsym(lib, "gdk_atom_intern"); Get get = (Get)dlsym(lib, "gtk_clipboard_get"); Set set = (Set)dlsym(lib, "gtk_clipboard_set_text");
  if (!atom || !get || !set) { dlclose(lib); return -1; }
  set(get(atom("PRIMARY", 0)), text, (int)len); dlclose(lib); return 0;
}
#else
int lt_clipboard_request_location(void *ctx, bool primary, void (*cb)(void *, const char *, void *)) { (void)ctx; (void)primary; (void)cb; return -1; }
int lt_primary_write(const char *text, size_t len) { (void)text; (void)len; return -1; }
#endif
int lt_clipboard_request(void *ctx, void (*cb)(void *, const char *, void *)) { return lt_clipboard_request_location(ctx, false, cb); }


/* Same foreground group may be a shell or an exec'ed task: report unknown. */
int lt_foreground_state(int fd, int shell_pid) {
  pid_t foreground = tcgetpgrp(fd);
  return foreground > 0 && foreground != shell_pid ? 1 : -1;
}
int lt_create_config(const char *path, const void *data, size_t len) {
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (fd < 0) return errno == EEXIST ? 1 : -1;
  const char *bytes = data; size_t at = 0;
  while (at < len) {
    ssize_t n = write(fd, bytes + at, len - at);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { close(fd); unlink(path); return -1; }
    at += (size_t)n;
  }
  int rc = close(fd); return rc == 0 ? 0 : -1;
}

extern char **environ;
int lt_launch_opener(const char *target, int *out_pid) {
  pid_t pid = 0;
  char *const argv[] = {"xdg-open", (char *)target, NULL};
  int error = posix_spawnp(&pid, "xdg-open", NULL, NULL, argv, environ);
  if (error) return -1;
  *out_pid = pid; return 0;
}
int lt_absolute_path(const char *path, char *out, size_t cap) {
  if (path[0] == '/') return snprintf(out, cap, "%s", path) >= (int)cap ? -1 : 0;
  if (!getcwd(out, cap)) return -1;
  size_t used = strlen(out);
  return snprintf(out + used, cap - used, "/%s", path) >= (int)(cap - used) ? -1 : 0;
}

int lt_foreground_group(int fd) { return tcgetpgrp(fd); }
/* Name and kernel working directory of the PTY foreground group leader. Only
   in-kernel process tables are queried; no candidate file is stat'ed or read. */
int lt_foreground_process(int fd, char *name, size_t name_cap, char *cwd, size_t cwd_cap) {
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
bool lt_shell_idle(int fd, int group) { return group > 0 && tcgetpgrp(fd) == group; }
void lt_terminate_session(int fd, int pid) {
  pid_t foreground = tcgetpgrp(fd);
  /* Darwin login remains the watched child while the shell has its own group.
     The controlling PTY can only designate a group in that same session. */
  if (foreground > 0 && foreground != pid) {
    kill(-foreground, SIGHUP);
    kill(-foreground, SIGKILL);
  }
  lt_signal(pid, SIGHUP);
  lt_signal(pid, SIGKILL);
}
bool lt_local_directory(const char *host, const char *path) {
  char local[256] = {0};
  if (*host && strcmp(host, "localhost") && strcmp(host, "127.0.0.1") && strcmp(host, "[::1]")) {
    if (gethostname(local, sizeof local - 1) || strcmp(host, local)) return false;
  }
  struct stat st;
  return path[0] == '/' && !stat(path, &st) && S_ISDIR(st.st_mode);
}
uint64_t lt_cpu_micros(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)) return 0;
  return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}
uint64_t lt_micros(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}
/* Explicit diagnostic snapshots only; never called by rendering or PTY I/O. */
void lt_memory_usage(uint64_t *rss, uint64_t *pss, uint64_t *peak) {
  *rss = *pss = *peak = 0;
  struct rusage usage;
  if (!getrusage(RUSAGE_SELF, &usage)) {
#ifdef __APPLE__
    *peak = usage.ru_maxrss;
#else
    *peak = (uint64_t)usage.ru_maxrss * 1024;
#endif
  }
#ifdef __APPLE__
  struct proc_taskinfo task;
  if (proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, sizeof task) == sizeof task)
    *rss = task.pti_resident_size;
#else
  FILE *file = fopen("/proc/self/smaps", "r");
  if (!file) return;
  char line[512];
  unsigned long long kib;
  while (fgets(line, sizeof line, file)) {
    if (sscanf(line, "Rss: %llu kB", &kib) == 1) *rss += kib * 1024;
    if (sscanf(line, "Pss: %llu kB", &kib) == 1) *pss += kib * 1024;
  }
  fclose(file);
#endif
}
/* Each process owns one persistence writer. Secondary instances use a PID path. */
#include <sys/file.h>
int lt_state_lock(const char *path) {
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return -1;
  if (flock(fd, LOCK_EX | LOCK_NB)) { close(fd); return -1; }
  return fd;
}
int lt_process_id(void) { return getpid(); }
