# Sourced by recipes/*.sh to set up the Android cross-compile environment.
# Inputs (must be set by the caller):
#   ARCH      — aarch64 | x86_64
#   API       — Android API level (e.g. 36)
#   NDK_HOME  — root of the Android NDK
#   STAGING   — sysroot install dir; recipes install into $STAGING/usr/{lib,include,...}

set -euo pipefail

if [[ -z "${ARCH:-}" || -z "${API:-}" || -z "${NDK_HOME:-}" || -z "${STAGING:-}" ]]; then
  echo "env.sh: missing required env (ARCH, API, NDK_HOME, STAGING)" >&2
  exit 1
fi

# Map our short arch names to the triples used by NDK + (when needed) openssl.
case "$ARCH" in
  aarch64)
    HOST_TRIPLE="aarch64-linux-android"
    OPENSSL_TARGET="android-arm64"
    CMAKE_ANDROID_ABI="arm64-v8a"
    ;;
  x86_64)
    HOST_TRIPLE="x86_64-linux-android"
    OPENSSL_TARGET="android-x86_64"
    CMAKE_ANDROID_ABI="x86_64"
    ;;
  *)
    echo "env.sh: unsupported ARCH=$ARCH" >&2
    exit 1
    ;;
esac

# NDK prebuilt clang lives under a host-tagged directory. Linux ships
# linux-x86_64; macOS ships darwin-x86_64 (a universal x86_64+arm64 Mach-O,
# despite the x86_64-only directory name — runs natively on Apple Silicon).
case "$(uname -s)" in
  Darwin) NDK_HOST_TAG="darwin-x86_64" ;;
  *)      NDK_HOST_TAG="linux-x86_64" ;;
esac
NDK_PREBUILT="$NDK_HOME/toolchains/llvm/prebuilt/$NDK_HOST_TAG"
if [[ ! -d "$NDK_PREBUILT" ]]; then
  echo "env.sh: NDK prebuilt dir missing: $NDK_PREBUILT" >&2
  exit 1
fi

# Compiler driver wrappers that bake in --target and --sysroot.
export CC="$NDK_PREBUILT/bin/${HOST_TRIPLE}${API}-clang"
export CXX="$NDK_PREBUILT/bin/${HOST_TRIPLE}${API}-clang++"
# Binutils replacements (llvm-* universally accepts host-triple arg parity).
export AR="$NDK_PREBUILT/bin/llvm-ar"
export RANLIB="$NDK_PREBUILT/bin/llvm-ranlib"
export STRIP="$NDK_PREBUILT/bin/llvm-strip"
export NM="$NDK_PREBUILT/bin/llvm-nm"
export OBJCOPY="$NDK_PREBUILT/bin/llvm-objcopy"
export OBJDUMP="$NDK_PREBUILT/bin/llvm-objdump"
export READELF="$NDK_PREBUILT/bin/llvm-readelf"
# pkg-config + autotools should look only inside $STAGING.
export PKG_CONFIG_LIBDIR="$STAGING/usr/lib/pkgconfig"
export PKG_CONFIG_PATH=""

# Keep host/native build settings out of Android cross-builds. User shell
# flags such as LDFLAGS=-fuse-ld=mold are valid for local host builds but can
# make the NDK clang driver select an incompatible host linker. These archives
# are linked into Swift shared libraries, so build them as PIC by default.
export CFLAGS="-fPIC${NUCLEUS_ANDROID_CFLAGS:+ $NUCLEUS_ANDROID_CFLAGS}"
export CXXFLAGS="-fPIC${NUCLEUS_ANDROID_CXXFLAGS:+ $NUCLEUS_ANDROID_CXXFLAGS}"
export CPPFLAGS="${NUCLEUS_ANDROID_CPPFLAGS:-}"
export LDFLAGS="${NUCLEUS_ANDROID_LDFLAGS:-}"
unset LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH

if [[ ! -x "$CC" ]]; then
  echo "env.sh: compiler driver missing: $CC" >&2
  echo "  expected NDK target API=$API; verify it is supported by this NDK:" >&2
  echo "  ls $NDK_PREBUILT/bin/${HOST_TRIPLE}*-clang | head" >&2
  exit 1
fi

# Convenience for cmake-based recipes.
CMAKE_TOOLCHAIN_FILE="$NDK_HOME/build/cmake/android.toolchain.cmake"

# Convenience: pinned-version source tarball verify+unpack.
fetch_and_unpack() {
  local url="$1" sha="$2" out_dir="$3"
  mkdir -p "$out_dir"
  local tarball
  tarball="$DEPS_CACHE/$(basename "$url")"
  if [[ ! -f "$tarball" ]]; then
    echo "  fetching $(basename "$url")" >&2
    curl -fSL -o "$tarball" "$url"
  fi
  local actual
  actual="$(sha256sum "$tarball" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    echo "  sha256 mismatch for $(basename "$url")" >&2
    echo "    expected: $sha" >&2
    echo "    actual:   $actual" >&2
    exit 1
  fi
  # If a directory of the same base name already exists, reuse it; otherwise extract.
  local base
  base="$(basename "$tarball" | sed -E 's/\.(tar\.(gz|xz|bz2)|tgz|tar)$//')"
  if [[ ! -d "$out_dir/$base" ]]; then
    case "$tarball" in
      *.tar.gz|*.tgz) tar -xzf "$tarball" -C "$out_dir" ;;
      *.tar.xz)       tar -xJf "$tarball" -C "$out_dir" ;;
      *.tar.bz2)      tar -xjf "$tarball" -C "$out_dir" ;;
      *)
        echo "  unsupported archive format: $tarball" >&2
        exit 1
        ;;
    esac
  fi
  echo "$out_dir/$base"
}
