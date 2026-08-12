#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d /src/.repo || ! -d /out ]]; then
  echo "error: AOSP artifact processing requires source and built host tools" >&2
  exit 64
fi

if [[ $# -eq 0 ]]; then
  echo "error: AOSP artifact image has no command" >&2
  exit 64
fi

exec "$@"
