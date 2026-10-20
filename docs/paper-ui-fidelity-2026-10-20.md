# Paper UI fidelity follow-up

This follow-up responds to the approved design comparison and the subsequent requests to simplify preview controls and replace the read-only label with an icon. The earlier refresh receipt remains unchanged and certifies only its recorded source.

## Changes

- Settings restores the intended three-column proportions, embeds search in one outlined field, and shows font/theme selectors plus compact numeric steppers. Detailed cell, system-theme and sidebar options remain searchable behind disclosures. Validation opens a hidden field before focusing it.
- Manual **Reload from disk** and **Update preview** controls are removed. Appearance drafts update a local sample after a 120 ms pause; incomplete values keep the last valid sample. A single sun/moon icon switches the configured appearance branch. Only Save and apply writes and publishes the draft.
- Document chrome places collapse and the filename at the leading edge. Reading margins, title hierarchy and code containers are revised. Code-copy actions use owned bytes and current document revisions through pointer, keyboard and accessibility activation.
- A pinned Lucide lock icon replaces the read-only footer text. Hover and assistive technology expose “Read-only document.”
- Top tabs include available session directories, sanitized with the existing navigation helper. Sidebar command hints remain visible.

## Review and evidence

[Design comparison and resolution log](../design-qa.md).

- [Settings](assets/paper-fidelity-2026-10-20/settings-native.png)
- [Canonical README preview](assets/paper-fidelity-2026-10-20/preview-native.png)
- [Integrated workspace](assets/paper-fidelity-2026-10-20/workspace-native.png)
- [Verification receipt](assets/paper-fidelity-2026-10-20/evidence.json)

The images are native rendered fixtures. Their content is controlled for comparison; operating-system window frames are outside offscreen captures. Fixed light/dark theme branches can have identical colors, and the preview reports an unavailable font rather than silently implying that it is installed.

Final verification: 771 native UI checks and 767 portable UI checks passed, alongside both renderers' unit/core/VT suites. Standalone Settings and Preview passed 67 and 71 checks. Linux cross-build and static ABI checks passed for all nine binaries; this does not establish target Linux/X11/VDI runtime acceptance. Exact source and executable identities are recorded in the linked receipt.

The local macOS preview is packaged in `dist/paper-fidelity-655107f67682/Letty.app`, with a versioned ZIP in the same directory. Previous preview bundles remain unchanged.
