# Paper Reading Room fidelity review

Status: passed for the scoped native content-layout review and automated verification. This is not a claim of pixel-identical operating-system window chrome.

## Basis

Approved reference images are the Settings, top-tab, sidebar, and final single-toggle document-header mockups in `/Users/beribeli/.codex/generated_images/01a1586e-b809-7131-9d79-2a6c7979a5f3/`. Primary references: `exec-fe9b82bd-1529-49da-87e7-723ee42e6101.png` and `exec-4166240e-de0c-41c4-868c-3fbbf8661d26.png`.

The implementation is the existing native Zig/nanoui application. Screenshots are actual rendered fixtures, not generated mockups. Settings is captured at 1100×760 logical points, 2× density, with 14-point type and the Paper theme. The canonical document uses the reference's README content at 368×770 logical points, 2× density, matching the reference panel's approximate physical width. Whole-window and narrow captures cover integration and clipping. Native titlebar decorations are outside these offscreen content captures.

## Findings and changes

| Finding | Severity | Resolution |
|---|---|---|
| Settings middle column dominated the window and the sample was cramped | P2 | Category/preview columns are 220/330 points; the form takes the remaining width |
| Long numeric fields, repeated font/theme controls, and detailed settings obscured common fields | P2 | Compact steppers, selectors with custom input, and searchable disclosures; both padding rows fit the initial wide view |
| Search icon sat outside its input | P2 | One outlined search container with an embedded icon |
| Manual Reload/Update Preview controls and a text Light button added unnecessary operations | P2 | Removed on user feedback; edits update the sample after a short pause; one sun/moon icon selects its appearance |
| Preview header centered the filename and placed collapse after it | P2 | Leading collapse and document icon, left-aligned filename, trailing Source/Search/More |
| Document content was tight and fenced code lacked a usable copy action | P2 | Larger title, consistent reading margins, padded code containers, real pointer/keyboard/accessibility copy |
| Read-only footer text occupied unnecessary space | P2 | Lock icon with hover text and an accessibility label, as requested |
| Tab paths and the sidebar command shortcut were missing | P2 | Available session directories appear in top tabs; sidebar command hint restored |

Existing terminal colors, configured theme branches, native font shaping, multi-document close controls and window decorations remain functional constraints. Fixed light/dark themes may intentionally have the same preview colors. A missing configured font is disclosed instead of pretending the sample uses it.

## Evidence

Latest captures and verification receipt: `docs/assets/paper-fidelity-2026-10-20/`.
The previous `paper-refresh-2026-10-20` receipt and preview bundle remain historical evidence for their own recorded source.

Final source: `655107f676826e31c7ce1ee000d7c4aaa0f90ad2b6683111859666e2c425058c`.
Native UI: 771 checks passed. Portable UI: 767 checks passed. Each renderer also passed unit (213), core (49), replay (9), N2 (24), protocol (56), boundary (21), and graphics (13) suites. Standalone Settings (67) and Preview (71) checks passed. Linux cross-build and static ABI checks passed for all nine binaries; target runtime acceptance remains separate.

The final Settings and canonical README captures were reviewed against the approved references for proportions, control density, hierarchy, spacing and clipping. Native and portable integrated captures confirm that the revised document header, code-copy control and footer icon render in the application. Integrated captures include synthetic PTY test titles and an intentional composition guard notice; they are regression evidence, not a staged product demo. No unresolved P0/P1/P2 content-layout finding remains in this scoped review.


## Settings pages and collapsed workspace follow-up

The approved references for this follow-up are the collapsed workspace plus the corrected Terminal, Keyboard, Clipboard and Advanced images. The full effective key-binding catalogue is retained, so the real Keyboard page scrolls beyond the shorter illustrative reference. Reference-only bulk reset is omitted; defaults restore per binding. Native titlebar decorations are outside offscreen content captures.

Actual Settings captures are in `docs/assets/paper-pages-2026-10-20/`. Reviewed the category hierarchy, full-width content, aligned form controls, compact shortcut groups, grouped clipboard policies, source rows and diagnostic disclosures. The independent Settings suite passes 80 assertions, including wheel scroll, thumb drag, idle fade, edge reveal, category reset, shortcut moves, aliases, conflict preservation and bounded-draft rollback.

Final source `bd9502007301` passes 778 native and 774 portable UI checks, both host unit/core/VT suites, and the Linux cross-build plus nine ELF audits. The scoped follow-up review is complete. See [follow-up record](docs/paper-ui-pages-2026-10-20.md).
