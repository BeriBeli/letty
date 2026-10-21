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
~/.local/opt/letty/current/bin/letty
# After installing a later version:
./tools/rollback-user.sh
```

Installation keeps version directories under `~/.local/opt/letty` and does not
modify system libraries. Running directly from the extracted directory also works.

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
