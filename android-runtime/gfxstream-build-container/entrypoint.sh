#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d /gfxstream || ! -f /gfxstream/meson.build ]]; then
  echo "error: /gfxstream is not the complete read-only gfxstream checkout" >&2
  exit 64
fi
if [[ ! -d /mesa || ! -f /mesa/meson.build ]]; then
  echo "error: /mesa is not the complete read-only Mesa checkout" >&2
  exit 64
fi
if [[ ! -d /build || ! -w /build ]]; then
  echo "error: /build is not the writable gfxstream build workspace" >&2
  exit 64
fi
if [[ ! -d /ccache || ! -w /ccache ]]; then
  echo "error: /ccache is not the writable gfxstream compiler cache" >&2
  exit 64
fi
if [[ ! -d /export || ! -w /export ]]; then
  echo "error: /export is not the writable gfxstream artifact root" >&2
  exit 64
fi
if [[ $# -eq 0 ]]; then
  echo "error: gfxstream build image has no command" >&2
  exit 64
fi

exec "$@"
