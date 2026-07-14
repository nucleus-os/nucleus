#!/usr/bin/env bash
# nghttp2 — enables HTTP/2 support in libcurl.
# Build system: cmake.
#
# We build only the library (libnghttp2.a); skip the asio C++ wrapper, the
# app binaries (nghttp client, nghttpd server, etc.), and the docs.

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$NGHTTP2_URL" "$NGHTTP2_SHA256" "$DEPS_CACHE/src-$ARCH")"

build_dir="$src/build-$ARCH"
rm -rf "$build_dir"
mkdir -p "$build_dir"

cmake -S "$src" -B "$build_dir" \
  -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
  -DANDROID_ABI="$CMAKE_ANDROID_ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_INSTALL_PREFIX="$STAGING/usr" \
  -DCMAKE_FIND_ROOT_PATH="$STAGING/usr" \
  -DCMAKE_PREFIX_PATH="$STAGING/usr" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_STATIC_LIBS=ON \
  -DENABLE_LIB_ONLY=ON \
  -DENABLE_APP=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_HPACK_TOOLS=OFF \
  -DENABLE_DOC=OFF \
  -DBUILD_TESTING=OFF
cmake --build "$build_dir" -j"$JOBS"
cmake --install "$build_dir"
