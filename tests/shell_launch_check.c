#include "platform/shell_launch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static void same(LtShellLaunch launch, const char *const *expected) {
  size_t i = 0;
  for (; expected[i]; i++) {
    assert(launch.argv[i]);
    assert(!strcmp(launch.argv[i], expected[i]));
  }
  assert(!launch.argv[i]);
}
int main(int argc, char **argv) {
  if (argc == 5 && !strcmp(argv[1], "exec")) {
    bool darwin = !strcmp(argv[2], "darwin");
    LtShellLaunch launch = lt_shell_launch(darwin, "fixture", false,
                                          argv[3], argv[4], false);
    /* Execute the Darwin payload without system login/accounting in tests. */
    size_t at = darwin ? 3 : 0;
    execvp(launch.argv[at], (char *const *)(launch.argv + at));
    return 127;
  }
  assert(!lt_probable_cli(true, true, "ghostty", 3));
  assert(lt_probable_cli(true, false, "ghostty", 1));
  assert(lt_probable_cli(false, false, NULL, 2));
  assert(!lt_probable_cli(false, false, "", 1));
  assert(!strcmp(lt_initial_directory("", false, "/account/home"), "/account/home"));
  assert(!lt_initial_directory("", true, "/account/home"));
  assert(!strcmp(lt_initial_directory("home", true, "/account/home"), "/account/home"));
  assert(!lt_initial_directory("inherit", false, "/account/home"));
  assert(!lt_initial_directory("home", false, NULL));
  assert(!strcmp(lt_initial_directory("/project", false, "/account/home"), "/project"));
  puts("PASS working directory desktop/CLI detection, home/inherit/explicit and missing-account fallback");
  same(lt_shell_launch(true, "tester", false, "/bin/zsh", "", false),
       (const char *const[]){"/usr/bin/login", "-flp", "tester", "/bin/bash",
         "--noprofile", "--norc", "-c", "exec -l -- \"$@\"", "letty-login",
         "/bin/zsh", NULL});
  same(lt_shell_launch(true, "tester", true, "/bin/zsh", "echo 'a b'", false),
       (const char *const[]){"/usr/bin/login", "-q", "-flp", "tester", "/bin/bash",
         "--noprofile", "--norc", "-c", "exec -l -- \"$@\"", "letty-login",
         "/bin/zsh", "-c", "echo 'a b'", NULL});
  same(lt_shell_launch(false, NULL, false, "/bin/zsh", "", false),
       (const char *const[]){"/bin/zsh", NULL});
  same(lt_shell_launch(false, NULL, false, "/bin/bash", "", true),
       (const char *const[]){"/bin/bash", "--posix", "-i", NULL});
  same(lt_shell_launch(false, NULL, false, "/bin/bash", "exit 7", true),
       (const char *const[]){"/bin/bash", "-c", "exit 7", NULL});
  same(lt_shell_launch(true, NULL, false, "/bin/zsh", "", false),
       (const char *const[]){"/bin/zsh", NULL});
  puts("PASS shell launch Darwin login/quiet, Linux non-login, commands and missing-account fallback");
}
