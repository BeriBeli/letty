# Settings validation — 2026-10-20

Status: development verification passed for frozen source `8e6a2f5691b5b59a0a87afe735b986d0db0050b79ce1f762cd1678b95ff4e107`. The matching native release gate passed. Target-desktop limitations remain below.

The standalone harness uses Zig 0.17.0 and the locked nanoui sources. All test configuration files live under a private `/tmp/letty-settings-*` directory. No user configuration, terminal window, system clipboard, or existing PTY is used.

| Check | Recorded result |
| --- | --- |
| macOS native Metal | 61 standalone checks passed outside the filesystem sandbox, including the English UI and system-font fallback. |
| macOS portable | The same 61 standalone checks passed. |
| x86_64 Linux 3.10, baseline CPU | Settings harness and the complete application cross-build passed. |
| Linux ELF audit | All 9 application ELF files passed the common audit with highest GLIBC requirement 2.17. The isolated harness also passed: `/lib64/ld-linux-x86-64.so.2`, libc/loader/libpthread only. Audit is static, not target execution. |
| Screenshots | Actual English light and 480×360 dark/sidebar offscreen layouts reviewed; images are in `docs/images/settings/`. Actual Settings-window snapshots from the application fixture were also reviewed. |
| Real application | All 18 assertions passed on native and portable against the same frozen source: actual Save, two real PTYs, invalid-save preservation, singleton, default/ignore/custom shortcuts, reopen, unsaved Quit guard, CLI overrides during navigation changes, Git/port flag persistence, and stable preview font providers. Portable's complete UI suite passed 671 assertions, including these 18. |
| Shared input isolation | Five M11 regressions passed: bytes and paste reject before enqueue, recording blocks global app actions, queued bytes reject again at execution, and the pending global app action is dropped before creating a PTY. |
| GTK/X11/native IME | Not run on a target Linux desktop. Simulated composition events do not substitute for a native IME test. |

Covered cases include unchanged zero writes, include precedence, retained comments/duplicate keys/CRLF, host preflight rejection, root and included-source conflicts, post-preflight reservation rollback, range diagnostics, JSON preservation, missing-file exclusive creation, symlink/ACL/xattr/mode preservation, navigation persistence/default reset, parser-safe shortcut recording and all-default roundtrips. Long existing values remain intact beyond form capacity and can be explicitly reset. Quoted commands are encoded only when the real shared parser roundtrips them exactly.

UI checks cover category layout, config-key search, Tab focus, IME composition Escape, unsaved-close confirmation, narrow footer geometry, system font independence, navigation search/layout, disabled top policy, canonical action search, explicit discard before reloading, applied-vs-file values, CLI override explanations, and bounded local theme filtering with origins.

Parser inputs are frozen as they are read. Both the draft's original sources and a newly selected theme's candidate sources are checked after host preflight. Tests cover an optional include appearing and an include symlink being retargeted without changing its values.

Conditional-theme checks verify that dark-mode inherited ligatures are displayed correctly, enabling them creates a real root override, and an existing draft survives an appearance event. The application fixture also checks that the verified preview font matches the frame's font provider, avoiding repeated font-cache resets; this extends the final application batch to 18 assertions.

Reproduce the portable suite from the repository root:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" zig build \
  --build-file tools/settings-check/build.zig run -Dportable=true \
  --cache-dir "$PWD/.cache/settings-zig"
```

The main integrator completed the common source freeze, full builds, application checks, performance review, and matching native release gate. Records are `.cache/verification/native-feature-SETTINGS.json`, `native-portable-ui.json`, `n3-linux-abi.json`, and `native-release-gate.json`. Final archives are produced by the common packaging workflow so the Settings feature ships in the same tested application.

Run the application fixture in a temporary XDG environment using `--nanoui-hidden --feature-checks=SETTINGS`. It creates its own configuration and two PTYs. The completed runs include the shared global-action guard while Settings owns focus or records a shortcut. GTK/X11 and native OS IME acceptance remain explicitly pending.
