# Letty @VERSION@ for Linux x86_64

Verify the extracted files, then launch from an X11 desktop or SSH-forwarded display:

```sh
sha256sum --check SHA256SUMS
./bin/letty
```

Requires Linux 3.10+, glibc 2.17+, GTK 3.22.30+, GLib 2.56.1+, Cairo 1.15.12+
and a usable shell. No compiler, Python, sudo or system font installation is needed.
Keep `bin/` and `share/` together: the four bundled Maple Mono font styles and
shell integration are loaded relative to the executable.

## Install or roll back

```sh
./tools/install-user.sh
~/.local/bin/letty
# After installing a later version:
./tools/rollback-user.sh
```

Installation keeps version directories under `~/.local/share/letty` and creates
`~/.local/bin/letty` as a symlink to `~/.local/share/letty/current/bin/letty`.
Add `~/.local/bin` to `PATH` to launch with `letty`. Upgrades and rollbacks switch
the `current` symlink, so the command follows the selected version.
The installer also adds a Letty application-menu entry with its icon under
`${XDG_DATA_HOME:-~/.local/share}/applications` (relative XDG paths are ignored).
Its executable and icon paths follow `current` through upgrades and rollbacks.
Running directly from the extracted package also provides the taskbar/window
icon; keep `share/icons/` beside `bin/`.
An optional first argument selects a custom install directory for either script;
the launcher remains in `~/.local/bin`. Existing installations under
`~/.local/opt/letty` are left in place; pass that directory explicitly to manage
them. Installation does not modify system libraries. Running directly from the
extracted directory also works.

## Uninstall

Close Letty, then run either the extracted package's `./tools/uninstall-user.sh`
or the installed copy:

```sh
~/.local/share/letty/current/tools/uninstall-user.sh
```

This removes all installed versions and the `current`/`previous` links. It removes
`~/.local/bin/letty` only when that symlink points to this installation. Configuration
and saved layouts are kept. The matching application-menu entry is removed too.
Other files in the installation root are also kept;
unrecognized entries inside `versions/` cause removal to stop before any deletion.
Pass a custom installation directory as the first argument, including
`~/.local/opt/letty` for an older installation. The script requires no sudo or Python.

## Configuration and help

Copy or adapt `config/config.example` into `~/.config/letty/config`.
Open Settings with Ctrl+, or the command palette with Ctrl+Shift+P.
Use Ctrl+Shift+T for a tab, Ctrl+Shift+D/E for splits, Ctrl+Shift+C/V for clipboard,
Ctrl+Shift+F for search, and Ctrl+Shift+O to open a local file.

- [Configuration](https://github.com/BeriBeli/letty/blob/v@VERSION@/docs/configuration.md)
- [File and Markdown workspaces](https://github.com/BeriBeli/letty/blob/v@VERSION@/docs/file-markdown-preview.md)
- [System requirements](https://github.com/BeriBeli/letty/blob/v@VERSION@/docs/compatibility.md)
- [Source and release notes](https://github.com/BeriBeli/letty/releases/tag/v@VERSION@)

`build-info.json` records the source commit, dependency versions and verification
workflow. `abi-audit.json` records the packaged ELF audit; `SHA256SUMS` covers every
payload file. Full test executables, logs, historical screenshots and development
documents are kept in the source repository and CI, outside this runtime package.
GitHub's automatic source archives contain the tagged sources, locks and patches;
`python3 tools/bootstrap.py` restores pinned build dependencies.

Publication requires Linux CI checks. The oldest supported Linux environment,
remote X11/VDI, real IME and target performance still require separate acceptance.
Dependency licenses are in `licenses/` and `THIRD_PARTY_NOTICES.md`.
