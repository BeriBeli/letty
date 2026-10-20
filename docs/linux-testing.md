# Linux acceptance checklist

Use a Linux host meeting the [kernel and library baseline](compatibility.md#linux-runtime-baseline). Distribution identity is not an acceptance criterion. Keep the same package's `build-info.json`, checksums, and actual results at every step. Record CI, target execution, and display/input acceptance separately.

The existing `tools/test-centos.sh` name and `el7` package suffix are historical identifiers, not distribution requirements.

## 1. Verify the package and basic compatibility

Copy the runtime tar.gz and outer SHA256SUMS into a user directory. Verify the outer digest, extract `letty-linux-x86_64-el7-<digest>.tar.gz`, and enter its directory. The outer manifest also lists source archives; if only the runtime was copied, verify its corresponding line separately. Then verify the extracted payload:

```bash
sha256sum -c SHA256SUMS
./tools/test-centos.sh probe >probe.log 2>&1
./tools/test-centos.sh core >core.log 2>&1
```

The probe checks libc open/fstat/pread, actual TTF/TTC directories, and dynamically loaded GUI libraries. Core checks include VT behavior and real PTY UTF-8 round trips. Keep failure logs before changing the environment; replacing glibc is not an installation step.

Baseline: x86_64, Linux 3.10+, glibc 2.17+, GTK 3.22.30+, GLib 2.56.1+, Cairo 1.15.12+. The probe opens no window; successful library loading does not validate GUI input.

## 2. Fonts and X11 window

Install Maple Mono Normal NL NF CN TTF files in `~/.local/share/fonts/` or `~/.fonts/` on the GUI host; use an existing `fc-cache -f` if available. nanoui scans those and system font directories. TTF/TTC is supported; CFF-only OTF is not.

```bash
fc-match 'Maple Mono Normal NL NF CN'
echo "$DISPLAY"
./tools/test-centos.sh gui 2>letty-stderr.log
```

Run within a working local or SSH-forwarded X11 display. Keep the first launch in the foreground. Check text, Paper colors, expose/repaint, resize, and window close. Fallback rendering alone does not prove Maple is selected: inspect both output and `fc-match`. Test background launch afterward. Fonts must be installed where the GUI process runs.

## 3. Terminal basics

Run this multilingual rendering fixture:

```bash
printf '中文 é Ω →\n\033[31mred\033[0m \033[1mbold\033[0m\n'
stty size
printf '\033[6n'
```

Check two-cell CJK, single-cell combining sequences, ANSI colors, cursor position, arrows, Backspace, Delete, Home/End, PageUp/PageDown, and F1–F12. `stty size` must follow resize. Test Ctrl-C against `sleep 60` and Ctrl-D to exit. Normally a pane closes after output drains and its child exits; `--hold` retains the final screen for diagnosis.

## 4. IME, selection, and clipboard

Using the normal system IME, test preedit, candidate positioning, candidate clicks, CJK commit, rapid typing, language switching, and focus away/back. Record `GTK_IM_MODULE`, `XMODIFIERS`, `LANG`, and `LC_CTYPE` as needed. UTF-8 rendering does not prove IME acceptance.

Test drag/multiline selection, double-click words, triple-click lines, and Ctrl+Shift+C. Ctrl+Shift+V reads asynchronously and targets the request's stable Session ID. Paste is bounded to about 1 MiB; a busy queue rejects explicitly. CRLF is normalized and control bytes pass through VT encoding. Test bracketed paste in the shell and vim/tmux; start multiline tests with harmless text.

## 5. vim / less / tmux

Check startup/exit and alternate-screen restoration with installed vim/less versions. Exercise tmux splits, mouse click/drag, wheel, resize, and detach/attach. Use `xterm-256color` terminfo. Validate only the GUI capabilities listed for the tested release; engine protocol support alone does not establish host integration.

## 6. Tabs, splits, history, and search

Use Ctrl+Shift+T/D/E to create four independent PTYs and run distinct commands. Ctrl+Tab changes tabs; Ctrl+Shift+] changes panes. Input must reach only the focused pane. Let a hidden tab produce output, return, and inspect its end. Closing one pane must leave the others running. After repeated creation/closure, inspect child processes, FDs, and memory.

Run the package's absolute `tools/workload.sh 100000` path to fill bounded history. Test wheel/Shift+wheel, Ctrl+Shift+F, text entry, Previous/Next, and incremental history search.

`layout.json` is saved on structural changes and exit. Restoration creates new shells/profile commands, not live processes or shell state. Use existing tmux when tasks must survive GUI or SSH disconnection.

## 7. Performance and disconnection

Follow [performance methodology](performance.md) against Konsole 2.10.5 on the same host with one/four independent sessions, identical bounded history, and equal workloads. No target memory advantage has been established.

Record SSH X11 disconnection, normal GUI close, display-session loss, and host reboot separately. There is no daemon; layout restoration does not preserve task processes.

## 8. Install, roll back, and collect failures

After all required checks pass, install the same tested package:

```bash
./tools/install-user.sh
~/.local/opt/letty/current/bin/letty
# Roll back after installing a newer version:
./tools/rollback-user.sh
```

Version directories are retained and system libraries are unchanged. Running from the extracted directory remains possible.

```bash
./tools/test-centos.sh collect letty-test-record
# If strace is available, capture a failing path:
strace -f -o letty-strace.log ./bin/letty --no-restore
```

Include the package digest, failing step, probe/core/stderr, display transport, IME environment, screenshots, and reproduction commands. Collection omits shell history and SSH credentials. Review traces/screenshots before sharing because they may contain work content.

## M0–M1: actions, tabs, and splits

