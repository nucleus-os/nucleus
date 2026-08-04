#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  swiftpm)
    shift
    ;;
  javascript)
    if [[ ! -f package.json || ! -f yarn.lock ]]; then
      echo "error: working directory is not the React Native checkout root" >&2
      exit 64
    fi
    shift
    ;;
  wayland-generate)
    if [[ ! -x /native-wayland/bin/wayland-scanner ]]; then
      echo "error: produced wayland-scanner is not mounted" >&2
      exit 64
    fi
    if [[ ! -d Protocols || ! -d Sources/SwiftWaylandGenerator ]]; then
      echo "error: working directory is not the swift-wayland source root" >&2
      exit 64
    fi
    shift
    ;;
  skia-linux | skia-android)
    if [[ ! -d /build || ! -w /build ]]; then
      echo "error: /build is not the writable external native build root" >&2
      exit 64
    fi
    if [[ ! -d /ccache || ! -w /ccache ]]; then
      echo "error: /ccache is not the writable compiler cache" >&2
      exit 64
    fi
    if [[ ! -x /src/bin/gn || ! -f /src/DEPS ]]; then
      echo "error: /src is not the complete read-only Skia checkout" >&2
      exit 64
    fi
    shift
    ;;
  react-native)
    if [[ ! -d /build || ! -w /build ]]; then
      echo "error: /build is not the writable external native build root" >&2
      exit 64
    fi
    if [[ ! -d /ccache || ! -w /ccache ]]; then
      echo "error: /ccache is not the writable compiler cache" >&2
      exit 64
    fi
    if [[ ! -f /src/README.md \
        || ! -d /src/third-party/react-native/packages/react-native/ReactCommon \
        || ! -d /core-cmake ]]; then
      echo "error: React Native builder inputs are incomplete" >&2
      exit 64
    fi
    shift
    ;;
  gfxstream)
    if [[ ! -d /gfxstream || ! -f /gfxstream/meson.build ]]; then
      echo "error: /gfxstream is not the complete read-only gfxstream checkout" >&2
      exit 64
    fi
    if [[ ! -d /mesa || ! -f /mesa/meson.build ]]; then
      echo "error: /mesa is not the complete read-only Mesa checkout" >&2
      exit 64
    fi
    if [[ ! -d /build || ! -w /build ]]; then
      echo "error: /build is not the writable external gfxstream build root" >&2
      exit 64
    fi
    if [[ ! -d /ccache || ! -w /ccache ]]; then
      echo "error: /ccache is not the writable compiler cache" >&2
      exit 64
    fi
    shift
    ;;
  wayland)
    if [[ ! -d /build || ! -w /build ]]; then
      echo "error: /build is not the writable external Wayland build root" >&2
      exit 64
    fi
    if [[ -z "${NUCLEUS_WAYLAND_SDK:-}" \
        || ! -d "${NUCLEUS_WAYLAND_SDK}" \
        || ! -w "${NUCLEUS_WAYLAND_SDK}" ]]; then
      echo "error: NUCLEUS_WAYLAND_SDK is not the writable target Wayland SDK root" >&2
      exit 64
    fi
    if [[ ! -f /src/meson.build || ! -f /src/protocol/wayland.xml ]]; then
      echo "error: /src is not the complete read-only Wayland checkout" >&2
      exit 64
    fi
    shift
    ;;
  *)
    echo "error: expected builder mode: swiftpm, javascript, wayland-generate, skia-linux, skia-android, react-native, gfxstream, or wayland" >&2
    exit 64
    ;;
esac

if [[ $# -eq 0 ]]; then
  echo "error: native builder mode has no command" >&2
  exit 64
fi

exec "$@"
