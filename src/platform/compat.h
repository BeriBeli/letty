#ifndef LETTY_COMPAT_H
#define LETTY_COMPAT_H
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>
int lt_open(const char *path);
int64_t lt_length(int fd);
ssize_t lt_pread(int fd, void *buf, size_t len, uint64_t off);
void lt_close(int fd);
void lt_scan_fonts(const char *path, void *ctx,
                   void (*cb)(void *, const char *));
void lt_launch_context(size_t argc);
const char *lt_default_shell(void);
int lt_spawn(const char *shell, const char *command, const char *cwd,
             unsigned cols, unsigned rows, int *pid);
int lt_resize(int fd, unsigned cols, unsigned rows, unsigned cw, unsigned ch);
ssize_t lt_read(int fd, void *buf, size_t n);
ssize_t lt_write(int fd, const void *buf, size_t n);
int lt_wait(int pid, int *status);
void lt_signal(int pid, int sig);
uint64_t lt_millis(void);
const char *lt_env(const char *name);
int lt_write_atomic(const char *path, const void *data, size_t len);
unsigned lt_fd_watch(int fd, unsigned flags, int (*cb)(int, unsigned, void *),
                     void *ctx);
unsigned lt_child_watch(int pid, void (*cb)(int, int, void *), void *ctx);
void lt_unwatch(unsigned id);
int lt_probe(int gui);
int lt_foreground_state(int fd, int shell_pid);
int lt_foreground_group(int fd);
int lt_foreground_process(int fd, char *name, size_t name_cap, char *cwd, size_t cwd_cap);
void lt_terminate_session(int fd, int pid);
int lt_launch_opener(const char *target, int *out_pid);
int lt_absolute_path(const char *path, char *out, size_t cap);
int lt_create_config(const char *path, const void *data, size_t len);
#endif
