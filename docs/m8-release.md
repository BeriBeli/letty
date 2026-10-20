# M8 frozen integration release

This historical release uses Zig 0.17.0, nanoui, and native Zig VT. M8 covers shaping/fallback/ligature control on the fixed VT grid and CPU damage rendering. Window-latency fixes and integrated later work remain included; their presence does not certify every target-platform M9–M11 behavior.

## Use

Read `$XDG_CONFIG_HOME/letty/config`, or `~/.config/letty/config` without XDG:

```ini
font-family = Maple Mono Normal NL NF CN
theme = paper
```

Cmd+Shift+P / Ctrl+Shift+P opens configuration/reload/themes/tab/split actions. Theme/font reload preserves PTYs. Install fonts on the GUI host; ligature availability depends on the font variant. Titles prefer program OSC, then CWD; zsh/bash integrate automatically and csh/tcsh require [manual loading](terminal-titles.md).

## Recorded local checks

- Native macOS: 110 model, 46 core, 526 complete UI checks.
- Portable macOS: same model/core, 522 UI; four Metal texture-ownership checks are native-only.
- CPU damage: 1/4/16 panes, eight stages × twelve frames, 288 pixel comparisons.
- Protocol: fixed replay/golden including 596 splits; thirteen actual graphics Context boundary checks.
- Configuration: fifteen CLI and seventeen actual-file checks, including empty/nonempty ACLs, xattrs, concurrency, and symlinks.
- nanoui: fifteen patches replayed from the locked archive; 46 affected files matched byte-for-byte.

Recorded later-feature checks include graphics/OSC 52/Inspector/themes/drops/accessibility routing. OSC 52 write defaults deny, read is unsupported, and graphics defaults off. Owned in-process NSView/adapter checks do not replace native drag gestures or screen readers.

## Linux acceptance

From the extracted package:

```sh
tools/test-centos.sh probe
tools/test-centos.sh core
tools/test-centos.sh gui
```

The helper's historical name imposes no distribution requirement. GUI requires DISPLAY and GTK 3. Check fonts, CJK IME, default CWD, titles, platform bindings, splits/reload, then TUIs/SSH. Collect failures with `tools/test-centos.sh collect`; follow the [Linux checklist](linux-testing.md).

The static target is baseline x86_64/Linux 3.10/glibc 2.17; GUI-library requirements are in [compatibility](compatibility.md). Target execution, GTK/X11 presentation, IME, VoiceOver/Orca, real drag/drop, and multi-monitor hotkeys remain pending. macOS is ad-hoc signed and unnotarized.

See [performance](performance-m8-2026-10-20.md) and packaged `native-release-gate.json`. Only passed evidence matching the corresponding frozen source certifies that development package.
