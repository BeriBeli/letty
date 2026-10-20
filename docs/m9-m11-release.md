# M9–M11, Settings, and sidebar integration release

This historical batch retains Zig 0.17.0, nanoui/native Zig VT, Maple/Paper, and baseline Linux 3.10/glibc 2.17. M8 and the C recovery archive remain separate. Frozen source: `8e6a2f5691b5b59a0a87afe735b986d0db0050b79ce1f762cd1678b95ff4e107`; passed local gate SHA256: `84750e7b0b172465d849f53a2061b773c76719c7e59cdc3d5c59137baea59a5e`. Checks passed: 190 model, 46 core, 675 native UI, 671 portable UI, and nine Linux ELF audits with maximum GLIBC_2.17.

M9 checks real Kitty protocol→Context→CPU/Metal readback, fixes indexed PNG validation and bilinear source-crop bleed. M10 covers theme preview/save transactions, unknown-shell read-only drop preview, generation-bound OSC 52 approval, and Inspector text opt-in/erasure. M11 integrates two-phase hotkey registration, hidden Quick Terminal, owned AX trees, and IME rejection.

[Settings](settings-window.md) is an independent English system-font window, Cmd+, / Ctrl+,. Save/Reload share all-window transactions. Failure preserves draft/runtime configuration; dirty settings precede Quit. New-session parameters do not restart PTYs.

The [sidebar](sidebar-navigation-plan.md) reuses Tab/split tree/Session with pinned groups, within-group reordering, collapse/width/scroll, keyboard, and AX. All pane/search/drop/IME/AX geometry shares the content rectangle. Git/ports default off; explicit enablement uses bounded event-driven workers. Exit/fatal/disable/close revokes collection resources.

M9/M10/M11 each retain distinct feature entry points/acceptance sections while sharing one frozen binary. Settings/Sidebar are also recorded independently. Review packages reference the same binary digest rather than mixing old M8/source counts. `feature-acceptance.json` records actual native/portable assertions/components; `native-release-gate.json` binds source/binaries/raw logs/stability/performance.

Tests use hidden owned windows, private Tester input/clipboard, temporary configurations, and private PTYs. Real OS hotkeys, VoiceOver/Orca, system CJK IME, native drag/drop, GTK/X11 presentation, and target Linux execution remain pending. macOS is ad-hoc signed/unnotarized. Cross-builds/static ABI do not replace execution.

Capability matrices: [M9](m9-capabilities.md), [M10](m10-capabilities.md), [M11](m11-capabilities.md), [configuration](configuration.md). M12–M19 daemon/extensions/AI work is not started by this delivery.

Native feature counts (complete suites, including previous regressions): M9 45 (40 image, five atlas), M10 102, M11 63, Sidebar 81, Settings 18. Components include nineteen sampler, seventeen config-save, 35 AppKit AX, ten AX transaction, nineteen AX adapter, 26 provider, nine real-login PTY, and 61 native/61 portable Settings-form checks.

256 lifecycle rounds reaped 257 children; twenty layout-startup restores, twenty real-login checks, fifteen configuration CLI, and six appearance checks passed. 288 CPU full/damage pixel comparisons matched; CPU/Metal Kitty scene hashes matched. Sixteen nanoui patches replayed from locked upstream; 48 files matched byte-for-byte. Framework Linux/Windows cross-builds passed.

Eighteen performance runs against retained M8 were reviewed sample-by-sample with no 1.10 median-ratio warning. Frame-build medians for 1/4/16 panes: 337/551/638 µs versus M8 337/557/649. Peak RSS medians rose less than 0.5%; unstripped binary size rose 15.53%. Scope is Tester construction, not input-to-display or sidebar-drag latency. See [performance](performance-m9-m11-2026-10-20.md).

Receipt: [m9-m11-native-release-acceptance.json](m9-m11-native-release-acceptance.json). macOS archive: `dist/Letty-macos-arm64-native-zig-8e6a2f5691b5.zip`. Linux/source filenames follow authored-source digests; final names/sizes/SHA256 are in `dist/release-8e6a2f5691b5.json`. Review archives include `dist/letty-M9-review-8e6a2f5691b5.tar.gz` and M10/M11 equivalents; complete evidence is `dist/letty-feature-evidence-8e6a2f5691b5.tar.gz`. M8 versioned binaries/source/receipts remain unchanged.
