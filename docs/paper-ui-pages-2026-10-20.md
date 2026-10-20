# Paper settings pages and collapsed workspace

Follow-up to [Paper UI fidelity](paper-ui-fidelity-2026-10-20.md), implementing the approved collapsed workspace and four Settings references.

- Compact workspace navigation uses folder icons, a quiet selected state and stacked bottom actions.
- A collapsed or empty document dock occupies zero width. macOS titlebar buttons expose File Preview and Commands; the existing menu, palette and shortcut routes remain available.
- Terminal groups startup, directories and history. Keyboard uses a searchable effective-binding list and a focused editor. Clipboard groups copy, paste and terminal access. Advanced uses source rows, diagnostics and disclosures.
- Settings scrollbars overlay content, appear on interaction and fade after idle. No persistent scrollbar track is reserved.

The reference images describe layout, not configuration defaults. The implementation retains actual key bindings, all supported settings and platform capabilities. Offscreen captures omit native window decorations. Native titlebar controls are separately exercised in an owned hidden AppKit window. Fixtures use private files and owned PTYs.

## Actual captures

- [Terminal](assets/paper-pages-2026-10-20/terminal.png)
- [Keyboard](assets/paper-pages-2026-10-20/keyboard.png)
- [Clipboard](assets/paper-pages-2026-10-20/clipboard.png)
- [Advanced](assets/paper-pages-2026-10-20/advanced.png)
- [Collapsed workspace, native renderer](assets/paper-pages-2026-10-20/workspace-collapsed-native.png)
- [Expanded workspace, native renderer](assets/paper-pages-2026-10-20/workspace-expanded-native.png)

Workspace captures retain synthetic fixture PTY output and an intentional earlier composition-guard notice. They verify layout, not a staged demonstration. The collapsed screenshot was compared with the approved reference for icon rail width, selected state, bottom actions and recovered terminal width.

## Verification

Final source: `bd95020073016620b07f309611b085c3843ac4428d324d177b4e2c24ebccab04`.

The independent Settings suite passes 80 assertions. Native UI passes 778 checks; portable UI passes 774. Both host builds pass 213 unit, 49 core, 9 replay, 24 N2, 56 protocol, 21 boundary and 13 graphics checks. The Linux cross-build and all nine ELF audits pass with the existing baseline/GLIBC 2.17 contract. Target Linux execution, X11/VDI and native IME acceptance remain separate. Full results are recorded in [evidence.json](assets/paper-pages-2026-10-20/evidence.json).

Local macOS preview: `dist/paper-pages-bd9502007301/Letty.app`. This is a local developer preview, not a new distribution release acceptance.

