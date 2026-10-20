# Documentation

All maintained project documentation is in English. Linux support is defined by the kernel, CPU, and library baseline in [system requirements](compatibility.md). Commands, artifact names, multilingual test fixtures, and historical evidence retain their original identities.

## Getting started

- [Project overview and build](../README.md)
- [System requirements](compatibility.md)
- [Linux acceptance checklist](linux-testing.md)
- [macOS development preview](macos-preview.md)
- [Configuration and shortcuts](configuration.md)
- [Terminal/window titles](terminal-titles.md)
- [Paper theme provenance](theme-source.md)
- [Paper UI refresh and validation](paper-ui-refresh-2026-10-20.md)
- [Application icon assets](../assets/icons/README.md)

## Features and integration

- [Architecture and ownership](architecture.md)
- [File/Markdown preview](file-markdown-preview.md), [plan](file-markdown-preview-plan.md), [integration](file-markdown-preview-integration.md)
- [Settings](settings-window.md), [plan](settings-window-plan.md), [host contract](settings-host-contract.md)
- [Sidebar plan](sidebar-navigation-plan.md), [validation](sidebar-validation.md), [metadata providers](../src/navigation/providers/README.md)
- [M9 graphics](m9-capabilities.md), [M10 desktop features](m10-capabilities.md), [M11 system integration](m11-capabilities.md)

## Releases and validation

Receipts, logs, JSON data, screenshots, and archives describe their recorded source/environment. Their hashes remain historical evidence; documentation edits do not rerun or certify a release gate.

- [Validation history](validation.md)
- [GitHub CD and release artifacts](github-releases.md)
- [M8 frozen release](m8-release.md)
- [M9–M11 integration](m9-m11-release.md), [handoff](handoff-m9-m11.md)
- [Settings validation](settings-validation-2026-10-20.md)
- [Dynamic workspaces, file workspaces and validation](dynamic-workspaces-2026-10-20.md)
- [Workspace navigation and preview validation](workspace-navigation-validation-2026-10-20.md)
- [UI review fixes and final validation](ui-review-fixes-validation-2026-10-20.md)
- [C VT recovery](c-vt-recovery.md)
- [Isolated native VT probe](../tools/native-vt-probe/README.md)

## Performance

- [Measurement methodology](performance.md)
- [Native measurements, 2026-10-19](performance-native-2026-10-19.md)
- [C-to-Zig migration/native comparisons](performance-zig-migration-2026-10-20.md)
- [M8 font/CPU rendering](performance-m8-2026-10-20.md)
- [M9–M11 frozen comparison](performance-m9-m11-2026-10-20.md)
- [macOS window latency](window-latency-2026-10-20.md)

## Development plans

Plans retain decisions and acceptance boundaries; release records identify what was actually measured.

- [Original terminal development plan](../terminal-development-plan.md)
- [M0–M5 feature gap plan](ghostty-nanoui-gap-plan.md)
- [M6–M19 follow-up plan](ghostty-nanoui-next-plan.md)
- [Native Zig VT migration](native-zig-vt-adaptation-plan.md)

- [Paper UI fidelity follow-up](paper-ui-fidelity-2026-10-20.md): simplified automatic preview, closer layout proportions, and document status/copy icons.

- [Paper settings pages and collapsed workspace](paper-ui-pages-2026-10-20.md) — four redesigned Settings pages, transient scrollbars and native titlebar controls.
