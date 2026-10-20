#!/bin/bash
set -euo pipefail
prefix=${1:-"$HOME/.local/opt/letty"}
[[ -L "$prefix/previous" && -L "$prefix/current" ]] || { echo 'No previous version available' >&2; exit 1; }
old=$(readlink "$prefix/previous")
[[ -d "$prefix/$old" ]] || { echo 'Previous version missing' >&2; exit 1; }
current=$(readlink "$prefix/current")
ln -s "$old" "$prefix/.rollback-new-$$"
mv -fT "$prefix/.rollback-new-$$" "$prefix/current"
ln -s "$current" "$prefix/.previous-new-$$"
mv -fT "$prefix/.previous-new-$$" "$prefix/previous"
printf 'Now using %s\n' "$old"
