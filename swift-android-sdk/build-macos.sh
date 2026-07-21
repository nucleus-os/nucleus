#!/usr/bin/env bash
# Build a Swift SDK for Android against the locally-built macOS
# swift-toolchain (build-macos.sh in the sibling repo). See
# README.md for prerequisites.
#
# Sibling to build.sh, not a branch inside it — mirrors the pattern used by
# swift-toolchain/build-macos.sh: the cross-compile-to-Android work
# itself is host-OS-agnostic (same NDK clang, same build-script --android
# flags), but every path that assumes a Linux *build host* (the NDK's
# linux-x86_64 prebuilt clang directory, ~/Android/Sdk, `nproc`, apt-based
# prerequisites, the Debian ccache PATH-shim convention) needs a macOS
# counterpart. Keeping that as a second top-level script avoids threading
# host-OS conditionals through build.sh's already-dense flag lists.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${NUCLEUS_SWIFT_PLATFORM_ORCHESTRATED:-0}" != 1 ]]; then
  exec "$script_dir/../tools/nucleus" toolchain rebuild "$@"
fi
source "$script_dir/scripts/android-sdk-env.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Toolchain (host swift compiler) — the macOS host toolchain built by
# swift-toolchain/build-macos.sh. Required — this script does NOT
# build it.
toolchain_root="${NUCLEUS_SWIFT_TOOLCHAIN:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/release-6.4.x-macos/usr}"

# Source workspace produced by swift-toolchain/build-macos.sh.
# Reuses the existing checkout — no second clone, no separate patch state.
source_id="${NUCLEUS_SWIFT_SOURCE_ID:-release-6.4.x}"
workspace="${NUCLEUS_SWIFT_SOURCE_WORKSPACE:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-source/${source_id}-macos}"

# build-script's LLVM product driver (swift_build_support/products/llvm.py)
# unconditionally bootstraps Darwin compiler-rt "runtimes" (including a
# Swift-language swift-syntax build) whenever the *build host* reports
# Darwin — regardless of what target is actually being cross-compiled. That
# stage compiles Swift code for the host (arm64-apple-macosx<host-version>)
# and by default resolves the compiler via `xcrun --find swiftc`, landing on
# whatever system Xcode/Xcode-beta is selected rather than our
# swift-toolchain. On this host that system swiftc can't even load
# its own standard library without an explicit -sdk
# ("error: unable to load standard library for target ..."), a pre-existing
# environment issue unrelated to this build. swift_build_support/cmake.py
# reads CMAKE_Swift_COMPILER from the environment before falling back to the
# auto-detected one, so redirect it to our own toolchain's swiftc — built
# from this exact source checkout, so there's no version skew either.
# SDKROOT is still exported as a belt-and-suspenders fallback for any other
# spot that shells out to a bare `swiftc`.
export CMAKE_Swift_COMPILER="$toolchain_root/bin/swiftc"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

# NDK. Default matches build.sh's Linux default (30.0.14904198, AGP-managed
# NDK 30) so both hosts build against the same NDK version — the macOS
# location is the standard Android-tooling convention
# (~/Library/Android/sdk), the closest macOS analogue of ~/Android/Sdk.
# Install it without Android Studio via the standalone cmdline-tools +
# sdkmanager; see README.md.
ndk_version="$(nucleus_android_ndk_version)"
ndk_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/android-ndk"
ndk_home="$(nucleus_android_ndk_home)"
ndk_url="https://dl.google.com/android/repository/android-ndk-${ndk_version}-darwin.zip"

# NDK prebuilt-clang host-tag directory. Linux ships linux-x86_64; macOS
# ships darwin-x86_64 — a universal x86_64+arm64 Mach-O despite the
# x86_64-only directory name, so it runs natively on Apple Silicon.
ndk_host_tag="darwin-x86_64"

# Build/install output. Kept in a separate `-macos` namespace from the
# Linux build's release-6.4.x so the two never collide on a machine that
# somehow has both (they won't on this host, but the convention matches
# swift-toolchain/build-macos.sh).
install_root="${NUCLEUS_SWIFT_ANDROID_INSTALL:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-android-sdks/${source_id}-macos}"
build_root="$install_root/build"
log_root="${NUCLEUS_SWIFT_ANDROID_LOG_DIR:-$install_root/logs}"
log_file="${NUCLEUS_SWIFT_ANDROID_LOG:-$log_root/build-$(date +%Y%m%d-%H%M%S).log}"
latest_log="$log_root/latest.log"
run_info_file="$log_root/latest-run.env"

# Build-script knobs.
api_level="${NUCLEUS_ANDROID_API_LEVEL:-36}"
jobs="${NUCLEUS_SWIFT_ANDROID_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"

# Bundle layout.
bundle_name="swift-${source_id}-macos_android.artifactbundle"
bundle_root="$install_root/$bundle_name"
bundle_tar="$install_root/${bundle_name}.tar.gz"
bundle_sha="${bundle_tar}.sha256"

