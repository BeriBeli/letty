# File and Markdown preview implementation plan

Date: 2026-10-20 (Asia/Singapore). Historical scope authorized by the user: study cmux, then implement local file/Markdown previews. Main integration: local chat `01a15755-4f50-74e2-a62d-441733ffb585`. Final implemented scope/budgets are in the [preview guide](file-markdown-preview.md), with the [integration contract](file-markdown-preview-integration.md) retained for interface history.

Retain nanoui, Zig 0.17.0, native Zig VT, baseline Linux 3.10/glibc 2.17, and the frozen 8e6a2f5691b5/M8 packages and evidence.

## Recorded upstream source review

Reference commit: `488af9a884577a304819ade9c952339fbe148dda` in manaflow-ai/cmux. These were behavioral references, not an instruction to copy AppKit/WebKit architecture.

| Source | Observed design | Letty adaptation |
|---|---|---|
| [FilePreviewPanel.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/FilePreviewPanel.swift), type dispatch ~918/text load ~1181/panel ~1248 | Text/image/PDF/media/Quick Look routing by extension/content; separate loading/lifecycle | Local text/code/PNG/Markdown only; explicit unsupported/binary/directory errors and user-triggered external opening |
| [MarkdownPanel.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/MarkdownPanel.swift) | Stable panel ID, rendered/source, latest-generation async reads, close cancels work/watch/find | Workspace stable-tab ownership, owned shared content, no Session/PTY, stale-result rejection |
| [MarkdownPanelView.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/MarkdownPanelView.swift) | WKWebView/marked.js/GitHub CSS/highlight.js, cross-paragraph selection/search/source | Native nanoui text/images/layout; genuinely selectable cross-block reader |
| [MarkdownWebRenderer.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/MarkdownWebRenderer.swift), [MarkdownWebSupport.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/MarkdownWebSupport.swift) | Panel-lived renderer, resize/visibility/resource/navigation separation, optional remote images | Persistent document caches, bounded canonical local resources, no automatic network or HTML/JS execution |
| [FileContentChangeCoordinator.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/FileContentChangeCoordinator.swift) | Canonical-path observations, aliases/symlinks/replacement, coalescing/reconciliation | Event-driven atomic-rename-compatible watchers, latest request, bounded retries, no per-draw stat/read |
| [FilePreviewWorkspaceOpenSupport.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/Panels/FilePreviewWorkspaceOpenSupport.swift), [FileOpenSocketSupport.swift](https://github.com/manaflow-ai/cmux/blob/488af9a884577a304819ade9c952339fbe148dda/Sources/FileOpenSocketSupport.swift) | Common workspace entry, Markdown routing, reuse and explicit targeting | Picker/path/selected-path/drop share stable-target requests; no new socket/daemon |

The reference also had editing/saving/more formats. This request was read-only preview, without a general editor, remote transfer, or browser dependency.

## P1: document model, opening, and file preview

- Right-side workspace dock with document tabs/close/collapse/resize/focus and reachable narrow-window controls. Each workspace keeps independent documents/scroll.
- Extend shared navigationGeometry().content into final terminal/document rectangles for search/splits/Kitty/drop/URL/IME/AX. An overlay must never leave terminal input active underneath.
- Separate document budgets from eight terminal tabs/sixteen PTYs; no hidden shells. Proposed/final limits: four documents/workspace, sixteen/application, with explicit atomic refusal.
- open_file_preview menu/palette/picker/path input; configurable defaults ultimately Cmd+O / Ctrl+Shift+O. Relative input uses the captured trusted local CWD and shows its base. Markdown routes rendered; text/code routes source.
- Preview Selected Path accepts absolute/relative/local file URI and optional line/column. Try full filenames before suffix parsing, preserving colons; uniformly handle spaces/CJK/percent escapes/authority/NUL/controls. Existing HTTP(S) policy stays separate.
- Preview-area drops open; terminal drops paste quoted paths, never both. Output paths do not trigger automatic reads. Remote OSC 7 cannot map to local files.
- Read-only UTF-8/BOM/CRLF/CJK/empty text with line numbers, scrolling, find/selection/copy/path/refresh and explicit encoding/size/permission/deletion/format errors.
- PNG behavior must match native/portable; expose fit/original/zoom/dimensions/errors as implemented. Other decoders require separate cross-platform implementation and acceptance.

## P2: rendered Markdown

- Shared-generation Preview/Source with headings/paragraphs/emphasis/code/quotes/rules/lists/tasks/tables/strike/links/local PNG, readable spacing/hierarchy/long rows.
- Bounded syntax/token/layout model rather than regex substitutions. Pin new dependencies/licenses/digests if used. For a local parser, publish the actual CommonMark/GFM subset and test nesting/escapes/backticks/fences; Source retains originals.
- Code uses monospace/background/horizontal scroll/copy; syntax highlighting is not assumed. Tasks remain read-only; HTML/MDX is literal/escaped.
- Cross-block selection/copy in source order, current-document find/navigation/counts/scroll, UTF-8/grapheme-safe offsets. Do not route find into terminals.
- Anchors scroll locally; relative documents use common opening. HTTP(S) requires clicks. Local images resolve inside the document directory with symlink/boundary checks; unsupported/remote/out-of-bounds resources show alt/status without fetching.
- Cache layout, invalidate on width/zoom/content/font changes, and construct visible regions. Terminal output must not repeatedly read/parse/decode documents.

## P3: changes, lifecycle, and integration

- Background reads/parsing/decode return owned results with Window/Tab/Document/generation checks. Close/switch/exit cancels and rejects stale results; paths cannot borrow frame/config arenas.
- macOS vnode/directory and Linux inotify observe writes/atomic replace/rename/delete/recreate, coalesce saves, retry bounded races, and disclose manual-refresh fallback without idle polling.
- Recheck object/size around reads. Reject directories/FIFO/devices/sockets without blocking. Preliminary text 4 MiB/PNG proposals were tightened by implementation; the [guide](file-markdown-preview.md#updates-resources-and-limits) is authoritative. Bound content/AST/index/images/concurrency/aggregate ownership; never silently present truncation as complete.
- Hidden workspaces mark updates without constant relayout. Close releases watches/FDs/workers/content/indexes/image keys/caches; errors leave PTYs intact.
- Managed image keys share nanoui_graphics_resources.Store/TextSystem KeySource, with CPU/Metal lifetime/failure checks.
- Document focus owns text/navigation/selection/find/copy/zoom; modals/IME have priority. Return restores pane focus/mode 1004. AX exposes bounded read-only semantics/actions and rejects stale targets.
- Initial document state may remain memory-only. If later persisted, store revalidated metadata only, never content/native handles/worker pointers.

## Original work allocation

Main integration owned shared app/config/actions/menu/geometry/input/AX/drop/build/release. Three bounded original subtasks covered reader/model/path/watch, Markdown parser/layout, and document UI/Tester respectively; implemented modules use `src/preview/`. Shared interfaces had one owner and full builds/freezes were serialized. This records historical ownership, not a new delegation request.

## Acceptance and delivery

1. Actual app entry points, reuse/workspace isolation/switch/close/collapse/drag and full-PTY-budget behavior; preserve source bytes/session IDs/PIDs/ratios/selection.
2. Temp fixtures: ordinary/code/CJK/emoji/CRLF/empty/no-extension/misnamed binary/oversize/long-line/permissions/spaced-CJK-colon paths/symlink/FIFO; nonblocking work, cancellation, no UAF/leaks.
3. Tables/nesting/fences/escapes/links/anchors/local images/cross-block copy/find/source; actual rendered reading, explicit dangerous-scheme/path/corrupt-image fallback.
4. Writes/atomic replacement/delete-recreate/rapid saves/close-switch during read/symlink changes; latest generation wins and watcher fallback is real.
5. Top/sidebar/two windows/narrow/zoom/light-dark geometry/input/drop/URL/search/IME/AX; real PTY proves no leakage; inspect text/Markdown/image/error native/portable screenshots.
6. Fresh model/app/native/portable/CPU-Metal/resource/Linux cross-ABI/lifecycle/release evidence and versioned package. Retain 8e6 baseline; measure closed-preview idle, large-document memory/frame/scroll with honest scope.

Track P1–P3 separately; final delivery requires real App integration and a testable package. M12 target acceptance remains separate; this does not initiate M15–M19 daemon/extensions/AI.
