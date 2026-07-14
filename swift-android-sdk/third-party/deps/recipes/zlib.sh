#!/usr/bin/env bash
# zlib — leaf dep, used by openssl and libcurl.
# Build system: bespoke configure script. Plays nicely with cross by reading $CC.

set -euo pipefail
DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$DEPS_DIR/versions.env"
source "$DEPS_DIR/env.sh"

src="$(fetch_and_unpack "$ZLIB_URL" "$ZLIB_SHA256" "$DEPS_CACHE/src-$ARCH")"

pushd "$src" >/dev/null
# zlib's configure has no --host flag; it picks up $CC/$AR/$RANLIB from env.
# --static drops the .so target so we don't ship a shared zlib (Foundation
# links it statically). prefix routes install into $STAGING/usr.
#
# --uname=Linux: zlib's configure keys its *own* uname (i.e. the build
# host's), not the target, to decide the archiver — on a Darwin build host
# it unconditionally overrides AR to Apple's libtool, discarding our
# exported AR=llvm-ar. libtool then silently produces a corrupt archive
# from the ELF (Android) .o files ("libtool: warning: not a mach-o"), which
# only surfaces later as "undefined symbol: deflate" et al at link time.
# We're always targeting Android (Linux-based) regardless of build host, so
# spoofing the Linux branch is correct on every host, not just a workaround.
make clean >/dev/null 2>&1 || true
./configure --prefix="$STAGING/usr" --static --uname=Linux
make -j"$JOBS"
make install
popd >/dev/null
