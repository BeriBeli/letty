# Settings host contract

This records the frozen integration: the Settings task owns `src/settings/`, form checks, and Settings documentation; the main integrator owns App/Session/configuration/services/vendor/release.

`application_settings.open(h)` opens AppState's singleton Settings; repeated calls reuse it. It creates no PTY and sits outside the terminal registry. Hidden tests do not focus/activate native windows. `open_settings` defaults to Cmd+, / Ctrl+,, respecting clear/ignore/unbind/custom bindings.

## Stable host interface

`src/settings/window.zig` exports Settings, Host, and Options. Embed `settings: Settings = .{}` in heap-stable AppState, outside the dynamic terminal window registry, then open with:

```zig
try h.settings.open(h.gpa, h.app, host_adapter, .{
    .path = selected_config_path,
    .home = config.env("HOME"),
    .dark = h.system_dark,
    .effective = h.cfg,
    .command_override = h.command_override orelse "",
    .cwd_override = h.cwd_override orelse "",
    .profile_override = h.override_profile,
    .diagnostic = last_config_diagnostic,
    .theme_roots = roots,
});
```

Host callbacks from `src/settings/adapter.zig`:

```zig
context: *anyopaque,
prepare: *const fn (*anyopaque, *const Candidate) anyerror!*anyopaque,
abort: *const fn (*anyopaque, *anyopaque) void,
commit: *const fn (*anyopaque, *anyopaque, Candidate) void,
open_config: *const fn (*anyopaque) anyerror!void,
closed: ?*const fn (*anyopaque) void = null,
```

Callbacks run on the UI thread after draw reconstruction. Prepare returns a reservation ticket without consuming Candidate or publishing visible changes. Abort releases it; infallible commit consumes it and transfers the single Candidate arena. Missing configuration publishes an fsynced temporary file through exclusive link. A directory-fsync warning after publication means committed-but-durability-unconfirmed, not a failed save. Describe rollback for reservation side effects; never add fallible service registration after writing.

Call Settings.deinit before AppState/config-arena/app destruction. System appearance calls settings.syncAppearance(dark). Linux/portable uses existing POSIX/config_edit helpers without a new platform dependency. Open Configuration uses the selected path and existing explicit creation confirmation.

## Save transaction

`settings/adapter.zig.Host` provides prepare/abort/commit/open_config/closed. Candidate owns arena/cfg/replacement/frozen dependencies; only arena ownership transfers to commit. Settings checks the actual root/include/theme dependencies, including missing optional files/logical symlinks, constructs a candidate, calls Host.prepare, rechecks inputs/new themes, and performs checked save/create. Failure aborts and preserves draft/configuration/file; successful commit performs no fallible registration/validation. The entire transaction stays in one UI turn without yielding.

`config_transaction.Transaction.prepareBorrowed` validates all windows/profiles and reserves services. Cancellation deinitializes reservations; successful save uses adoptArena→commit. Anchor does not rely on an old Window pointer, allowing Settings without terminal windows. Reload uses the same transaction. Theme leases cancel/rebind before publication; old arenas free afterward. Full commit clears notifications that may borrow profile names. Later render/menu failure reports applied-but-refresh-failed, without claiming disk rollback.

## Navigation and providers

Config.workspace_navigation is top/sidebar, default sidebar; sidebar_show_git/sidebar_show_ports default false. Controls need no additional Options capability. Collection requires explicit enablement. Legacy top/sidebar values both use Kero presentation; Settings does not expose the removed top tab bar. Changes limited to navigation/tab-bar/toggles retain configuration ownership, Session/PID, topology/ratios, search/selection/IME/queued input and rebase the four theme_original fields. CLI command/CWD stay independent overrides rather than modifying parsed profiles.

Bounded workers publish owned snapshots through completion FDs. When macOS set-id login restricts libproc, same-PID sysctl supplies full identity with exact birth checks; unreadable root FDs can yield partial verified-descendant results. Disable/close/held natural exit/fatal revokes watches/timers/snapshots/worker ownership. Static draw never polls.

## Input and lifecycle

Settings focus blocks terminal services at enqueue/timer wake/drainWindow. Binding capture also rejects application-wide globals, including queued actions. Ordinary editing can retain explicit app actions such as new_window/quit. Quit resolves dirty Settings first; closing Settings does not quit or alter terminal layouts.

Options.effective=h.cfg is copied to formatted values only on open. Advanced separates file snapshot, effective-at-open values, and CLI overrides without retaining releasable cfg pointers.

## Validation

`--feature-checks=SETTINGS --nanoui-hidden` runs real hidden windows/two-PTY fixtures, including floating font/choice menus and configuration transactions. Current assertion counts and source hashes are recorded in the verification receipts. M11 also covers Settings focus/capture isolation. Full release/portable app results belong to the [integration release](m9-m11-release.md) and packaged source-bound gate. Target Linux/GTK, native IME/hotkeys/screen readers remain pending.

Standalone portable form check from the repository root:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" zig build \
  --build-file tools/settings-check/build.zig run -Dportable=true \
  --cache-dir "$PWD/.cache/settings-zig"
```

Remove `-Dportable=true` for native Metal. If sandbox Metal is unavailable, build first and run with required authorization. Fixtures use private `/tmp/letty-settings-*` configuration and offscreen PNGs, never user windows/configuration/system clipboard. See [Settings validation](settings-validation-2026-10-20.md) for recorded results.
