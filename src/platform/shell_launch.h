#ifndef LETTY_SHELL_LAUNCH_H
#define LETTY_SHELL_LAUNCH_H
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

/* Adapted from Ghostty Config.probableCliEnvironment / WorkingDirectory:
   src/config/Config.zig and src/os/desktop.zig at the locked vendor revision. */
static inline bool lt_probable_cli(bool darwin, bool desktop,
    const char *term_program, size_t argc) {
  if (darwin && desktop) return false;
  return (term_program && *term_program) || argc > 1;
}
static inline const char *lt_initial_directory(const char *requested,
    bool probable_cli, const char *account_home) {
  if (!requested || !*requested) requested = probable_cli ? "inherit" : "home";
  if (!strcmp(requested, "inherit")) return NULL;
  if (!strcmp(requested, "home")) return account_home;
  return requested;
}

/* Keep shell/command strings as argv values, never interpolate them into code.
   Mirrors Ghostty's Darwin login wrapper and non-login POSIX shell launch. */
typedef struct {
  const char *argv[16];
} LtShellLaunch;

static inline LtShellLaunch lt_shell_launch(bool darwin, const char *username,
    bool quiet, const char *shell, const char *command, bool bash_integration) {
  LtShellLaunch plan = {0};
  size_t n = 0;
  bool has_command = command && *command;
  if (darwin && username && *username) {
    plan.argv[n++] = "/usr/bin/login";
    if (quiet) plan.argv[n++] = "-q";
    /* -l preserves cwd, -p preserves integration env, -f uses our own account. */
    plan.argv[n++] = "-flp";
    plan.argv[n++] = username;
    plan.argv[n++] = "/bin/bash";
    plan.argv[n++] = "--noprofile";
    plan.argv[n++] = "--norc";
    plan.argv[n++] = "-c";
    plan.argv[n++] = "exec -l -- \"$@\"";
    plan.argv[n++] = "letty-login";
    plan.argv[n++] = shell;
    if (has_command) {
      plan.argv[n++] = "-c";
      plan.argv[n++] = command;
    }
  } else {
    plan.argv[n++] = shell;
    if (has_command) {
      plan.argv[n++] = "-c";
      plan.argv[n++] = command;
    } else if (bash_integration) {
      plan.argv[n++] = "--posix";
      plan.argv[n++] = "-i";
    }
  }
  return plan;
}
#endif
