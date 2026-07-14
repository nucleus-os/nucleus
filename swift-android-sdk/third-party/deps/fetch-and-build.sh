#!/usr/bin/env bash
# Orchestrator for cross-compiling Foundation's C library dependencies
# (libcurl, openssl, libxml2 + their transitive deps) against the Android NDK.
#
# Output: a fully populated $STAGING/usr/{lib,include,lib/pkgconfig,…} that
# build.sh can hand to build-script via --cross-compile-deps-path.
#
# Invoked by build.sh's build_one_arch(); can also be run standalone:
#
#   STAGING=/tmp/staging-aarch64 ARCH=aarch64 API=36 \
#     NDK_HOME=$HOME/Android/Sdk/ndk/30.0.14904198 \
#     ./fetch-and-build.sh

set -euo pipefail

# BSD sed (macOS) requires an argument (even if empty) to -i; GNU sed (Linux)
# rejects a separate empty-string argument as an extra operand. Portable
# in-place edit wrapper so this script works unmodified on both hosts.
sed_inplace() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

DEPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPS_DIR
export DEPS_CACHE="${DEPS_CACHE:-$DEPS_DIR/cache}"
mkdir -p "$DEPS_CACHE"

JOBS="${JOBS:-$(nproc)}"
export JOBS

# Required env passed by caller; env.sh validates and exits if missing.
: "${ARCH:?ARCH (aarch64|x86_64) required}"
: "${API:?API (e.g. 36) required}"
: "${NDK_HOME:?NDK_HOME (path to NDK root) required}"
: "${STAGING:?STAGING (output sysroot dir) required}"
mkdir -p "$STAGING/usr/lib" "$STAGING/usr/include"

# Load the same cross-build environment used by each recipe so sentinel reuse is
# tied to the actual compiler and flags that produced the staged archives.
source "$DEPS_DIR/env.sh"

# Build order is the topological sort of the dep graph:
#
#   zlib    liblzma   libiconv      (leaves)
#     ↓                  ↓
#   openssl   nghttp2  libxml2
#     ↓         ↓
#   libcurl ←───┘
#
# Within each layer, order among siblings doesn't matter.
recipes=(
  zlib
  xz             # provides liblzma
  libiconv
  openssl        # needs zlib
  nghttp2        # HTTP/2 support for libcurl
  libxml2        # needs liblzma, libiconv
  libcurl        # needs openssl, zlib, nghttp2
)

# Sentinel files mark a recipe as already-built into $STAGING for this
# (ARCH, API) tuple. Recipes are skipped if their sentinel is present;
# delete the sentinel (or $STAGING) to force a rebuild.
sentinel_dir="$STAGING/.deps-built"
mkdir -p "$sentinel_dir"

deps_signature_version="android-deps-v2-pic"
deps_signature="$deps_signature_version
ARCH=$ARCH
API=$API
NDK_HOME=$NDK_HOME
CC=$CC
CXX=$CXX
CFLAGS=$CFLAGS
CXXFLAGS=$CXXFLAGS
CPPFLAGS=$CPPFLAGS
LDFLAGS=$LDFLAGS"
signature_file="$sentinel_dir/.signature"
if [[ "$(cat "$signature_file" 2>/dev/null || true)" != "$deps_signature" ]]; then
  echo "==> [$ARCH] dependency build settings changed; invalidating C dep sentinels" >&2
  find "$sentinel_dir" -maxdepth 1 -type f ! -name .signature -delete
  printf '%s\n' "$deps_signature" > "$signature_file"
fi

sanitize_android_link_metadata() {
  local lib_dir="$STAGING/usr/lib"
  [[ -d "$lib_dir" ]] || return 0

  local file
  local inspected=0
  while IFS= read -r -d '' file; do
    sed_inplace -E \
      -e 's/\\?\$<LINK_ONLY:-pthread>;?//g' \
      -e 's/\\\\\\\\(\$<LINK_ONLY:)/\\\1/g' \
      -e 's/[[:space:]]-pthread([[:space:];)])/\1/g' \
      -e 's/^-pthread[[:space:]]//g' \
      -e 's/[[:space:]]-pthread$//g' \
      -e "s/[[:space:]]-pthread'/'/g" \
      "$file"
    inspected=1
  done < <(find "$lib_dir" -type f \( -path '*/pkgconfig/*.pc' -o -path '*/cmake/*' -o -name '*.la' \) -print0)

  if (( inspected )); then
    echo "==> [$ARCH] normalized Android link metadata" >&2
  fi
}

for recipe in "${recipes[@]}"; do
  sentinel="$sentinel_dir/$recipe"
  if [[ -f "$sentinel" ]]; then
    echo "==> [$ARCH] $recipe: already built (sentinel present)" >&2
    continue
  fi
  echo "==> [$ARCH] $recipe: building" >&2
  bash "$DEPS_DIR/recipes/$recipe.sh"
  touch "$sentinel"
done

sanitize_android_link_metadata

echo "==> [$ARCH] all C deps built into $STAGING/usr/" >&2
