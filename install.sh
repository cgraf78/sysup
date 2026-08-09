#!/usr/bin/env bash
# Install stable links instead of copying files so a checked-out update changes
# the dispatcher and its private backends together, without version skew.

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="${BIN_DIR:-$PREFIX/bin}"
LIB_DIR="${LIB_DIR:-$PREFIX/lib}"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

for target in "$BIN_DIR/sysup" "$LIB_DIR/sysup"; do
  if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
    printf 'sysup: refusing to replace non-symlink path: %s\n' "$target" >&2
    exit 1
  fi
done

mkdir -p "$BIN_DIR" "$LIB_DIR"
ln -sfn "$ROOT/bin/sysup" "$BIN_DIR/sysup"
ln -sfn "$ROOT/lib/sysup" "$LIB_DIR/sysup"

printf 'installed sysup to %s\n' "$BIN_DIR/sysup"
