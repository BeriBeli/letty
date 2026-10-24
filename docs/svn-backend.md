# Git/SVN Changes panel and local SVN backend

The active Zig port has a read-only SVN working-copy backend in
`src/runtime/svn.zig`. `src/runtime/vcs.zig` provides Git/SVN discovery, a shared
change-record type and common request/select/pump/consume accessors. Each desktop
pane owns this shared state; the existing Changes panel automatically selects
the backend for the focused terminal's current directory.

## Using Changes

Open **Toggle Changes** in the command palette, press Cmd+Alt+G on macOS or
Ctrl+Shift+G on Linux, or click the repository status in a pane header. The
existing `git-status` setting controls automatic status for both Git and SVN;
explicitly opening Changes also works with that setting disabled.

The SVN panel is labelled **SVN Working Copy Changes**. It lists local changes
without staged/unstaged groups, and retains property, copy and conflict markers.
It hides Git's Uncommitted/Branch/Agent turn selector and snapshot hint. Git
retains its own comparison modes. SVN rows omit Git line counts because SVN
status does not measure them.

Click a path to preview its local BASE diff with the same virtualized renderer
used for Git. `diff-layout = unified`, `split` or `auto` applies to both backends.
SVN property hunks have colors without invented file line numbers; binary
notices remain readable metadata. Open file is available only for listed paths
that can be opened, and is hidden for deleted/missing/obstructed/external paths.

Refresh uses the existing local process probe for the shell's current directory,
then OSC working-directory metadata or its launch directory if unavailable.
Opening the panel, window focus, shell/agent completion and an output-triggered
250 ms coalesced refresh update repository information; the Refresh button is
also available for edits made outside the terminal. Terminal headers display
SVN and the changed-file count; sidebar tooltips include the same summary.
There is no periodic server or filesystem polling. Leaving a working copy
clears its list/patch and shows **No Git or SVN working copy**.

## Supported behavior

- Discover the nearest enclosing `.git` or `.svn` marker, including from a
  subdirectory or symlinked project directory. Git wins a same-directory tie.
  SVN validates the working copy and obtains its actual root with local
  `svn info --xml --depth empty`.
- List local changes using `svn status --xml --ignore-externals`, including
  changelists, added/deleted/replaced/missing/unversioned paths, copies, move
  metadata, switched nodes and external markers. A directory's own property
  changes are retained, including the root `.` entry.
- Preserve text and property status separately, and recognize text, property
  and tree conflicts. Moves retain SVN's added/deleted records and move links;
  they are not collapsed into Git rename records.
- Preview a selected versioned path using SVN's internal unified diff against
  local BASE. Property patches and SVN's binary-file notices remain in the
  patch. Directory selection uses `--depth empty` to avoid mixing descendant
  changes into a directory's own preview.
- Report explicit reasons for unavailable previews of unversioned, missing,
  obstructed/incomplete and external paths. An external working copy must be
  opened separately. Unversioned paths have no SVN BASE; raw unversioned file
  preview is outside this backend.

No command uses `status -u`, repository URLs, history, commit, add, revert,
cleanup or update. No `.svn/wc.db` parser or `git-svn` conversion is involved.
The backend does not provide staging, branch comparisons or Last Turn snapshots.
`supportsBase(.head)` means local BASE for SVN; `.branch` and `.turn` are
unsupported. SVN status does not populate Git's line-count/binary summary
fields: their default zero/false values are not measured SVN statistics.

## Integration contract

The desktop owns one `vcs.State` per pane. Call `request` with an absolute directory
and stable window/workspace/pane IDs; `review = true` schedules the selected
preview after status refresh. `select` accepts only a path in the current SVN
change list. Pass `pump` the existing `jobs.Pool` and route completed review jobs
back through `consume`, after resolving their owner IDs. Git job tags use the
lower half of the byte; SVN uses the upper half. Other job kinds must not be
routed here.

`files()`, `patch()` and `message()` return borrowed views owned by the backend.
`patchVersion()` invalidates cached diff rendering when text or backend changes.
Copy them before retention across requests, completions or destruction. The SVN
backend copies XML text and child output before a job is destroyed. Stop routing
and cancel/reap owned jobs before destroying the owner's state/pool.

Refresh is event driven and queued requests coalesce per pane. This backend
starts no polling timer. Each SVN
state runs at most one job. Requests during a running job coalesce to the newest
generation, and directory/owner changes discard stale results. Backend switches
cancel and reap old jobs before resetting state/private Git indexes. The desktop
revalidates owner IDs, review epoch, current directory and membership for deferred
selection/open actions. Patch cache keys include directory/backend transitions.
Selection changes
discard an old preview and queue the new selection. Failures clear preview text
and surface diagnostics; refresh can retry discovery after a status failure.

The production pool permits four active jobs in total, with 15-second SVN
deadlines, 4 MiB stdout and 32 KiB stderr limits. XML depth is limited to 32 and
changed entries to 16,384. Hitting a limit fails explicitly rather than
publishing a partial list/patch. XML supports SVN's escaped UTF-8 attributes,
including numeric references; DTDs and external entities are rejected.

Commands use argument vectors, `--` and local path prefixes, never shell
interpolation. Local BASE-to-WORKING `svn diff` treats `@` literally, unlike
`svn info`'s peg-revision syntax. `--internal-diff` overrides a configured
external diff helper. Executables are found through PATH; absent SVN reports an
error and can be retried after installation/PATH correction.

## Verification

Use exactly Zig 0.17.0. Unit checks are part of the normal host suite. The
additional integration suite requires `svn` and `svnadmin` (SVN 1.9+):

```sh
python3 tools/build.py --native --skip-bootstrap --zig=/path/to/zig
python3 tools/verify-ui.py --prefix=native
python3 tools/verify-svn.py --zig=/path/to/zig
python3 tools/verify-svn.py --zig=/path/to/zig --ui=zig-out/native/bin/letty
```

Pass `--svn=/path/to/svn --svnadmin=/path/to/svnadmin` when they are not in PATH.
The script builds the fixture-only `svn-check-bin` target under `.cache/`, drives
the production asynchronous job pool without visible windows, and creates
private `file://` repositories, working copies, HOME and configuration. It
checks actual conflict output, Unicode/space/`@`/option-like paths, property and
binary patches, nested Git/SVN discovery and operation with the repository
unavailable. It also proves a configured external diff helper is not executed.
Temporary repositories are removed on exit; the current source and fixture
binary hashes are recorded in `.cache/verification/native-svn.json` on success.
No global SVN installation is performed by this script.

The normal hidden UI suite verifies SVN labels, hidden Git controls, absent
invented counts, missing-path/stale-action guards and both layouts using owned
deterministic fixtures, saving `svn-unified.png` and `svn-split.png`. The optional
`--ui` integration run drives real SVN discovery, status and patch jobs through
the desktop, clicks a changed file, checks both layouts, and leaves the working
copy to verify stale content is cleared. It uses the same private repositories
and records the application/log hashes in the SVN receipt.

The fixture executable is not part of the default installation. Cross-building
it or the application does not establish real target Linux/X11/VDI acceptance.

## Shared local editor

The Changes panel's Edit file action opens the same native editor for regular
Git and SVN working files. Text is limited to 1 MiB, undo history is bounded,
and saves compare the file content hash before an atomic replacement. The
editor follows worktree-relative no-follow directory handles, preserves normal
permission bits, and does not stage, commit, or change SVN properties. Binary
files remain outside text editing. Git agent-turn Keep/Revert controls do not
appear for SVN; this preserves the backend capability boundary.
