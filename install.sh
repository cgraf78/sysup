#!/usr/bin/env bash
# Install a stable link instead of copying files so a checked-out update changes
# the dispatcher and its provider-private backends together, without version
# skew or a second installed library tree that can drift independently.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

target="$BIN_DIR/sysup"
if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
  printf 'sysup: refusing to replace non-symlink path: %s\n' "$target" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
ln -sfn "$ROOT/bin/sysup" "$BIN_DIR/sysup"

printf 'installed sysup to %s\n' "$BIN_DIR/sysup"
