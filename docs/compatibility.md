# System requirements and compatibility

## Linux runtime baseline

Support is defined by interfaces and versions, independently of distribution name.

| Component | Baseline |
| --- | --- |
| Architecture / CPU | x86_64, baseline CPU instruction set |
| Kernel | Linux 3.10 or newer |
| C runtime | glibc 2.17 or newer |
| GTK | GTK 3.22.30 or newer |
| GLib | 2.56.1 or newer |
| Cairo | 1.15.12 or newer |
| Display | Working GTK/X11 session, local or forwarded to an X server/VDI |
| Terminal environment | PTYs, a usable shell and `xterm-256color` terminfo |
| Fonts | Bundled JetBrainsMono Nerd Font; optional installed monospaced families |

The exact delivery target is `x86_64-linux.3.10-gnu.2.17`, CPU `baseline`,
ReleaseSafe, with VT SIMD disabled. glibc and GLib are separate libraries.
Recorded GTK/GLib/Cairo versions define the project baseline; ELF symbol audits
do not establish their independently lowest compatible versions.

`tools/audit-elf.py` checks architecture, interpreter, NEEDED libraries, version
requirements through GLIBC_2.17 and RPATH. Dynamically loaded GUI libraries,
old-kernel syscall paths and actual input/display behavior still need
[target acceptance](linux-testing.md). A newer version number alone does not
certify a particular environment. Runtime use requires no compiler or Python.

## Pinned development inputs

Use **exactly Zig 0.17.0** and Python 3. Current source pins are in
[deps.lock.json](../deps.lock.json):

- Ghostty: `df246d0105e13dfd4a6a54754a9c6555325644ec`.
- nanoui fork: `e68e577db963cf003dacd9aa8da3b00b4cf8f71c`, based on upstream v0.6.4.
- HarfBuzz: 14.6.0, pinned separately in `tools/shaper-dependency.json`.

Bootstrap verifies fixed archives and applies the active patch chains described
in [patches/README.md](../patches/README.md). Five nanoui patches and two Ghostty
patches are active. The 29 older nanoui patches are retained with original hashes
under `patches/archive/`; they are not a second active patch chain.
See [nanoui integration](nanoui-integration.md) for current API ownership.

The application uses native Zig `ghostty-vt`; intentional platform C supplies
system and file services. The former C terminal engine is retained only in the
[historical recovery package](c-vt-recovery.md).

## macOS and acceptance scope

macOS is a development preview using native CoreText/Metal. The
[preview workflow](macos-preview.md) builds, tests and packages that application.
A portable-renderer variant is also available for local verification.

Host checks, Linux cross-builds, static ABI audits, Linux CI, actual oldest-target
execution and real X11/VDI/IME acceptance are distinct evidence. Existing release
receipts remain tied to their recorded source. The
[preceding compatibility guide](archive/compatibility-pre-runtime.md) preserves
older dependency/patch details and measurements.
