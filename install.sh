#!/usr/bin/env bash
# Install a stable link instead of copying files so a checked-out update changes
# the dispatcher and its provider-private backends together, without version
# skew or a second installed library tree that can drift independently.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

source="$ROOT/bin/sysup"
target="$BIN_DIR/sysup"
if [[ ! -f "$source" || ! -x "$source" ]]; then
  printf 'sysup: command source is not executable: %s\n' "$source" >&2
  exit 1
fi
if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
  printf 'sysup: refusing to replace non-symlink path: %s\n' "$target" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
ln -sfn "$source" "$target"

printf 'installed sysup to %s\n' "$target"
