#!/usr/bin/env bash

set -euo pipefail

REPO_TARBALL_URL=${NPU_AUTO_OCCUPY_TARBALL_URL:-https://github.com/depeng1994/npu-auto-occupy/archive/refs/heads/main.tar.gz}
command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl command not found\n' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { printf 'ERROR: tar command not found\n' >&2; exit 1; }

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
curl -fsSL "$REPO_TARBALL_URL" | tar -xz -C "$tmp_dir"
repo_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$repo_dir" && -x "$repo_dir/install.sh" ]] || {
    printf 'ERROR: downloaded archive does not contain install.sh\n' >&2
    exit 1
}
exec "$repo_dir/install.sh" "$@"
