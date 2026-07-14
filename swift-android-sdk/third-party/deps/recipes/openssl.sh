#!/usr/bin/env bash
# OpenSSL — depends on zlib. Used by libcurl for TLS.
# Build system: bespoke perl-driven ./Configure.
#
# OpenSSL has first-class Android targets (`android-arm64`, `android-x86_64`,
# …) selected via $OPENSSL_TARGET (set by env.sh).
#
# We do a static-only build matching Apple's bundle (libssl.a + libcrypto.a),
# no shared, no tests, no docs. Disable engines and unneeded protocols to
# keep the static archives small.

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$OPENSSL_URL" "$OPENSSL_SHA256" "$DEPS_CACHE/src-$ARCH")"

# OpenSSL expects the NDK toolchain bin/ to be on PATH so its build machinery
# can locate `clang`, `ar`, etc. without absolute paths.
export PATH="$NDK_PREBUILT/bin:$PATH"
# Pass -D__ANDROID_API__ explicitly; OpenSSL inspects this to gate API-level
# guarded symbols (e.g. arc4random_buf available from API 28).
export ANDROID_NDK_ROOT="$NDK_HOME"

pushd "$src" >/dev/null
# Configure is non-recursive (in-tree build). Clean any prior arch's output.
[[ -f Makefile ]] && make clean >/dev/null 2>&1 || true
./Configure "$OPENSSL_TARGET" \
  -D__ANDROID_API__="$API" \
  --prefix="$STAGING/usr" \
  --openssldir="$STAGING/usr/ssl" \
  --with-zlib-include="$STAGING/usr/include" \
  --with-zlib-lib="$STAGING/usr/lib" \
  no-shared \
  no-tests \
  no-docs \
  no-apps \
  no-engine \
  no-legacy \
  no-asan \
  no-ubsan \
  zlib
make -j"$JOBS" build_libs
# install_dev = headers + .a archives, no binaries/docs/man pages.
make install_dev
popd >/dev/null
