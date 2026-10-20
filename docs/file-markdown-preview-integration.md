# File and Markdown preview integration contract

Date: 2026-10-20. Historical implementation handoff for the [preview plan](file-markdown-preview-plan.md); it was not an acceptance receipt. See [current capabilities](file-markdown-preview.md) for final budgets.

The main integrator owns App/AppState, actions/menus/bindings, final terminal/document rectangles, input/AX/drop, and release builds. Original work allocation: m11_services owned model/loader/platform reader-watch/tempfile components; m9_graphics owned bounded Markdown IR/parser fixtures; m10_interactions owned panel/view/read-only selection/find/Tester checks. The implemented directory is `src/preview/`, equivalent to the proposed `src/file_preview/`.

`application_preview.Runtime(Window)` owns heap-stable documents by stable Tab ID, each with Panel/fdwatch. Limits are four/workspace, sixteen/application, independent of sixteen PTYs; duplicate paths reuse. Hidden workspaces retain data/scroll without relayout on background results. Workspace/window close removes fdwatch before worker teardown and owned-result release. Document state is not written into terminal restoration files.

`preview/model.State` contains id/generation/path/bytes/kind/status/revision/stale, with open(gpa,path), refresh(), fd(), drain(gpa), and deinit(gpa). Kinds: text/markdown/image/unsupported. Background reads require absolute local paths; UI resolves relative/file URI/line-column forms. Special/remote/unverifiable paths and symlink components reject visibly; macOS fixtures use canonical `/private/tmp`. Early proposed PNG input was 8 MiB; the final guide specifies 4 MiB. Text is 2 MiB/50000 lines and Markdown parsing 1 MiB, rejecting excess explicitly.

Panel exposes opened/focused/model/path, revision-only sync(gpa), deinit, prepareInput, draw→Intent, and handleAction. Main integration owns dock collections/tabs. Markdown.Document owns rendered text and absolute-byte-offset lines/spans/links for cross-block find/selection. HTML stays literal; resources never automatically fetch over the network. Worker prepare hooks perform Markdown/PNG transforms; UI accepts owned results/uploads.

Every pane/search/URL/drop/IME/AX path uses final content rectangles after dock subtraction. Document focus intercepts terminal/queued PTY services; modal priority and terminal focus restoration remain intact. Drops open once in previews or paste once in terminals. Managed images share the TextSystem Store.keys source.

The `8e6a2f5691b5` versioned package/source remain intact. Its test binaries, manifest, and core records were retained in `.cache/preview-baseline-8e6a2f5691b5/`. New source requires fresh feature/regression/ABI/resource/performance evidence and packages, without reusing old counts.
