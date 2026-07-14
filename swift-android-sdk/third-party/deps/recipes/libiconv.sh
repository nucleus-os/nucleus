#!/usr/bin/env bash
# libiconv — leaf dep, used by libxml2 for character set conversion.
# Build system: GNU autotools.
#
# Android's bionic does NOT provide a usable iconv (the symbol exists but is
# stubbed). libxml2's configure check passes against bionic's stub, so we
# must explicitly point libxml2 at our cross-built libiconv via
# --with-iconv=$STAGING/usr (handled in libxml2.sh).

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$LIBICONV_URL" "$LIBICONV_SHA256" "$DEPS_CACHE/src-$ARCH")"

pushd "$src" >/dev/null
build_dir="build-$ARCH"
rm -rf "$build_dir"
mkdir -p "$build_dir"
pushd "$build_dir" >/dev/null
../configure \
  --host="$HOST_TRIPLE" \
  --prefix="$STAGING/usr" \
  --disable-shared --enable-static \
  --enable-extra-encodings \
  --disable-rpath
make -j"$JOBS"
make install
popd >/dev/null
popd >/dev/null
