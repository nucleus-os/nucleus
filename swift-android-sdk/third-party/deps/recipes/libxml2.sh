#!/usr/bin/env bash
# libxml2 — depends on liblzma + libiconv. Used by FoundationXML.
# Build system: cmake (modern libxml2 ≥ 2.10 ships first-class CMakeLists).

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$LIBXML2_URL" "$LIBXML2_SHA256" "$DEPS_CACHE/src-$ARCH")"

build_dir="$src/build-$ARCH"
rm -rf "$build_dir"
mkdir -p "$build_dir"

# Foundation needs the schema/xpath/etc. core; doesn't need python bindings,
# http/ftp client (it has FoundationNetworking for that), or the xmllint
# executable.
cmake -S "$src" -B "$build_dir" \
  -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
  -DANDROID_ABI="$CMAKE_ANDROID_ABI" \
  -DANDROID_PLATFORM="android-$API" \
  -DCMAKE_INSTALL_PREFIX="$STAGING/usr" \
  -DCMAKE_FIND_ROOT_PATH="$STAGING/usr" \
  -DCMAKE_PREFIX_PATH="$STAGING/usr" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_ICU=OFF \
  -DLIBXML2_WITH_LZMA=ON \
  -DLIBXML2_WITH_ICONV=ON \
  -DLIBXML2_WITH_ZLIB=ON \
  -DLIBXML2_WITH_HTTP=OFF \
  -DLIBXML2_WITH_FTP=OFF \
  -DLIBXML2_WITH_THREAD_ALLOC=OFF
cmake --build "$build_dir" -j"$JOBS"
cmake --install "$build_dir"
