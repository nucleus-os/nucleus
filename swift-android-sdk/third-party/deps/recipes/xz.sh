#!/usr/bin/env bash
# liblzma (from the XZ Utils source distribution) — leaf dep, used by libxml2.
# Build system: GNU autotools.

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$XZ_URL" "$XZ_SHA256" "$DEPS_CACHE/src-$ARCH")"

pushd "$src" >/dev/null
# Out-of-tree build dir to keep the source clean across arch runs.
build_dir="build-$ARCH"
rm -rf "$build_dir"
mkdir -p "$build_dir"
pushd "$build_dir" >/dev/null
../configure \
  --host="$HOST_TRIPLE" \
  --prefix="$STAGING/usr" \
  --disable-shared --enable-static \
  --disable-doc \
  --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
  --disable-scripts
make -j"$JOBS"
make install
popd >/dev/null
popd >/dev/null
