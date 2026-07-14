#!/usr/bin/env bash
# libcurl — depends on openssl + zlib. Used by FoundationNetworking.
# Build system: cmake.
#
# Feature set: Apple's swift.org Android bundle baseline (SSL, IPv6,
# UnixSockets, libz, AsynchDNS, alt-svc, HSTS, NTLM, HTTPS-proxy,
# threadsafe) PLUS HTTP/2 via nghttp2. We diverge from Apple here
# because most modern HTTP endpoints negotiate HTTP/2 by default;
# without it FoundationNetworking falls back to HTTP/1.1.
#
# Still excluded: HTTP/3 (needs ngtcp2 + QUIC-capable TLS), SCP/SFTP
# (libssh2), IDN (libidn2), PSL (libpsl). These were excluded by
# Apple too and don't warrant the dep weight today.

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$LIBCURL_URL" "$LIBCURL_SHA256" "$DEPS_CACHE/src-$ARCH")"

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
  -DBUILD_CURL_EXE=OFF \
  -DBUILD_TESTING=OFF \
  -DCURL_USE_OPENSSL=ON \
  -DCURL_USE_LIBSSH2=OFF \
  -DCURL_USE_LIBPSL=OFF \
  -DUSE_LIBIDN2=OFF \
  -DUSE_NGHTTP2=ON \
  -DCURL_DISABLE_LDAP=ON \
  -DCURL_DISABLE_LDAPS=ON \
  -DCURL_DISABLE_DICT=OFF \
  -DCURL_ZLIB=ON
cmake --build "$build_dir" -j"$JOBS"
cmake --install "$build_dir"
