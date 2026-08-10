#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d /src/.repo \
    || ! -d /src/out \
    || ! -w /src/out \
    || ! -d /ccache \
    || ! -w /ccache ]]; then
  echo "error: AOSP compilation requires source plus writable output and compiler-cache workspaces" >&2
  exit 64
fi

if [[ $# -eq 0 ]]; then
  echo "error: AOSP build image has no command" >&2
  exit 64
fi

exec "$@"
