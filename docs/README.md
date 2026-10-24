# Letty documentation

Start with the [project overview](../README.md), [implementation scope](implementation-scope.md)
and [architecture](architecture.md). Letty is an independent Zig terminal
application using nanoui and Ghostty's native `ghostty-vt` module.

## Using the current application

- [Configuration and shortcuts](configuration.md): the `config` file, supported settings, themes and bindings.
- [Settings](settings-window.md): immediate validation, persistence and reload.
- [File and Markdown documents](file-markdown-documents.md): file workspaces, side previews, editing and automatic saves.
- [Git/SVN Changes](svn-backend.md): discovery, local diffs and backend limits.
- [System requirements](compatibility.md): the Linux kernel, CPU and library baseline.
- [macOS development preview](macos-preview.md): build, package, launch and logs.
- [Linux acceptance checklist](linux-testing.md): current binaries and real X11/VDI/IME acceptance.

## Developing Letty

- [Contributing](../CONTRIBUTING.md) and [agent guide](../AGENTS.md).
- [Architecture and ownership](architecture.md) and [implementation scope](implementation-scope.md).
- [Shared nanoui integration](nanoui-integration.md) and [active dependency patches](../patches/README.md).
- [Build, verification and asset tools](../tools/README.md).
- [CI and release status](github-releases.md).
- [Third-party notices](../THIRD_PARTY_NOTICES.md), [UI asset sources](../src/ui_icons/README.md) and [application icon](../assets/icons/README.md).
- [Reference-source inventory](reference-source-inventory.json): attribution and adaptation coverage, not a feature-parity requirement.

<a id="releases-and-validation"></a>

## History and evidence

The [historical index](archive/README.md) groups preceding feature guides,
plans, releases, measurements and source-bound receipts. Recorded paths and
hashes retain their original identity. Those records certify their recorded
source, not the current application.

Recent implementation records include the [UI audit](terminal-ui-audit-2026-10-24.md),
[Markdown width repair](markdown-width-2026-10-24.md),
[nanoui fork review](nanoui-fork-patch-review-2026-10-23.md), and
[documentation and file cleanup](archive/cleanup-2026-10-24.md).

Maintained documentation is in English. Distribution names do not define Linux
support; use the versions in the compatibility guide.
