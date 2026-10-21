#ifndef LETTY_LAUNCH_ACCOUNT_H
#define LETTY_LAUNCH_ACCOUNT_H
#include <pwd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Main-thread launch context, owned for the process lifetime. NSS can involve
   a remote directory service; resolve once instead of for every tab/split.
   Copy libc's borrowed record before any other account lookup can replace it. */
typedef struct { char *shell, *home, *name; } LtLaunchAccount;
static LtLaunchAccount launch_account;
static int launch_account_ready, launch_account_cleanup;
static uid_t launch_account_uid;
static void lt_launch_account_clear(void) {
  free(launch_account.shell); free(launch_account.home); free(launch_account.name);
  launch_account = (LtLaunchAccount){0};
}
static const LtLaunchAccount *lt_launch_account(void) {
  uid_t uid = getuid();
  if (launch_account_ready && launch_account_uid == uid) return &launch_account;
  if (!launch_account_cleanup) {
    if (atexit(lt_launch_account_clear)) { errno = ENOMEM; return NULL; }
    launch_account_cleanup = 1;
  }
  lt_launch_account_clear();
  launch_account_ready = 1;
  launch_account_uid = uid;
  struct passwd *account = getpwuid(uid);
  if (account) {
    launch_account.shell = account->pw_shell ? strdup(account->pw_shell) : NULL;
    launch_account.home = account->pw_dir ? strdup(account->pw_dir) : NULL;
    launch_account.name = account->pw_name ? strdup(account->pw_name) : NULL;
    if ((account->pw_shell && !launch_account.shell) || (account->pw_dir && !launch_account.home) ||
        (account->pw_name && !launch_account.name)) {
      lt_launch_account_clear(); launch_account_ready = 0; errno = ENOMEM; return NULL;
    }
  }
  return &launch_account;
}
#endif
