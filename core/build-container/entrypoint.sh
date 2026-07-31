#!/usr/bin/env bash
set -euo pipefail

if [[ ! -d /build || ! -w /build ]]; then
  echo "error: /build is not the writable external native build root" >&2
  exit 64
fi
if [[ ! -d /ccache || ! -w /ccache ]]; then
  echo "error: /ccache is not the writable compiler cache" >&2
  exit 64
fi

case "${1:-}" in
  skia-host | skia-android)
    if [[ ! -x /src/bin/gn || ! -f /src/DEPS ]]; then
      echo "error: /src is not the complete read-only Skia checkout" >&2
      exit 64
    fi
    shift
    ;;
  react-native)
    if [[ ! -f /src/README.md \
        || ! -d /src/third-party/react-native/packages/react-native/ReactCommon \
        || ! -d /core-cmake ]]; then
      echo "error: React Native builder inputs are incomplete" >&2
      exit 64
    fi
    shift
    ;;
  *)
    echo "error: expected native builder mode: skia-host, skia-android, or react-native" >&2
    exit 64
    ;;
esac

if [[ $# -eq 0 ]]; then
  echo "error: native builder mode has no command" >&2
  exit 64
fi

exec "$@"