# Per-arch matrix. Default builds aarch64 only — that's what every
# modern physical Android device (Pixel 7+, Galaxy S22+, etc.) needs.
# x86_64 is only useful for x86 Android emulators on this host; opt
# in via --arch x86_64 when you actually want that.
default_arches=(aarch64)
supported_arches=(aarch64 x86_64)
declare -A arch_triple=(
  [aarch64]="aarch64-unknown-linux-android${api_level}"
  [x86_64]="x86_64-unknown-linux-android${api_level}"
)
declare -A arch_ndk_libdir=(
  [aarch64]="aarch64-linux-android"
  [x86_64]="x86_64-linux-android"
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
Usage: build-macos.sh [--dry-run] [--skip-ndk] [--skip-package] [--reconfigure]
                      [--arch aarch64|x86_64] ...

Build a Swift SDK for Android against the locally-built macOS
swift-toolchain. Requires the Android cmdline-tools + NDK (see
README.md) and swift-toolchain/build-macos.sh already run.

Flags:
  --dry-run       Print the resolved commands and exit.
  --skip-ndk      Use \$NUCLEUS_ANDROID_NDK_HOME as-is; skip the existence check.
  --skip-package  Build the per-arch installs, run smoke test, and skip
                  artifactbundle assembly. Useful while iterating.
  --reconfigure   Force CMake reconfigure for Swift build-script projects,
                  including stale per-arch CMake/external-project state.
  --arch ARCH     Build this arch (repeatable). Default: aarch64. Supported: ${supported_arches[*]}.

Environment:
  NUCLEUS_SWIFT_TOOLCHAIN              Host toolchain root. Default: ${toolchain_root}
  NUCLEUS_SWIFT_SOURCE_WORKSPACE       Source workspace. Default: ${workspace}
  NUCLEUS_SWIFT_SOURCE_ID              Filesystem identifier. Default: ${source_id}
  NUCLEUS_ANDROID_NDK_VERSION          NDK version. Default: ${ndk_version}
  NUCLEUS_ANDROID_NDK_HOME             Explicit NDK path. Default: ${ndk_home}
  NUCLEUS_ANDROID_API_LEVEL            --android-api-level. Default: ${api_level}
  NUCLEUS_SWIFT_ANDROID_INSTALL        Output root. Default: ${install_root}
  NUCLEUS_SWIFT_ANDROID_BUILD_JOBS     Parallel jobs. Default: ${jobs}
USAGE
}

