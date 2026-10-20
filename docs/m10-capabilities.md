# M10 capabilities and acceptance boundaries

Date: 2026-10-20 (Asia/Singapore). Source/binary/log identity and 102 feature assertions are in the [integration release](m9-m11-release.md). M8 526/522 counts are historical, not this batch's evidence.

| Capability | Implementation | Validation boundary |
|---|---|---|
| Local theme browsing/search | Paper/package/user directories; bounded scans, no downloads | Temp directories/Tester; no real configuration writes |
| Preview/Cancel/Apply | Stable Window ID, lease/candidate ownership; window-local; cancel restores cached theme/zoom; Apply does not save | Multiple windows, source close, reload, deleted files, narrow layout |
| Save | Replace only final root-text theme value; preserve comments/newlines/unknown keys/permissions/ACL/xattr and symlink | Real tempfiles; content/metadata conflict refusal; post-rename directory-fsync warning |
| Inspector | Window/Session/PID/grid/modes/CWD/authority/queues/history/fonts/glyph/render/service stats, eight bounded event changes | Read-only; no polling when closed; text opt-in for one visible cell; Copy Diagnostics omits text |
| Local file drops | Quote for actual POSIX shell/fish, preserve bracketed paste, no Enter | No shell launch/file read/existence probe; stable target/geometry; close/resize/modal invalidates |
| Unknown shell/remote URI | Read-only raw preview/Copy Details, no PTY delivery | Command override is unknown; 7000-byte preview with truncation disclosure; copy includes displayed preview only; no remote-path assumptions |
| OSC 52 writes | Default deny; ask after parsing, Enter cancels; explicit allow; CLIPBOARD UTF-8 ≤64 KiB decoded | Bounded owned queue and session/policy/approval generations; invalid Base64/NUL/UTF-8/busy/empty-clear negatives |
| OSC 52 reads | Unsupported; config accepts deny only; query never reads clipboard | Upstream callback is synchronous; no nested loop or pretend async permission |

Drops accept sixteen paths, 4095 decoded bytes/path, 64 KiB total. POSIX quoting covers sh/bash/zsh/ksh/dash/ash; fish handles backslashes/quotes separately. Unknown shells, overrides, and nonlocal URIs show diagnostics. A known launch shell does not reveal arbitrary later programs' input syntax; users still inspect the target path/host.

Save uses flock for cooperating writers and compares inode/ownership/mode/times/exact content/metadata digest. POSIX has no compare-and-rename; a noncooperating writer can still race between final comparison and rename.

Local validation uses private sessions/configuration/Tester clipboard/owned hidden NSView. In-process callbacks do not establish native drag gestures. Target Linux/GTK/X11 drops, IME, and system clipboard remain pending; the integrated source-bound gate governs packages.
