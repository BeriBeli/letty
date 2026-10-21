# Paper controls on nanoui kit

Letty uses nanoui 0.4.0's component kit through `src/chrome.zig`. The adapter
keeps the Paper theme, compact geometry, Lucide assets and existing semantic
targets. Application models and input routing remain outside the kit.

## Migrated components

- Text buttons use `kit.button`, including Settings, document toolbars,
  confirmation and rename dialogs, the theme browser and Inspector.
- Icon controls use the same kit button implementation with custom Lucide
  children. Their existing extents, active fill and focus border are retained.
- Settings category rows, choice triggers, inline choice buttons, switches,
  disclosures and shortcut rows use composed kit buttons. The existing
  keyboard and accessibility adapters still decide when to activate them.
- Context-menu, command-palette and theme-list rows use composed kit buttons.
  Selection, scrolling, shortcuts, enabled-action checks and stable targets
  remain with their controllers.
- Workspace and document tab bodies use composed kit buttons, retaining their
  stable keys, child close buttons, drag handling and double-click actions.
- Separators use `kit.separator` with the existing theme border color.

## Appearance adapter

`patches/nanoui-22-kit-appearance.patch` adds an optional `ButtonAppearance`
and a `beginButton`/`Button.end` composition API. Both ordinary kit buttons
and composed buttons share this implementation. The patch is discovered by
the existing `tools/patch_nanoui.py` patch sequence; it does not change the
pinned upstream revision.

A custom appearance supplies a complete `ui.Style`, foreground, text/icon
sizes and optional hover color. It bypasses the default kit shadow, glass
and press spring. Paper keeps its 30-point text buttons, six-point button
corners, compact icon extents and existing hover easing. Colors continue to
come from `appearance.theme`, including external light and dark themes.
Remaining buttons that previously used `ui.button` now use the same compact
Paper appearance as the rest of the application.

`chrome.control` opens exactly one kit button node and leaves it open for
caller-drawn children; callers close it with `ui.end`. No intermediate wrapper
or replacement key is introduced. This preserves the node identity recorded
by `ctx.peekId` before construction, including accessibility geometry and
keyboard focus records. Application keyboard/AX handling remains responsible
for activation; a kit pointer click alone does not authorize an action.

## Retained compositions

The migration reuses kit controls inside existing compositions rather than
replacing their controllers with the kit's defaults:

- Text fields continue using `ui.textField`, including marked text and IME
  handling. Numeric settings keep direct text entry plus increment/decrement
  buttons; kit's `numberInput` only displays a value between two buttons.
- Settings choices retain their inline expansion, custom values, filtering,
  platform-dependent choices, focus sequence and accessibility registration.
  The stock `kit.select` popover does not provide those contracts.
- Dialogs retain modal input isolation, default-cancel behavior, generation
  checks, diagnostic copying, focus and composition guards. Their action
  buttons use kit; the stock dialog's dismissal and animation lifecycle does
  not replace application ownership.
- Menus and palettes retain their keyboard selection, bounded visible rows
  and stable command targets. Tab and sidebar models retain dynamic storage,
  reordering, overflow and session/document ownership.
- Rich sidebar tooltips retain bounded multiline content and clipping. The
  stock kit tooltip is a single label with different timing and appearance.
- Terminal grids, split geometry, transient scrollbars, file/Markdown views
  and native window chrome remain specialized implementations.

## Verification status

The 0.2.0 release preparation ran the integrated application suites: 228 unit
tests, 49 core checks, 806 native UI checks and 802 portable UI checks passed.
All 24 nanoui patches were replayed from the pinned upstream archive and matched
the active vendor files. Linux publication requires the separate tagged CI gate.
Actual Linux IME and screen-reader flows still need target acceptance.
