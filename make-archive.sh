#!/usr/bin/env bash

set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERSION=${1:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d)}
OUT=${2:-$ROOT/npu-auto-occupy-${VERSION}.tar.gz}

tar -czf "$OUT" \
    --exclude-vcs \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='.state' \
    --exclude='*.tar.gz' \
    -C "$ROOT" \
    README.md install.sh make-archive.sh bin host systemd .gitignore

printf '%s\n' "$OUT"
