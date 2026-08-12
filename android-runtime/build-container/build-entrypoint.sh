#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "source" ]]; then
  shift
  exec "$@"
fi

if [[ ! -d /src/.repo \
    || ! -d /out \
    || ! -w /out \
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
