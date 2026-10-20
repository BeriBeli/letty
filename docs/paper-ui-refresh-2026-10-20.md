# Paper UI refresh

Implemented and verified on 2026-10-20.

## Interface

- Settings uses a category sidebar with search and outline icons, grouped form rows, switches, explicit choice lists, and a separate preview at widths of 1040 px or more. Smaller windows retain the preview inside the scrolling form and keep the save footer visible.
- Top workspace tabs use a muted accent selection, folder icons, and close controls at the trailing edge. Overflow and stable-ID reordering remain available.
- Sidebar workspaces show a title and available directory. Idle single-pane workspaces omit the status row; progress, attention, split, Git and port details remain available when applicable. Pin/close controls appear on hover or the focused active row.
- The document header combines tabs, collapse, a selected **Source view** (`</>`) toggle, search and **More document actions**. More reveals path input, copy, refresh, external opening and PNG controls. Status sits below the reading area.
- Outline icons come from pinned Lucide 0.468.0 SVGs. Both renderers use the same embedded rasterizations. See [asset provenance and regeneration](../src/ui_icons/README.md). Packaging includes the upstream license.

The existing session limits, terminal colors, configuration save checks, native Zig VT integration and deferred ownership checks are preserved. The new settings choice-list state participates in accessibility generation checks. Collapsed document actions remove their accessibility controls; keyboard Enter and native accessibility activation use the same source toggle and More actions.

## Validation

Tested source identity: `8962bd71085356ad003937c605a0e7b6ff09607097abfceb11b1d26bf13c432d`.

| Check | Native macOS | Portable renderer on macOS |
|---|---:|---:|
| Unit | 213 | 213 |
| Core, including owned PTY child | 49 | 49 |
| Full hidden UI | 765 | 761 |
| VT replay | 9 | 9 |
| N2 replay | 24 | 24 |
| Protocol fixtures | 56 | 56 |
| VT boundary | 21 | 21 |
| Graphics boundary | 13 | 13 |

The final standalone Settings fixture also passed 61 checks. The preview component passed 68 checks during implementation; the final application preview suite passed 80 assertions within each full UI run, including source-toggle keyboard activation, selected state, accessible More expansion/collapse, IME isolation, private clipboard copying, watcher updates, document limits and PTY input isolation.

Linux cross-compilation and the ELF audit passed for all nine delivery executables, retaining `x86_64-linux.3.10-gnu.2.17`, baseline CPU, ReleaseSafe and VT SIMD disabled. This is static ABI evidence, not execution on a target Linux desktop.

Build and test stages were run serially for each renderer. After permission-review timeouts, native build stages and individual suites were invoked separately using the existing verification helpers; the final build manifests and all sixteen suite records match the source identity above. Hidden UI tests use private clipboard/configuration fixtures and owned children. Existing release receipts and recovery packages were not repurposed.

[Evidence and screenshot hashes](assets/paper-refresh-2026-10-20/evidence.json) preserve the current results. Real target Linux/X11/VDI, native IME candidates and screen-reader acceptance remain separate. Portable emoji rendering still depends on available fonts; the fixture's ZWJ emoji can show missing glyphs.

## Actual rendered screenshots

- [Settings, three columns](assets/paper-refresh-2026-10-20/settings-native.png)
- [Settings, narrow dark layout](assets/paper-refresh-2026-10-20/settings-narrow-native.png)
- [Top workspace tabs](assets/paper-refresh-2026-10-20/tabs-native.png)
- [Workspace sidebar](assets/paper-refresh-2026-10-20/sidebar-native.png)
- [Document preview with top tabs](assets/paper-refresh-2026-10-20/workspace-native.png)
- [Narrow sidebar and preview, native](assets/paper-refresh-2026-10-20/preview-narrow-native.png)
- [Narrow sidebar and preview, portable](assets/paper-refresh-2026-10-20/preview-narrow-portable.png)

These are real offscreen application/Settings fixtures. Their shell commands, document names and composition-guard notices are test data.

## Local preview package

Use the current verified native binary without overwriting an existing bundle:

```sh
python3 tools/package-macos.py --local-preview \
  --output-dir=dist/paper-refresh-8962bd710853
```

This produces an ad-hoc signed developer preview. It does not claim notarization or the distribution release gate.
