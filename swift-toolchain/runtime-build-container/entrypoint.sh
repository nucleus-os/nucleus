#!/usr/bin/env bash
set -euo pipefail

test "$(uname -m)" = aarch64
test -x /src/swift/utils/build-script
test -d /usr/x86_64-linux-gnu/usr/include
test -d /usr/x86_64-linux-gnu/usr/include/c++/v1
test -w /build
test -w /output

if find /usr/x86_64-linux-gnu \
    \( -name 'libstdc++*' -o -name 'libstdcxx*' \) -print -quit \
    | grep -q .; then
  echo 'error: the Linux target sysroot contains libstdc++' >&2
  exit 1
fi

libxml_build=/build/libxml2-linux-x86_64
libxml_install=/build/libxml2-install-linux-x86_64
rm -rf -- "$libxml_install"

cmake -S /src/libxml2 -B "$libxml_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/opt/swift-bootstrap/usr/bin/clang \
  -DCMAKE_C_COMPILER_TARGET=x86_64-unknown-linux-gnu \
  -DCMAKE_C_FLAGS="--target=x86_64-unknown-linux-gnu --sysroot=/usr/x86_64-linux-gnu" \
  -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
  -DCMAKE_SYSROOT=/usr/x86_64-linux-gnu \
  -DCMAKE_FIND_ROOT_PATH=/usr/x86_64-linux-gnu \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu \
  -DLIBXML2_WITH_ICU=OFF \
  -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_ZLIB=OFF
cmake --build "$libxml_build" --parallel "${NUCLEUS_BUILD_JOBS:-16}"
DESTDIR="$libxml_install" cmake --install "$libxml_build"
test -f "$libxml_install/usr/include/libxml2/libxml/parser.h"
test -f "$libxml_install/usr/lib/x86_64-linux-gnu/libxml2.so"

python3 /src/swift/utils/build-script \
  --preset-file /src/swift/utils/build-presets.ini \
  --preset-file /recipe/nucleus-target-runtime-presets.ini \
  --preset=nucleus_linux_x86_64_runtime \
  --build-dir /build \
  --jobs "${NUCLEUS_BUILD_JOBS:-16}" \
  toolchain_path=/opt/swift-bootstrap/usr/bin \
  install_destdir=/output \
  "$@"

rsync --archive "$libxml_install/usr/" /output/usr/

install -d /output/usr/include/swift
install -m 0644 \
  /src/swift/lib/ClangImporter/SwiftBridging/swift/bridging \
  /src/swift/lib/ClangImporter/SwiftBridging/swift/bridging.modulemap \
  /output/usr/include/swift/
install -m 0644 \
  /src/swift/lib/ClangImporter/SwiftBridging/module.modulemap \
  /output/usr/include/
