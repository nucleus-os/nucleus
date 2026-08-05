#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME"

case "${1:-}" in
  run-test)
    if [[ $# -lt 2 ]]; then
      echo "error: run-test requires an executable under /build" >&2
      exit 64
    fi
    executable="$2"
    shift 2
    case "${executable}" in
      /build/*) ;;
      *) echo "error: Chromium test executable must be under /build" >&2; exit 64 ;;
    esac
    exec "${executable}" "$@"
    ;;
  clang-version)
    if [[ $# -ne 1 \
        || ! -x /source/chromium/src/third_party/llvm-build/Release+Asserts/bin/clang ]]; then
      echo "error: clang-version requires the Chromium compiler" >&2
      exit 64
    fi
    exec /source/chromium/src/third_party/llvm-build/Release+Asserts/bin/clang --version
    ;;
  validate-browser)
    if [[ $# -ne 1 \
        || ! -x /artifact/runtime/nucleus-browser-bin \
        || ! -f /artifact/bin/nucleus-browser ]]; then
      echo "error: validate-browser requires a complete browser artifact" >&2
      exit 64
    fi
    linkage="$(ldd /artifact/runtime/nucleus-browser-bin)"
    printf '%s\n' "$linkage"
    if grep -Fq 'not found' <<<"$linkage"; then
      exit 1
    fi
    exec bash -n /artifact/bin/nucleus-browser
    ;;
  cef-make-distrib)
    if [[ $# -ne 1 \
        || ! -f /source/chromium/src/cef/tools/make_distrib.py \
        || ! -d /build \
        || ! -w /distribution ]]; then
      echo "error: cef-make-distrib requires source, build, and distribution mounts" >&2
      exit 64
    fi
    exec python3 /source/chromium/src/cef/tools/make_distrib.py \
      --output-dir=/distribution \
      --allow-partial \
      --ninja-build \
      --release-build-dir=/build \
      --x64-build \
      --minimal \
      --no-archive
    ;;
  validate-cef)
    if [[ $# -ne 1 \
        || ! -f /sdk/Release/libcef.so \
        || ! -f /sdk/include/cef_version_info.h \
        || ! -w /smoke ]]; then
      echo "error: validate-cef requires complete SDK and scratch mounts" >&2
      exit 64
    fi
    linkage="$(ldd /sdk/Release/libcef.so)"
    printf '%s\n' "$linkage"
    if grep -Fq 'not found' <<<"$linkage"; then
      exit 1
    fi
    cat > /smoke/consumer.c <<'EOF'
#include "include/cef_version_info.h"
int main(void) { return cef_version_info(0) > 0 ? 0 : 1; }
EOF
    cc \
      -I /sdk \
      /smoke/consumer.c \
      -L /sdk/Release \
      -Wl,-rpath,/sdk/Release \
      -lcef \
      -o /smoke/consumer
    exec /smoke/consumer
    ;;
  cef-version-check)
    if [[ $# -ne 1 \
        || ! -f /source/chromium/src/cef/tools/version_manager.py ]]; then
      echo "error: cef-version-check requires the CEF source mount" >&2
      exit 64
    fi
    exec python3 /source/chromium/src/cef/tools/version_manager.py -c
    ;;
  cef-archive)
    if [[ $# -ne 3 \
        || ! "$2" =~ ^[A-Za-z0-9._+-]+\.tar\.gz$ \
        || ! "$3" =~ ^[0-9a-f]{24}$ \
        || ! -d /candidate/sdk \
        || ! -w /candidate/artifacts ]]; then
      echo "error: cef-archive requires a safe archive name, build ID, and candidate mount" >&2
      exit 64
    fi
    exec tar \
      -C /candidate \
      --sort=name \
      --mtime=@0 \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --use-compress-program='gzip -n' \
      -cf "/candidate/artifacts/$2" \
      "--transform=s,^sdk,$3," \
      sdk
    ;;
esac

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