1. In Ctrl+Shift+P, run `new_split:left` / `new_split:up`; check directional navigation and `goto_split:previous/next`. Missing neighbors must not change tabs.
2. Use Ctrl+Shift+Enter for zoom/restore. Compare `echo $$` and original ratios; run `equalize_splits`, `resize_split:right,20`, and divider dragging.
3. Rename a tab with CJK text and reorder it. Each tab must remember its pane. At 480×240, create eight tabs and navigate through overflow/palette; a ninth must be rejected.
4. During IME composition, arrows/Enter belong to the IME. Palette/rename text and Escape must not reach the shell; dismissing outside must not click an underlying close button.
5. Test v1 layout migration in a separate XDG directory. Restore new processes without overwriting the active user's session data.

Record failed actions, configuration, window dimensions, and collected logs. Local hidden checks do not replace actual display/font/mouse acceptance.

## M2: history and search

1. Run `seq 1 100000` within history budgets. Continued output must preserve a scrolled viewport. Test scrollbar drag/track, page/top/bottom actions, resize, and pruning.
2. Search repeated CJK, combining text, and soft wraps. Check visible hits, current color, counts, Enter/Shift+Enter, independent selection, and normal input after closing search.
3. In vim/less alternate screens, hide main-history scrolling and reject clear-screen; main history returns after exit.
4. Select-all respects the 1 MiB copy limit. Clear-screen preserves modes; `reset` clears VT modes without restarting the shell. Check `echo $$`.
5. Measure CPU/display responsiveness during large-history search and scrollbar dragging on the actual target.

## M3: menus, diagnostics, and close confirmation

1. Test terminal/tab context menus using mouse, arrows/Enter, Escape, and outside dismissal; placement must fit 480×240.
2. TUI mouse mode receives ordinary right-click; Shift+right-click opens Letty's menu. App button IDs are 1 left, 2 right, 3 middle.
3. Run sleep/vim/ssh across panes. Exercise pane/tab/other-tabs/window/WM close/quit. Cancel preserves every PID; confirmation closes only listed sessions. Natural exit during a dialog must not close a reused slot.
4. In isolated XDG configuration, Open Configuration must create nothing on cancel, create a sample on confirmation, and never overwrite existing files. Opener failure must offer the actual path.
5. Introduce an invalid value on line two and reload. Diagnostics show path, line, key, and cause while preserving configuration/PIDs. Fix and retry.

## M4: PRIMARY, paste, and links

1. Select and middle-paste into another X11 app; independently test CLIPBOARD with Ctrl+Shift+C/V and `copy-on-select = none`. In TUI mouse mode, Shift selects Letty's right/middle-click behavior.
2. Paste two lines without bracketed-paste mode. Cancel sends no bytes; approval targets the original session. Switching tabs or closing that session must not redirect delivery.
3. Test OSC 8 with `printf '\033]8;;https://example.com/real\033\\Link text\033]8;;\033\\\n'`. Ctrl-hover reveals the true URL and context-copy uses it. Soft-wrapped URLs remain complete and exclude adjacent CJK.
4. Ctrl-click uses xdg-open; failure offers copying and retry. Record which host opens the browser. `file`/`javascript` schemes do not execute.
5. In a local shell, `cd` into a fixture directory and print `README.md`, `./docs/a.md:3`, a directory and a binary file. Press Ctrl without moving the pointer: the path under it underlines immediately and clears on release (nanoui-18). Ctrl-click opens the in-app preview; directory/binary/missing files show explicit states. Inside `ssh`, `tmux` and an SSH profile the tooltip refuses and the click reaches the application. In `vim` with mouse enabled, Ctrl-click on a path sends no mouse report.

## M5: local directories, shell, and focus

1. Start Bash 4.2 with `shell-integration = detect`; preserve PROMPT_COMMAND, DEBUG trap, and prompt. Use the multilingual path fixture `mkdir -p '/tmp/带 空格'` then `cd '/tmp/带 空格'`; new tabs/splits inherit it. Explicit profile CWD wins. Check initial `--cwd` behavior separately. `none` starts normally without changing rc files.
2. Test Previous/Next Shell Prompt with output, resize, and pruning. Missing integration must report unavailability.
3. In a background tab run `sleep 2; false`: failure clears on focus. BEL leaves a marker. `printf '\033]9;4;1;42\007'` shows 42%; `printf '\033]9;4;0\007'` removes it.
4. `confirm-close-surface = true` can close a trusted idle prompt directly; busy/unknown sessions confirm. Cancel preserves processes. `always` includes idle prompts; `false` closes directly.
5. Enable `CSI ? 1004 h` in a test program. Window/tab/pane/search/palette focus changes must emit deduplicated, correctly targeted reports. Disabling the mode stops them. IME focus changes must not leave drag state or misroute text.
6. SSH profiles inject nothing remotely. Remote OSC 7 hostnames must not become local chdir arguments. Tab feedback works without notification services.

## M6: multiple windows and transactions

1. Ctrl+Shift+N creates a second window. Font zoom, menus, paste, and mode 1004 target the active window; closing A preserves B's PIDs.
2. With sleep in two windows, Quit shows one aggregate confirmation. Cancel keeps all sessions; Close Window lists only that window. The final terminal window exits unless Settings keeps the app open.
3. Successful reload updates all windows without changing PIDs. Removing a profile used by either window rejects the whole reload.
4. Eight-window/sixteen-PTY limits reject before creating orphan processes. Closed capacity can be reused.
5. Restart restores topology, titles, and dimensions into new PIDs. A second instance writes a separate PID state file. Late paste/dialog responses from a closed window must not affect another window.

All applicable target Linux, X11, IME, and native-service checks remain necessary. Cross-builds, static ABI checks, and local hidden windows are distinct evidence.
