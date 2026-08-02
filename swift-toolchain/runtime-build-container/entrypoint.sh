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

python3 /src/swift/utils/build-script \
  --preset-file /src/swift/utils/build-presets.ini \
  --preset-file /recipe/nucleus-target-runtime-presets.ini \
  --preset=nucleus_linux_x86_64_runtime \
  --build-dir /build \
  --jobs "${NUCLEUS_BUILD_JOBS:-16}" \
  toolchain_path=/opt/swift-bootstrap/usr/bin \
  install_destdir=/output \
  "$@"

install -d /output/usr/include/swift
install -m 0644 \
  /src/swift/lib/ClangImporter/SwiftBridging/swift/bridging \
  /src/swift/lib/ClangImporter/SwiftBridging/swift/bridging.modulemap \
  /output/usr/include/swift/
install -m 0644 \
  /src/swift/lib/ClangImporter/SwiftBridging/module.modulemap \
  /output/usr/include/
