#!/bin/bash
# Versioned install from an already extracted package. No system libraries change.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
prefix=${1:-"$HOME/.local/opt/letty"}
version=$(awk -F'"' '/"package_id"/ {print $4; exit}' "$root/build-info.json")
[[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid package id' >&2; exit 1; }
mkdir -p -- "$prefix/versions"
target="$prefix/versions/$version"
[[ ! -e "$target" ]] || { echo "Version already exists: $target" >&2; exit 1; }
mkdir -- "$target"
cp -R "$root/." "$target/"
if [[ -e "$prefix/current" && ! -L "$prefix/current" ]]; then echo 'current is not a symlink; refusing replacement' >&2; exit 1; fi
if [[ -L "$prefix/current" ]]; then
  old=$(readlink "$prefix/current")
  ln -s "$old" "$prefix/.previous-new-$$"
  mv -fT "$prefix/.previous-new-$$" "$prefix/previous"
fi
ln -s "versions/$version" "$prefix/.current-new-$$"
mv -fT "$prefix/.current-new-$$" "$prefix/current"
printf 'Installed %s\nRun: %s/current/bin/letty\nRollback: tools/rollback-user.sh %q\n' "$target" "$prefix" "$prefix"