dry_run=0
skip_ndk=0
skip_package=0
reconfigure=0
selected_arches=()
while (($#)); do
  case "$1" in
    --dry-run)      dry_run=1 ;;
    --skip-ndk)     skip_ndk=1 ;;
    --skip-package) skip_package=1 ;;
    --reconfigure)  reconfigure=1 ;;
    --arch)
      shift
      [[ $# -gt 0 ]] || { echo "--arch needs a value" >&2; exit 2; }
      selected_arches+=("$1")
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ${#selected_arches[@]} -eq 0 ]]; then
  selected_arches=("${default_arches[@]}")
fi
for arch in "${selected_arches[@]}"; do
  if [[ -z "${arch_triple[$arch]:-}" ]]; then
    echo "unsupported arch: $arch (supported: ${supported_arches[*]})" >&2
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing host tool: $1 ($2)" >&2
    exit 1
  fi
}
require_tool curl "install with: brew install curl"
require_tool unzip "install with: brew install unzip"
require_tool python3 "install with: brew install python3"
require_tool tar "system tar missing - reinstall macOS command line tools"
require_tool sha256sum "install with: brew install coreutils (provides gsha256sum; symlink it to sha256sum on PATH)"
require_tool cmake "install with: brew install cmake"
require_tool ccache "install with: brew install ccache"

# Host swift toolchain must be present.
host_swift="$toolchain_root/bin/swift"
host_swiftc="$toolchain_root/bin/swiftc"
host_clang="$toolchain_root/bin/clang"
host_clangxx="$toolchain_root/bin/clang++"
if [[ ! -x "$host_swift" ]]; then
  echo "host swift not found at $host_swift" >&2
  echo "build swift-toolchain/build-macos.sh first, or set NUCLEUS_SWIFT_TOOLCHAIN." >&2
  exit 1
fi
if [[ ! -x "$host_swiftc" ]]; then
  echo "host swiftc not found at $host_swiftc" >&2
  echo "the swift-toolchain layout is expected; check the install." >&2
  exit 1
fi
if [[ ! -x "$host_clang" || ! -x "$host_clangxx" ]]; then
  echo "host clang not found under $toolchain_root/bin" >&2
  echo "the swift-toolchain layout is expected; check the install." >&2
  exit 1
fi

# Source workspace must exist and contain a swift checkout.
if [[ ! -d "$workspace/swift/utils" ]]; then
  echo "swift source workspace not found at $workspace" >&2
  echo "build swift-toolchain/build-macos.sh first (it populates this workspace)," >&2
  echo "or set NUCLEUS_SWIFT_SOURCE_WORKSPACE." >&2
  exit 1
fi

check_swift_target_backend() {
  local arch="$1"
  local triple="${arch_triple[$arch]}"
  local tmp err
  tmp="$(mktemp -d)"
  err="$tmp/swiftc.err"
  printf 'public func _nucleusAndroidPreflight() {}\n' > "$tmp/preflight.swift"
  if ! "$host_swiftc" \
      -target "$triple" \
      -parse-stdlib \
      -parse-as-library \
      -module-name _NucleusAndroidPreflight \
      -c "$tmp/preflight.swift" \
      -o "$tmp/preflight.o" >"$tmp/swiftc.out" 2>"$err"; then
    echo "host Swift compiler cannot emit object code for $triple" >&2
    echo "toolchain: $toolchain_root" >&2
    echo "The host Swift compiler must be built with the LLVM backend for the selected Android arch." >&2
    echo "Rebuild swift-toolchain/build-macos.sh with that backend, or set NUCLEUS_SWIFT_TOOLCHAIN to a matching Swift 6.4 toolchain that has it." >&2
    sed 's/^/  /' "$err" >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$tmp"
}
for arch in "${selected_arches[@]}"; do
  check_swift_target_backend "$arch"
done

# Reuse ccache from the toolchain build if present.
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
mkdir -p "$CCACHE_DIR"

reset_cmake_cache_for_subdir() {
  local subdir="$1"
  local build_dir="$workspace/build/$subdir"
  [[ -d "$build_dir" ]] || return 0

  echo "==> removing CMake cache state under $build_dir" >&2
  find "$build_dir" \
    -mindepth 2 -maxdepth 2 \
    \( -name CMakeCache.txt -type f -o -name CMakeFiles -type d -o -name '*-prefix' -type d \) \
    -prune -exec rm -rf {} +
}

# ---------------------------------------------------------------------------
# NDK acquisition
# ---------------------------------------------------------------------------

ensure_ndk() {
  if (( skip_ndk )); then
    if [[ ! -d "$ndk_home" ]]; then
      echo "--skip-ndk set but $ndk_home does not exist" >&2
      exit 1
    fi
    return
  fi
  if [[ -d "$ndk_home" && -x "$ndk_home/ndk-build" ]]; then
    return
  fi
  # Only the legacy r<N><letter> naming has a downloadable zip on
  # dl.google.com. Numeric/preview NDKs (e.g. 30.0.14904198) are only
  # distributed via sdkmanager; fail clearly instead of fabricating a URL.
  if [[ ! "$ndk_version" =~ ^r[0-9]+[a-z]?$ ]]; then
    cat >&2 <<EOF
NDK '$ndk_version' is not present at $ndk_home and is not a legacy
r<N><letter> release that can be fetched from dl.google.com.

Install it via sdkmanager (no Android Studio required — see README.md for
the standalone cmdline-tools setup):

  sdkmanager --channel=3 "ndk;$ndk_version"

Or override the path:

  NUCLEUS_ANDROID_NDK_HOME=/path/to/ndk ./build-macos.sh
EOF
    exit 1
  fi
  mkdir -p "$ndk_cache_dir"
  local zip="$ndk_cache_dir/android-ndk-${ndk_version}-darwin.zip"
  if [[ ! -f "$zip" ]]; then
    echo "fetching NDK ${ndk_version}: $ndk_url" >&2
    curl -fSL -o "$zip" "$ndk_url"
  fi
  # The zip extracts to android-ndk-${ndk_version}/ — rename to a stable path.
  local stage="$ndk_cache_dir/.stage-$$"
  rm -rf "$stage"
  mkdir -p "$stage"
  unzip -q "$zip" -d "$stage"
  local extracted
  extracted="$(find "$stage" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  if [[ -z "$extracted" ]]; then
    echo "NDK zip did not extract as expected" >&2
    exit 1
  fi
  rm -rf "$ndk_home"
  mkdir -p "$(dirname "$ndk_home")"
  mv "$extracted" "$ndk_home"
  rm -rf "$stage"
}

# ---------------------------------------------------------------------------
# Per-arch build
# ---------------------------------------------------------------------------

deps_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/third-party/deps" && pwd)"

build_deps_for_arch() {
  local arch="$1"
  local staging="$build_root/install-$arch"
  echo "==> staging Foundation C deps for $arch into $staging" >&2
  mkdir -p "$staging/usr/lib" "$staging/usr/include"
  ARCH="$arch" API="$api_level" NDK_HOME="$ndk_home" STAGING="$staging" \
    JOBS="$jobs" \
    bash "$deps_dir/fetch-and-build.sh"
}

# swift-corelibs-foundation's CMakeLists.txt does find_package(dispatch
# CONFIG) and, when that fails, falls back to "-I${DISPATCH_INCLUDE_PATH}
# -I${DISPATCH_INCLUDE_PATH}/Block" with DISPATCH_INCLUDE_PATH defaulting to
# the literal path "/usr/lib/swift" — a real Swift SDK/toolchain install
# convention (headers normally live at <sdk>/usr/lib/swift/dispatch and
# .../Block/Block.h) that doesn't hold here: cmake/modules/Libdispatch.cmake
# builds libdispatch for the Android target as a *nested*
# ExternalProject_Add embedded inside swift's own configure, passing
# -DENABLE_SWIFT=NO to it, so libdispatch's own CMakeLists installs its
# headers to that ExternalProject's internal, throwaway install prefix
# (.../include/dispatch, .../include) instead of the SDK-style path — and
# only the compiled .so gets copied out to our destdir; the headers never
# do. The top-level build-script-impl "libdispatch" product that *would*
# install them to the SDK-style path (it passes -DENABLE_SWIFT=YES) never
# runs at all in this cross-compile flow (no android-aarch64-macos/libdispatch-*
# top-level build directory is ever created, only the nested
# swift-android-aarch64/libdispatch-android-aarch64-prefix one) — so Foundation's
# `find_package(dispatch CONFIG)` also fails and it falls through to that
# unreachable literal "/usr/lib/swift" default, and the compile fails with
# "'Block.h' file not found" / "'dispatch/dispatch.h' file not found".
#
# Nothing here needs cross-compiling — dispatch.h and friends are portable
# C headers, identical to what libdispatch's own install() rules would have
# produced. Stage them into the layout Foundation's fallback already
# expects (a plain override of DISPATCH_INCLUDE_PATH) instead of patching
# Foundation's CMakeLists or chasing why the top-level libdispatch product
# doesn't run. Arch-independent (headers, not binaries) — stage once.
stage_libdispatch_headers() {
  local libdispatch_src="$1"
  local staging="$2"
  [[ -f "$staging/.complete" ]] && return 0
  rm -rf "$staging"
  mkdir -p "$staging/dispatch" "$staging/Block" "$staging/os"
  cp "$libdispatch_src"/dispatch/{base,block,data,dispatch,group,introspection,io,object,once,queue,semaphore,source,time}.h "$staging/dispatch/"
  cp "$libdispatch_src/src/BlocksRuntime/Block.h" "$staging/Block/Block.h"
  cp "$libdispatch_src"/os/{generic_base,generic_unix_base,generic_win_base,object}.h "$staging/os/"
  touch "$staging/.complete"
}

# CMake's enable_language(Swift)/CMakeTestSwiftCompiler.cmake try_compile
# probe (run again for every product build-script invokes separately, e.g.
# Foundation's own CMakeLists.txt configure) links a full test executable
# with `-sdk $ndk_home/.../sysroot`. swiftc resolves the Android runtime
# startup object relative to whatever `-sdk` path it's given
# (<sdk>/usr/lib/swift/android/<arch>/swiftrt.o) — it does NOT fall back to
# our --cross-compile-deps-path destdir for this lookup, so once stdlib is
# built the object also has to be reachable under the NDK's own sysroot or
# every subsequent product's CMake configure step fails with "no such file
# or directory: .../sysroot/usr/lib/swift/android/<arch>/swiftrt.o".
#
# This mirrors how a real `swift sdk install` artifactbundle works (its
# swift-sdk.json's sdkRootPath points at a self-contained sysroot that
# already ships this object) — we just don't have a packaged bundle yet
# while we're still building the one that would provide it, so bootstrap
# with a plain file copy instead of hand-patching the NDK ad hoc. Kept as
# an explicit, idempotent, version-controlled step (not a one-off manual
# edit to the shared ~/Library/Android/sdk install) so a fresh NDK checkout
# or a different machine reproduces it automatically; safe to call before
# stdlib exists yet (no-op) and safe to re-run.
sync_swiftrt_to_ndk() {
  local arch="$1"
  local destdir="$2"
  local ndk_prebuilt="$3"
  local src="$destdir/usr/lib/swift/android/$arch/swiftrt.o"
  local dst="$ndk_prebuilt/sysroot/usr/lib/swift/android/$arch/swiftrt.o"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "$dst")"
  cp -p "$src" "$dst"
}

build_one_arch() {
  local arch="$1"
  local triple="${arch_triple[$arch]}"
  # destdir doubles as the "staging" sysroot for cross-compile-deps-path:
  # third-party/deps/fetch-and-build.sh has already populated
  # $destdir/usr/{lib,include} with our cross-built libcurl + openssl +
  # libxml2 + transitive deps. cmake's find_package(CURL)/find_package(
  # LibXml2) then resolve against this dir during Foundation's build.
  # build-script subsequently installs the swift stdlib + Foundation +
  # libdispatch + XCTest into the same tree at $destdir/usr/lib/swift,
  # $destdir/usr/lib/swift_static, etc. matching the official 6.3.2 flow.
  local destdir="$build_root/install-$arch"
  # Swift's build-script writes intermediate artifacts under
  # $workspace/build/$subdir. Use --build-subdir to keep arches isolated
  # without nuking the host build tree (which lives at the default subdir
  # owned by swift-toolchain/build-macos.sh).
  local subdir="android-$arch-macos"
  local ndk_prebuilt="$ndk_home/toolchains/llvm/prebuilt/$ndk_host_tag"
  local libdispatch_headers="$build_root/libdispatch-headers"
  stage_libdispatch_headers "$workspace/swift-corelibs-libdispatch" "$libdispatch_headers"

  local clean_env=(
    env
    -u CFLAGS
    -u CXXFLAGS
    -u CPPFLAGS
    -u LDFLAGS
    -u LIBRARY_PATH
    -u CPATH
    -u C_INCLUDE_PATH
    -u CPLUS_INCLUDE_PATH
    -u OBJC_INCLUDE_PATH
    -u SWIFTLY_BIN_DIR
    -u SWIFTLY_HOME_DIR
    -u SWIFTLY_TOOLCHAINS_DIR
    "PATH=/opt/homebrew/opt/ccache/libexec:$toolchain_root/bin:$PATH"
    "CCACHE_PATH=$toolchain_root/bin"
    "DYLD_LIBRARY_PATH=$toolchain_root/lib:$toolchain_root/lib/swift/macosx:${DYLD_LIBRARY_PATH:-}"
    # Explicit, not just inherited: CMake's internal TryCompile probes for
    # Swift (CMakeTestSwiftCompiler.cmake) run several process layers below
    # this (build-script -> build-script-impl -> cmake -> ninja -> swiftc),
    # and empirically SDKROOT/CMAKE_Swift_COMPILER set only via the parent
    # shell's `export` don't reliably survive that chain even though a
    # manual repro of the exact same swiftc invocation works fine with them
    # exported. Passing them directly in this env array removes any
    # dependency on inheritance working correctly at every hop.
    "SDKROOT=$SDKROOT"
    "CMAKE_Swift_COMPILER=$CMAKE_Swift_COMPILER"
  )

  local cmd=(
    python3 "$workspace/swift/utils/build-script"
    # Release stdlib with assertions enabled in compiler bits.
    --release
    --assertions
    # Enable the Android target.
    --android
    --android-ndk "$ndk_home"
    --android-arch "$arch"
    --android-api-level "$api_level"
    # Use the prebuilt host Swift tools from swift-toolchain and
    # target-capable Android clang from the NDK; don't rebuild either.
    --native-swift-tools-path "$toolchain_root/bin"
    --native-clang-tools-path "$ndk_prebuilt/bin"
    --host-cc "$ndk_prebuilt/bin/clang"
    --host-cxx "$ndk_prebuilt/bin/clang++"
    --skip-build-cmark
    --build-llvm=0
    --skip-local-build
    --cross-compile-build-swift-tools=False
    # build-script's default_stdlib_deployment_targets() always prepends
    # the *build host's* own target (macosx-arm64 here) ahead of whatever
    # --cross-compile-hosts adds. That makes CMake's Swift try_compile
    # probe fail for arm64-apple-macosx<host-version> (a broken system
    # Xcode-beta on this host, unrelated to us — see
    # CMAKE_Swift_COMPILER_WORKS below), which is dodged by overriding
    # --stdlib-deployment-targets down to just the Android target.
    # (Tried restoring the host-inclusive default once CMAKE_Swift_COMPILER_WORKS
    # existed, hoping it would fix an unrelated missing-ninja-rule error for
    # a swiftAndroid module target — it didn't change that error at all, so
    # this override stays; no need to also build the host stdlib we don't want.)
    --stdlib-deployment-targets="android-$arch"
    # Cross-compile structure: cmake's CMAKE_FIND_ROOT_PATH points at
    # $destdir so Foundation/libdispatch resolve their external C deps
    # there. Output goes to $destdir/usr/... directly (no per-host
    # subdir nesting).
    --cross-compile-hosts="android-$arch"
    --cross-compile-deps-path="$destdir"
    --cross-compile-append-host-target-to-destdir=False
    # Per-component installs. This corrected an earlier wrong assumption
    # here: cmake/modules/Libdispatch.cmake's ExternalProject_Add (gated on
    # SDK list membership) only ever builds libdispatch's *C* library with
    # -DENABLE_SWIFT=NO — it's nested inside swift's own configure purely
    # to give the stdlib's own overlays something to link against, and it
    # deliberately never installs headers or a Swift module anywhere
    # reachable. The actual installable libdispatch — built with
    # -DENABLE_SWIFT=YES, installing headers under $destdir/usr/lib/swift/
    # {dispatch,Block,os} *and* building the "Dispatch" Swift overlay module
    # (swift-corelibs-libdispatch/src/swift/*.swift) — is a separate
    # top-level build-script-impl product, gated like Foundation/xctest/
    # swift-testing on its own bare --libdispatch flag
    # (toggle_true('build_libdispatch')); --install-libdispatch alone only
    # controls whether an already-built one gets installed. Without
    # --libdispatch here, that top-level product was silently never even
    # attempted (no android-aarch64-macos/libdispatch-android-aarch64 build
    # directory ever appeared), so nothing ever produced a Dispatch
    # swiftmodule, and Foundation's Swift sources failed with "no such
    # module 'Dispatch'" the moment its C-dependency (LibXml2/OpenSSL/
    # DISPATCH_INCLUDE_PATH) issues were fixed and it actually started
    # compiling. Exactly the same class of bug as the missing bare
    # --foundation flag below.
    --build-swift-static-stdlib
    --libdispatch
    --foundation
    --xctest
    --swift-testing
    --install-swift
    --install-libdispatch
    --install-foundation
    --install-xctest
    --install-swift-testing
    --swift-install-components='compiler;clang-resource-dir-symlink;license;stdlib;sdk-overlay'
    # build-script's default --install-prefix on Darwin is hardcoded to
    # /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr
    # (see the identical issue already fixed in
    # swift-toolchain/build-macos.sh). Every product we build
    # directly here uses --install-destdir/--cross-compile-deps-path
    # consistently, so it doesn't matter in isolation — but swift-testing's
    # own build resolves its resource-dir by joining that Apple-specific
    # default prefix onto $destdir, landing on a path our actual stdlib
    # install never populates (it lands under $destdir/usr/..., matching
    # our C deps layout, not $destdir/Applications/Xcode.app/...), so its
    # linker can't find libswiftCore.so et al. Pin it to /usr explicitly so
    # every sub-product agrees on the same flat layout.
    --install-prefix=/usr
    --install-destdir="$destdir"
    # `--foundation-cmake-options` (like every `--<component>-cmake-options`
    # flag) maps to a single scalar bash variable in build-script-impl
    # (KNOWN_SETTINGS' generic per-component loop; see the
    # `eval ${varname}=$value` assignment in its arg-scanner). It is NOT an
    # accumulating list like --extra-swift-cmake-options — passing this flag
    # more than once silently drops every occurrence but the last. We used to
    # pass three separate `--foundation-cmake-options=` flags here and only
    # the final one (-DLIBXML2_INCLUDE_DIR) ever reached CMake; the
    # CMAKE_SHARED_LINKER_FLAGS clear and -DLIBXML2_LIBRARY override were
    # silently discarded, which is why CMakeCache.txt kept recording
    # LIBXML2_LIBRARY as NOTFOUND even though the exact same path was
    # supposedly being passed on the command line every time. Fold all of
    # them into one space-separated value instead (the consumption site does
    # a bare unquoted `(${!varname})` expansion, so whitespace-splitting into
    # separate -D args works correctly here).
    #
    # The individual overrides, still valid:
    #  - CMAKE_SHARED_LINKER_FLAGS='': cmake injects host-side -Wl flags into
    #    the cross build's CMAKE_SHARED_LINKER_FLAGS, which lld then rejects
    #    when targeting Android. Clearing the var lets Foundation use only
    #    the flags build-script intentionally sets. Mirrors finagolfin's
    #    sdks.yml:161.
    #  - LIBXML2_LIBRARY / LIBXML2_INCLUDE_DIR: Foundation's
    #    find_package(LibXml2) can't locate our cross-built libxml2.a under
    #    $destdir/usr even though it's genuinely there (and even resolves
    #    libxml2-config.cmake enough to report the correct version) —
    #    CMake's bundled FindLibXml2.cmake module apparently doesn't respect
    #    CMAKE_FIND_ROOT_PATH the way we'd expect here. Bypass the search
    #    entirely with explicit answers.
    #  - OPENSSL_*: same story one level removed — Foundation's
    #    find_package(CURL) resolves our cross-built CURLConfig.cmake, which
    #    itself does find_dependency(OpenSSL "3"); that nested find_package
    #    hits the identical CMAKE_FIND_ROOT_PATH blind spot and reports
    #    "missing: OPENSSL_CRYPTO_LIBRARY" despite correctly detecting the
    #    version from the headers. Bypass it the same way.
    #  - DISPATCH_INCLUDE_PATH: see stage_libdispatch_headers's comment
    #    above — the libdispatch built for this Android target never
    #    installs its headers anywhere reachable, so hand Foundation's own
    #    find_package(dispatch)-failure fallback the staged copy directly.
    --foundation-cmake-options="-DCMAKE_SHARED_LINKER_FLAGS= -DLIBXML2_LIBRARY=$destdir/usr/lib/libxml2.a -DLIBXML2_INCLUDE_DIR=$destdir/usr/include/libxml2 -DOPENSSL_CRYPTO_LIBRARY=$destdir/usr/lib/libcrypto.a -DOPENSSL_SSL_LIBRARY=$destdir/usr/lib/libssl.a -DOPENSSL_INCLUDE_DIR=$destdir/usr/include -DDISPATCH_INCLUDE_PATH=$libdispatch_headers"
    --libdispatch-cmake-options=-DCMAKE_SHARED_LINKER_FLAGS=''
    # Swift's top-level CMakeLists.txt runs its own generic
    # enable_language(Swift)/CMakeTestSwiftCompiler.cmake try_compile
    # against our swift-toolchain swiftc as part of configuring
    # the Android cross-compile project. It fails with "library not found
    # for -lSystem" on this host — some flag build-script-impl assembles
    # for this specific project trips it up (extensively bisected against
    # a from-scratch repro of the same source tree + every common/extra
    # cmake option we could identify; the same swiftc links real programs
    # fine standalone, so this is a false negative in the probe, not a
    # real compiler defect). Skip the probe outright rather than chase the
    # exact flag interaction further — this is the same sanctioned pattern
    # Swift's own wasistdlib.py product driver uses
    # (CMAKE_Swift_COMPILER_WORKS:BOOL=TRUE) for a comparable situation.
    --extra-swift-cmake-options=-DCMAKE_Swift_COMPILER_WORKS:BOOL=TRUE
    # CMake's Swift-language support (a comparatively new/incomplete corner
    # of CMake, historically developed mostly against Apple platforms)
    # leaves CMAKE_SHARED_LIBRARY_SUFFIX_Swift empty when cross-compiling to
    # Android from this host, and whatever it falls back to for naming
    # Swift-language shared-library targets lands on ".dylib" — even though
    # CMAKE_SHARED_LIBRARY_SUFFIX (the C/CXX-language one, correctly
    # Android-aware) is ".so" in the very same configure. The result: every
    # installed Swift shared library (libswiftCore, etc.) is written as
    # "*.dylib" instead of "*.so", so nothing downstream that links against
    # -lswiftCore can find it. Force the correct suffix explicitly.
    --extra-swift-cmake-options=-DCMAKE_SHARED_LIBRARY_SUFFIX_Swift:STRING=.so
    # swift/CMakeLists.txt clears CMAKE_OSX_ARCHITECTURES/CMAKE_OSX_SYSROOT/
    # CMAKE_OSX_DEPLOYMENT_TARGET only inside
    # `if(CMAKE_SYSTEM_NAME STREQUAL "Darwin" AND NOT CMAKE_CROSSCOMPILING)`
    # — i.e. only for the "building for macOS" case. It never considers
    # "cross-compiling to a non-Darwin target from a Darwin build machine",
    # so those three cache variables are left however CMake's own automatic
    # Darwin-host platform init populated them (arm64 + the system Xcode
    # SDK). A handful of targets (swiftDemangling, swiftCommandLineSupport,
    # swiftImageRegistrationObjectELF — built via a path that doesn't
    # separately strip these) pick that up and pass both
    # "-arch arm64 -isysroot .../MacOSX.sdk" *and* the correct
    # "-target aarch64-unknown-linux-android36 --sysroot=..." in the same
    # invocation; clang rejects -arch for a non-Darwin target outright.
    # Force all three empty explicitly rather than depend on that
    # Darwin-only gate.
    --extra-swift-cmake-options=-DCMAKE_OSX_ARCHITECTURES:STRING=
    --extra-swift-cmake-options=-DCMAKE_OSX_SYSROOT:PATH=
    --extra-swift-cmake-options=-DCMAKE_OSX_DEPLOYMENT_TARGET:STRING=
    # build-script's --build-swift-dynamic-sdk-overlay defaults to
    # `platform.system() != "Darwin"` — i.e. it conflates "build host is
    # Darwin" with "target doesn't need a separately-built SDK overlay",
    # true when both host and target are Apple platforms but wrong for an
    # Android cross-compile FROM a Darwin host. With the default (False)
    # here, build-script-impl injects
    # -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY:BOOL=FALSE positionally *after*
    # anything we could set via --extra-swift-cmake-options, so overriding
    # the cmake variable directly is a losing battle — this is the actual
    # flag that has to change. Effect of leaving it off: swift/CMakeLists.txt
    # never runs add_subdirectory(Platform), which is what builds the
    # "Android" platform overlay module (swiftAndroid); Cxx's std overlay
    # declares SWIFT_MODULE_DEPENDS_ANDROID Android, so ninja ends up with a
    # dependency on a swiftAndroid-swiftmodule-android-aarch64 target that
    # was never generated, and fails immediately with "missing and no known
    # rule to make it" before any real compilation starts.
    --build-swift-dynamic-sdk-overlay
    --build-swift-static-sdk-overlay
    # Build/test mechanics.
    --build-subdir="$subdir"
    --jobs="$jobs"
    --skip-test-swift
    --skip-test-foundation
    --skip-test-libdispatch
  )
  if (( reconfigure )); then
    cmd+=(--reconfigure)
  fi

  if (( dry_run )); then
    printf 'arch=%s triple=%s destdir=%q\n' "$arch" "$triple" "$destdir"
    if (( reconfigure )); then
      printf 'reconfigure_cleanup: remove top-level CMake cache and external-project state under %q\n' "$workspace/build/$subdir"
    fi
    printf 'build_command:'
    printf ' %q' "${clean_env[@]}" "${cmd[@]}"
    printf '\n'
    return
  fi

  echo "==> building Swift Android SDK for $arch ($triple)" >&2
  if (( reconfigure )); then
    reset_cmake_cache_for_subdir "$subdir"
  fi
  # $destdir is already populated with C deps by build_deps_for_arch();
  # do NOT rm -rf here or we'd nuke them. build-script installs the swift
  # stdlib + Foundation into the same tree (lib/swift, lib/swift_static,
  # …) alongside the existing lib/libcurl.a, lib/libssl.a, etc.
  #
  # No-op on a from-scratch destdir (stdlib isn't built yet). On a from-
  # scratch run, Foundation's CMake configure will fail once needing this
  # (see sync_swiftrt_to_ndk's comment above) after stdlib has already been
  # installed by this same invocation — simply re-running build-macos.sh
  # picks the sync up on the next attempt and resumes from Foundation.
  sync_swiftrt_to_ndk "$arch" "$destdir" "$ndk_prebuilt"
  "${clean_env[@]}" "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# Artifactbundle assembly
# ---------------------------------------------------------------------------
#
# Swift SDK artifactbundle layout. Mirrors swift.org's official Android bundle:
#
#   <bundle>/
#   ├── info.json
#   └── swift-android/
#       ├── swift-sdk.json
#       ├── swift-toolset.json
#       ├── scripts/setup-android-sdk.sh
#       ├── ndk-sysroot/                       (populated by setup script)
#       ├── swift-resources/
#       │   └── usr/lib/swift-<arch>/          (dynamic resources)
#       │   └── usr/lib/swift_static-<arch>/   (static resources)

assemble_bundle() {
  local variant_dir="$bundle_root/swift-android"
  local resources="$variant_dir/swift-resources"
  local resources_usr="$resources/usr"
  local resources_lib="$resources_usr/lib"
  local setup_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/setup-android-sdk.sh"

  echo "==> assembling artifactbundle at $bundle_root" >&2
  [[ -x "$setup_script" ]] || { echo "setup script missing or not executable: $setup_script" >&2; return 1; }

  rm -rf "$bundle_root"
  rm -f "$bundle_tar" "$bundle_sha"
  mkdir -p "$variant_dir/scripts" "$variant_dir/ndk-sysroot" "$resources_lib/swift"

  cat > "$bundle_root/info.json" <<EOF
{
  "schemaVersion": "1.0",
  "artifacts": {
    "swift-${source_id}-macos_android": {
      "variants": [
        {
          "path": "swift-android"
        }
      ],
      "version": "0.1",
      "type": "swiftSDK"
    }
  }
}
EOF

  # No "rootPath" here: the swift driver's -tools-directory is supplied by the
  # SWBAndroidPlatform plugin (NUCLEUS_SWIFT_BUILD_ANDROID_NDK_TOOLS_DIRECTORY),
  # derived from the discovered NDK. A toolset rootPath would translate to a
  # competing -tools-directory pointing at the bundle's ndk-toolchain/bin, and
  # because the toolset value is pushed last it wins; if that directory were
  # ever unpopulated the swift driver would fall back to the host clang and
  # leak host libc++/libunwind onto the Android link. Letting the plugin own
  # the tool path keeps the discovered NDK the single source of truth.
  cat > "$variant_dir/swift-toolset.json" <<'EOF'
{
  "cCompiler": { "extraCLIOptions": ["-fPIC"] },
  "swiftCompiler": { "extraCLIOptions": ["-Xclang-linker", "-fuse-ld=lld"] },
  "linker": { "extraCLIOptions": ["-z", "max-page-size=16384"] },
  "schemaVersion": "1.0"
}
EOF

  cat > "$resources/SDKSettings.json" <<'EOF'
{
  "DisplayName": "Swift Android SDK",
  "Version": "0.1",
  "VersionMap": {},
  "CanonicalName": "linux-android"
}
EOF

  cp -a "$setup_script" "$variant_dir/scripts/setup-android-sdk.sh"
  chmod +x "$variant_dir/scripts/setup-android-sdk.sh"

  cat > "$variant_dir/swift-sdk.json" <<EOF
{
  "schemaVersion": "4.0",
  "targetTriples": {
EOF
  local first=1
  for arch in "${selected_arches[@]}"; do
    local triple="${arch_triple[$arch]}"
    if (( first )); then
      first=0
    else
      printf ',\n' >> "$variant_dir/swift-sdk.json"
    fi
    cat >> "$variant_dir/swift-sdk.json" <<EOF
    "$triple": {
      "sdkRootPath": "ndk-sysroot",
      "swiftResourcesPath": "swift-resources/usr/lib/swift-$arch",
      "swiftStaticResourcesPath": "swift-resources/usr/lib/swift_static-$arch",
      "toolsetPaths": [ "swift-toolset.json" ]
    }
EOF
  done
  cat >> "$variant_dir/swift-sdk.json" <<'EOF'
  }
}
EOF

  local first_arch="${selected_arches[0]}"
  local first_usr="$build_root/install-$first_arch/usr"
  [[ -d "$first_usr" ]] || { echo "missing install tree for $first_arch: $first_usr" >&2; return 1; }

  mkdir -p "$resources_usr/include" "$resources_usr/share"
  cp -a "$first_usr/include/." "$resources_usr/include/"
  if [[ -d "$first_usr/share/swift" ]]; then
    cp -a "$first_usr/share/swift" "$resources_usr/share/swift"
  fi
  if [[ -d "$first_usr/lib/cmake" ]]; then
    cp -a "$first_usr/lib/cmake" "$resources_lib/cmake"
  fi
  if [[ -d "$first_usr/lib/pkgconfig" ]]; then
    cp -a "$first_usr/lib/pkgconfig" "$resources_lib/pkgconfig"
  fi

  [[ -d "$toolchain_root/include/swift" ]] || { echo "missing Swift bridging headers under $toolchain_root/include/swift" >&2; return 1; }
  [[ -f "$toolchain_root/include/module.modulemap" ]] || { echo "missing Swift include module map at $toolchain_root/include/module.modulemap" >&2; return 1; }
  rm -rf "$resources_usr/include/swift"
  cp -a "$toolchain_root/include/swift" "$resources_usr/include/swift"
  cp -a "$toolchain_root/include/module.modulemap" "$resources_usr/include/module.modulemap"

  for arch in "${selected_arches[@]}"; do
    local install_usr="$build_root/install-$arch/usr"
    local swift_src="$install_usr/lib/swift"
    local swift_static_src="$install_usr/lib/swift_static"
    local swift_dst="$resources_lib/swift-$arch"
    local swift_static_dst="$resources_lib/swift_static-$arch"

    [[ -d "$swift_src/android" ]] || { echo "missing dynamic Swift resources for $arch: $swift_src" >&2; return 1; }
    [[ -d "$swift_static_src/android" ]] || { echo "missing static Swift resources for $arch: $swift_static_src" >&2; return 1; }

    cp -a "$swift_src" "$swift_dst"
    cp -a "$swift_static_src" "$swift_static_dst"
    rm -f "$swift_dst/clang" "$swift_static_dst/clang"
    ln -s ../swift/clang "$swift_dst/clang"
    ln -s ../swift/clang "$swift_static_dst/clang"

    while IFS= read -r -d '' archive; do
      cp -a "$archive" "$resources_lib/"
      cp -a "$archive" "$swift_static_dst/android/"
    done < <(find "$install_usr/lib" -maxdepth 1 -type f -name '*.a' -print0)
  done

  if [[ -d "$resources_lib/pkgconfig" ]]; then
    while IFS= read -r -d '' pc; do
      sed -i '' -E \
        -e 's#^prefix=.*#prefix=${pcfiledir}/../..#' \
        -e 's#^exec_prefix=.*#exec_prefix=${prefix}#' \
        -e 's#^libdir=.*#libdir=${exec_prefix}/lib#' \
        -e 's#^includedir=.*#includedir=${prefix}/include#' \
        "$pc"
    done < <(find "$resources_lib/pkgconfig" -type f -name '*.pc' -print0)
  fi
  if [[ -d "$resources_lib/cmake" ]]; then
    while IFS= read -r -d '' cmake_file; do
      sed -i '' "s|$first_usr|\\\${_IMPORT_PREFIX}|g" "$cmake_file"
    done < <(find "$resources_lib/cmake" -type f -print0)
  fi

  tar -C "$install_root" -czf "$bundle_tar" "$(basename "$bundle_root")"
  sha256sum "$bundle_tar" | awk '{print $1}' > "$bundle_sha"
  echo "==> wrote $bundle_tar" >&2
  echo "==> wrote $bundle_sha" >&2
}

smoke_test() {
  echo "==> smoke test" >&2
  local readelf_tool="$ndk_home/toolchains/llvm/prebuilt/$ndk_host_tag/bin/llvm-readelf"
  if [[ ! -x "$readelf_tool" ]]; then
    echo "llvm-readelf missing at $readelf_tool" >&2
    return 1
  fi

  for arch in "${selected_arches[@]}"; do
    local lib="$build_root/install-$arch/usr/lib/swift/android/libswiftCore.so"
    if [[ ! -f "$lib" ]]; then
      echo "  $arch: libswiftCore.so missing at $lib" >&2
      return 1
    fi
    local needed libcxx_needed libstdcxx_needed cxx11_syms
    needed="$("$readelf_tool" -d "$lib" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p')"
    libcxx_needed=0
    if grep -qx 'libc++_shared.so' <<<"$needed"; then
      libcxx_needed=1
    fi
    libstdcxx_needed=$(grep -Ec '^libstdc\+\+' <<<"$needed" || true)
    cxx11_syms=$("$ndk_home/toolchains/llvm/prebuilt/$ndk_host_tag/bin/llvm-nm" --dynamic --demangle "$lib" 2>/dev/null | grep -c "std::__cxx11::" || true)
    echo "  $arch: libc++_shared needed=$libcxx_needed libstdc++ needed=$libstdcxx_needed libstdc++ ABI symbols=$cxx11_syms" >&2
    if (( libcxx_needed == 0 )); then
      echo "  $arch: FAIL - libswiftCore.so does not depend on libc++_shared.so" >&2
      return 1
    fi
    if (( libstdcxx_needed != 0 || cxx11_syms != 0 )); then
      echo "  $arch: FAIL - libstdc++ leaked into libswiftCore.so" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

if (( dry_run )); then
  printf 'toolchain_root=%q\n' "$toolchain_root"
  printf 'workspace=%q\n'      "$workspace"
  printf 'ndk_home=%q\n'       "$ndk_home"
  printf 'install_root=%q\n'   "$install_root"
  printf 'api_level=%s\n'      "$api_level"
  printf 'arches=%s\n'         "${selected_arches[*]}"
  printf 'bundle_tar=%q\n'     "$bundle_tar"
  for arch in "${selected_arches[@]}"; do
    build_one_arch "$arch"
  done
  exit 0
fi

mkdir -p "$log_root" "$build_root"
ln -sfn "$log_file" "$latest_log"
cat > "$run_info_file" <<RUNINFO
toolchain_root=$toolchain_root
workspace=$workspace
ndk_home=$ndk_home
install_root=$install_root
api_level=$api_level
arches=${selected_arches[*]}
log_file=$log_file
reconfigure=$reconfigure
RUNINFO

{
  ensure_ndk
  for arch in "${selected_arches[@]}"; do
    build_deps_for_arch "$arch"
    build_one_arch "$arch"
  done

  if (( skip_package )); then
    echo "==> --skip-package set; stopping before bundle assembly" >&2
    smoke_test
    exit 0
  fi

  smoke_test
  assemble_bundle
} 2>&1 | tee -a "$log_file"
