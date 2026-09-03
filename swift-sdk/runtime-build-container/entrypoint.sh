#!/usr/bin/env bash
set -euo pipefail

test "$(uname -m)" = aarch64
test -x /src/swift/utils/build-script
case "${NUCLEUS_TARGET_ARCHITECTURE:-}:${NUCLEUS_TARGET_GNU_ARCHITECTURE:-}:${NUCLEUS_TARGET_TRIPLE:-}" in
  aarch64:aarch64-linux-gnu:aarch64-unknown-linux-gnu | x86_64:x86_64-linux-gnu:x86_64-unknown-linux-gnu) ;;
  *)
    echo 'error: invalid Linux target descriptor' >&2
    exit 64
    ;;
esac
test -d /target-sysroot/usr/include
test -d /target-sysroot/usr/include/c++/v1
test -w /build
test -w /output
export SWIFT_BUILD_ROOT=/build

if find /target-sysroot \
    \( -name 'libstdc++*' -o -name 'libstdcxx*' \) -print -quit \
    | grep -q .; then
  echo 'error: the Linux target sysroot contains libstdc++' >&2
  exit 1
fi

libxml_build=/build/libxml2-linux-$NUCLEUS_TARGET_ARCHITECTURE
libxml_install=/build/libxml2-install-linux-$NUCLEUS_TARGET_ARCHITECTURE
rm -rf -- "$libxml_install"

cmake -S /src/libxml2 -B "$libxml_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_C_COMPILER=/opt/swift/usr/bin/clang \
  -DCMAKE_C_COMPILER_TARGET="$NUCLEUS_TARGET_TRIPLE" \
  -DCMAKE_C_FLAGS="--target=$NUCLEUS_TARGET_TRIPLE --sysroot=/target-sysroot" \
  -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR="$NUCLEUS_TARGET_ARCHITECTURE" \
  -DCMAKE_SYSROOT=/target-sysroot \
  -DCMAKE_FIND_ROOT_PATH=/target-sysroot \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR="lib/$NUCLEUS_TARGET_GNU_ARCHITECTURE" \
  -DLIBXML2_WITH_ICU=OFF \
  -DLIBXML2_WITH_LZMA=OFF \
  -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_PYTHON=OFF \
  -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_ZLIB=OFF
cmake --build "$libxml_build" --parallel "${NUCLEUS_BUILD_JOBS:-$(nproc)}"
DESTDIR="$libxml_install" cmake --install "$libxml_build"
test -f "$libxml_install/usr/include/libxml2/libxml/parser.h"
test -f "$libxml_install/usr/lib/$NUCLEUS_TARGET_GNU_ARCHITECTURE/libxml2.so"

python3 /src/swift/utils/build-script \
  --preset-file /src/swift/utils/build-presets.ini \
  --preset-file /recipe/nucleus-target-runtime-presets.ini \
  --preset=nucleus_linux_target_runtime \
  --jobs "${NUCLEUS_BUILD_JOBS:-$(nproc)}" \
  toolchain_path=/opt/swift/usr/bin \
  install_destdir=/output \
  target_architecture="$NUCLEUS_TARGET_ARCHITECTURE" \
  target_gnu_architecture="$NUCLEUS_TARGET_GNU_ARCHITECTURE" \
  target_triple="$NUCLEUS_TARGET_TRIPLE" \
  "$@"

swift_testing_build="/build/Ninja-Release/swifttesting-linux-$NUCLEUS_TARGET_ARCHITECTURE"
cmake -S /src/swift-testing -B "$swift_testing_build" -G Ninja \
  -DBUILD_SHARED_LIBS=YES \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/opt/swift/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/opt/swift/usr/bin/clang++ \
  -DCMAKE_Swift_COMPILER=/runtime-builder/nucleus-target-swiftc \
  -DCMAKE_C_COMPILER_TARGET="$NUCLEUS_TARGET_TRIPLE" \
  -DCMAKE_CXX_COMPILER_TARGET="$NUCLEUS_TARGET_TRIPLE" \
  -DCMAKE_Swift_COMPILER_TARGET="$NUCLEUS_TARGET_TRIPLE" \
  -DCMAKE_SYSROOT=/target-sysroot \
  -DCMAKE_C_FLAGS="--target=$NUCLEUS_TARGET_TRIPLE --sysroot=/target-sysroot" \
  -DCMAKE_CXX_FLAGS="--target=$NUCLEUS_TARGET_TRIPLE --sysroot=/target-sysroot -stdlib=libc++" \
  -DCMAKE_Swift_FLAGS="-resource-dir /build/Ninja-Release/swift-linux-$NUCLEUS_TARGET_ARCHITECTURE/lib/swift -sdk /target-sysroot -module-cache-path /build/Ninja-Release/swift-linux-$NUCLEUS_TARGET_ARCHITECTURE/module-cache" \
  -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DFoundation_DIR="/build/Ninja-Release/foundation-linux-$NUCLEUS_TARGET_ARCHITECTURE/cmake/modules" \
  -Ddispatch_DIR="/build/Ninja-Release/libdispatch-linux-$NUCLEUS_TARGET_ARCHITECTURE/cmake/modules" \
  -DSwiftTesting_MODULE_ABI_NAME_SUFFIX=_toolchain \
  -DSwiftTesting_MACRO=NO
cmake --build "$swift_testing_build" --parallel "${NUCLEUS_BUILD_JOBS:-$(nproc)}"
DESTDIR=/output cmake --install "$swift_testing_build"
test -f "/output/usr/lib/swift/linux/Testing.swiftmodule/$NUCLEUS_TARGET_TRIPLE.swiftinterface"
test -f /output/usr/lib/swift/linux/libTesting.so

rsync --archive "$libxml_install/usr/" /output/usr/

install -d /output/usr/include/swift
install -m 0644 \
  /src/swift/lib/ClangImporter/SwiftBridging/swift/bridging \
  /src/swift/lib/ClangImporter/SwiftBridging/swift/bridging.modulemap \
  /output/usr/include/swift/
install -m 0644 \
  /src/swift/lib/ClangImporter/SwiftBridging/module.modulemap \
  /output/usr/include/
