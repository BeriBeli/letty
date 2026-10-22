# Tab and window titles

The launch profile name (Local by default) identifies a launch configuration; it is no longer the automatic tab title.

- Manual tab names take precedence. Clearing a name restores automatic titles.
- Automatic titles use OSC 0/2 from the tab's last-focused pane.
- zsh/bash integration sends directory titles at prompts and command titles during execution. Programs may override titles using OSC.
- Before a terminal title arrives, use the reported directory or initial command/shell name. HOME displays as `~`.
- Background-pane title changes update the tab bar; long titles truncate at complete UTF-8 boundaries.

## csh / tcsh

Directly launched local `csh` and `tcsh` sessions default to their current directory,
including after `cd`, without editing startup files or loading hooks. HOME displays
as `~`; other paths display in full. Letty reads the foreground shell's kernel
working directory after PTY output and coalesces bursts to at most five queries per
second. It creates no idle polling timer and performs no directory query during
rendering or tab switching. Foreground jobs do not replace the shell directory.
Explicit launch commands, including SSH profiles, do not enable this fallback.

An OSC 7 report takes ownership of directory tracking for the rest of the session,
including when its remote or invalid path clears local directory inheritance.
Application OSC 0/2 titles and manual tab names retain their normal precedence.
Kernel paths are physical paths; optional shell hooks can report logical paths
and command titles. Directory discovery does not provide trusted-idle semantics.

Where `csh` resolves to tcsh, the title integration uses `precmd` / `postcmd` for directory/command titles and OSC 7 directory reports. It preserves existing aliases and does not change the prompt, HOME, or launch directory. It does not provide full OSC 133 command boundaries or trusted-idle semantics.

**Optional command-title hooks require manual sourcing; they are not injected automatically.** New Letty versions expose `LETTY_SHELL_DIR` to all shells. Add this after aliases in `~/.tcshrc` or `~/.cshrc`; if `~/.login` redefines those aliases, source afterward:

```tcsh
if ($?LETTY_SHELL_DIR) then
    source "$LETTY_SHELL_DIR/tcsh/hooks.tcsh"
endif
```

The same source command works in an open shell. Older sessions must restart under a newer Letty or explicitly point `LETTY_SHELL_DIR` at installed `share/letty/shell-integration` (macOS: `Contents/Resources/shell-integration`).

If kernel directory discovery is unavailable and no hooks report a directory or
title, the launch name such as `csh`/`tcsh` remains visible rather than Local.
Traditional BSD csh lacks tcsh's special aliases; the script detects and skips it.

Ghostty's own documented [shell integration](https://ghostty.org/docs/features/shell-integration) does not include automatic csh/tcsh integration in the referenced implementation. Letty reuses OSC-title and focused-pane precedence; tcsh hooks are its own implementation.

## Validation

```sh
python3 tools/verify-shell-titles.py
```

The script uses isolated HOME directories and real PTYs for zsh/bash/csh/tcsh: CJK/spaced directories, running commands, OSC 2 override, exit status, existing aliases, repeated loading, and control filtering. It does not edit user startup files. macOS `/bin/csh` and `/bin/tcsh` resolve to the same tcsh implementation; target Linux execution requires separate acceptance.

`tools/verify-ui.py` also exercises an owned csh/tcsh PTY with a private HOME and no
hooks: initial directory, `cd`, tab rename/reset, foreground-job exclusion, idle
timer removal, and OSC 7 precedence. Install csh or tcsh to run that case; Linux CI
installs tcsh explicitly. A local cross-build does not establish Linux execution.
