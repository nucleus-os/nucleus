#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME"

if [[ ! -f /source/source-provenance.json \
    || ! -x /source/chromium/src/buildtools/linux64/gn \
    || ! -x /depot_tools/autoninja ]]; then
  echo "error: Chromium source and depot_tools must be complete read-only inputs" >&2
  exit 64
fi
if [[ ! -d /build || ! -w /build ]]; then
  echo "error: /build must be the writable product output" >&2
  exit 64
fi

case "${1:-}" in
  configure)
    if [[ $# -ne 2 ]]; then
      echo "error: configure requires the complete GN argument string" >&2
      exit 64
    fi
    exec /source/chromium/src/buildtools/linux64/gn \
      gen /build \
      "--args=$2"
    ;;
  build)
    if [[ $# -lt 3 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: build requires a positive job count and at least one target" >&2
      exit 64
    fi
    jobs="$2"
    shift 2
    exec /depot_tools/autoninja -j "$jobs" -C /build "$@"
    ;;
  *)
    echo "error: expected Chromium builder mode: configure or build" >&2
    exit 64
    ;;
esac
