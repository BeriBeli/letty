# Historical documentation and evidence

Use the [current documentation](../README.md) for the active Letty runtime.
These guides, plans and receipts describe their recorded implementation and
acceptance scope. Older tool names, executable names and source paths are
historical references; some discontinued files are available only from Git or
the [cleanup recovery archive](cleanup-2026-10-24.md).

Existing receipt JSON, measurements, screenshots, release documents and recovery
packages remain at their recorded paths with their original hashes. This index
organizes those materials without re-certifying them for the current source.

## Preceding user and integration guides

- [Configuration and customization (preceding implementation)](configuration-pre-runtime.md)
- [Settings (preceding implementation)](settings-pre-runtime.md)
- [macOS native development preview (preceding implementation)](macos-preview-pre-runtime.md)
- [Linux acceptance checklist (preceding implementation)](linux-testing-pre-runtime.md)
- [System requirements and compatibility (preceding implementation)](compatibility-pre-runtime.md)
- [GitHub releases (preceding implementation)](github-releases-pre-runtime.md)
- [Local file and Markdown previews](../file-markdown-preview.md)
- [File and Markdown preview implementation plan](../file-markdown-preview-plan.md)
- [File and Markdown preview integration contract](../file-markdown-preview-integration.md)
- [nanoui Settings window plan](../settings-window-plan.md)
- [Settings host contract](../settings-host-contract.md)
- [Settings host integration (legacy link)](../settings-host-integration.md)
- [Workspace sidebar and navigation-mode plan](../sidebar-navigation-plan.md)
- [Workspace sidebar validation](../sidebar-validation.md)
- [Tab and window titles](../terminal-titles.md)
- [Paper controls on nanoui kit](../kit-ui.md)
- [Kero UI port](../rex-ui.md)
- [Paper theme provenance](../theme-source.md)
- [Linux acceptance checklist (legacy link)](../centos-testing.md)
- [M9 Kitty image capabilities and acceptance boundaries](../m9-capabilities.md)
- [M10 capabilities and acceptance boundaries](../m10-capabilities.md)
- [M11 capabilities and acceptance boundaries](../m11-capabilities.md)

## Releases and validation

- [Letty 0.2.3 fixes Linux shortcuts and local csh/tcsh directory titles, improves](../releases/0.2.3.md)
- [Letty 0.2.2 improves Linux input, settings persistence, application icons and](../releases/0.2.2.md)
- [Letty 0.2.1 improves native Markdown previews with structured blockquotes,](../releases/0.2.1.md)
- [Letty 0.2.0 updates the terminal engine and UI toolkit, adds local document editing,](../releases/0.2.0.md)
- [Validation history](../validation.md)
- [M8 frozen integration release](../m8-release.md)
- [M9–M11, Settings, and sidebar integration release](../m9-m11-release.md)
- [M9–M11 historical handoff](../handoff-m9-m11.md)
- [C VT baseline recovery](../c-vt-recovery.md)
- [Letty @VERSION@ for Linux x86_64](../runtime-package.md)
- [Settings validation — 2026-10-20](../settings-validation-2026-10-20.md)
- [Dynamic workspaces and file workspaces — 2026-10-20](../dynamic-workspaces-2026-10-20.md)
- [Workspace navigation and preview validation — 2026-10-20](../workspace-navigation-validation-2026-10-20.md)
- [UI review fixes: 2026-10-20](../ui-review-fixes-validation-2026-10-20.md)
- [Ghostty and nanoui upgrade — 2026-10-21](../dependency-upgrade-2026-10-21.md)
- [nanoui fork pin and patch review — 2026-10-23](../nanoui-fork-patch-review-2026-10-23.md)
- [Letty UI audit and repairs — 2026-10-24](../terminal-ui-audit-2026-10-24.md)
- [Rendered Markdown width repair, 2026-10-24](../markdown-width-2026-10-24.md)

## Measurements

- [Performance measurement methodology](../performance.md)
- [Bounded native performance measurements (2026-10-19)](../performance-native-2026-10-19.md)
- [Native Zig migration performance comparison (2026-10-20)](../performance-zig-migration-2026-10-20.md)
- [M8 font and CPU rendering measurements](../performance-m8-2026-10-20.md)
- [M9–M11 frozen performance review (2026-10-20)](../performance-m9-m11-2026-10-20.md)
- [Portable raster improvements, 2026-10-22](../performance-cpu-raster-2026-10-22.md)
- [Memory breakdown and cache recovery, 2026-10-22](../performance-memory-2026-10-22.md)
- [macOS window latency measurements (2026-10-20)](../window-latency-2026-10-20.md)

## Plans and design records

- [Terminal development plan: macOS development and baseline Linux runtime](../../terminal-development-plan.md)
- [Paper Reading Room fidelity review](../../design-qa.md)
- [Ghostty feature gap plan: M0–M5](../ghostty-nanoui-gap-plan.md)
- [Follow-up roadmap: M6–M19](../ghostty-nanoui-next-plan.md)
- [Native Zig VT migration plan and history](../native-zig-vt-adaptation-plan.md)
- [Paper UI refresh](../paper-ui-refresh-2026-10-20.md)
- [Paper UI fidelity follow-up](../paper-ui-fidelity-2026-10-20.md)
- [Paper settings pages and collapsed workspace](../paper-ui-pages-2026-10-20.md)

## Structured receipts and source data

- [Native migration receipt](../native-migration-acceptance.json) and [native release receipt](../native-release-acceptance.json).
- [M7](../m7-native-release-acceptance.json), [M8](../m8-native-release-acceptance.json) and [M9–M11](../m9-m11-native-release-acceptance.json) receipts.
- [Recorded milestones](../milestones.json) and [performance measurements](../performance-data/).
- [Native performance JSON](../performance-native-2026-10-19.json) and [window latency data](../window-latency-data/).
- [Source adaptation inventory](../reference-source-inventory.json).
- Preceding [text configuration example](config.example.pre-runtime) and [JSON example](config.example.json).
- [Documentation/file cleanup](cleanup-2026-10-24.md) and [recovery manifest](cleanup-2026-10-24.json).

The runtime-package document is a template consumed by historical packaging
helpers; its presence does not enable the current release workflow. Historical
counts and claims must be read with their source/environment qualifiers.
