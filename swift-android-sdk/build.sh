#!/usr/bin/env bash
# Build a Swift SDK for Android against the locally-built
# swift-toolchain. See README.md for prerequisites.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/scripts/android-sdk-env.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Toolchain (host swift compiler). Required — this script does NOT build it.
toolchain_root="${NUCLEUS_SWIFT_TOOLCHAIN:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/release-6.4.x/usr}"

# Source workspace produced by swift-toolchain/build.sh.
# Reuses the existing checkout — no second clone, no separate patch state.
source_id="${NUCLEUS_SWIFT_SOURCE_ID:-release-6.4.x}"
workspace="${NUCLEUS_SWIFT_SOURCE_WORKSPACE:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-source/${source_id}}"

# NDK. Defaults to the AGP-managed NDK 30 already installed via sdkmanager,
# so a single NDK serves both this Swift Android SDK build and AGP/Kotlin
# native builds. Override NUCLEUS_ANDROID_NDK_HOME to point elsewhere.
#
# To fall back to the upstream Swift Android workgroup's tested NDK (r27d),
# unset NUCLEUS_ANDROID_NDK_HOME and set NUCLEUS_ANDROID_NDK_VERSION=r27d;
# the script will fetch and cache it under ~/.cache/nucleus/android-ndk/.
ndk_version="$(nucleus_android_ndk_version)"
ndk_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/android-ndk"
ndk_home="$(nucleus_android_ndk_home)"
ndk_url="https://dl.google.com/android/repository/android-ndk-${ndk_version}-linux.zip"

# Build/install output.
install_root="${NUCLEUS_SWIFT_ANDROID_INSTALL:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-android-sdks/${source_id}}"
build_root="$install_root/build"
log_root="${NUCLEUS_SWIFT_ANDROID_LOG_DIR:-$install_root/logs}"
log_file="${NUCLEUS_SWIFT_ANDROID_LOG:-$log_root/build-$(date +%Y%m%d-%H%M%S).log}"
latest_log="$log_root/latest.log"
run_info_file="$log_root/latest-run.env"

# Build-script knobs.
# API 36 (Android 16 "Baklava") is the highest API the current NDK 30 beta1
# supports targeting; check $NDK/meta/platforms.json "max" to verify on bump.
# Binaries built at API 36 run forward-compatibly on Android 17 (API 37) and
# beyond. Lift to 37 when the NDK ships API-37 platform stubs.
api_level="${NUCLEUS_ANDROID_API_LEVEL:-36}"
jobs="${NUCLEUS_SWIFT_ANDROID_BUILD_JOBS:-$(nproc)}"

# Bundle layout.
bundle_name="swift-${source_id}_android.artifactbundle"
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
Usage: build.sh [--dry-run] [--skip-ndk] [--skip-package] [--reconfigure]
                [--arch aarch64|x86_64] ...

Build a Swift SDK for Android against the locally-built
swift-toolchain. Run on Ubuntu with the apt packages listed in
apt-deps.txt installed AND swift-toolchain already built.

Flags:
  --dry-run       Print the resolved commands and exit.
  --skip-ndk      Use \$NUCLEUS_ANDROID_NDK_HOME as-is; skip the download.
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
    echo "missing host tool: $1 (install with: sudo apt install $2)" >&2
    exit 1
  fi
}
require_tool curl curl
require_tool unzip unzip
require_tool python3 python3
require_tool tar tar
require_tool sha256sum coreutils

# Host swift toolchain must be present.
host_swift="$toolchain_root/bin/swift"
host_swiftc="$toolchain_root/bin/swiftc"
host_clang="$toolchain_root/bin/clang"
host_clangxx="$toolchain_root/bin/clang++"
if [[ ! -x "$host_swift" ]]; then
  echo "host swift not found at $host_swift" >&2
  echo "build swift-toolchain first, or set NUCLEUS_SWIFT_TOOLCHAIN." >&2
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
  echo "build swift-toolchain first (it populates this workspace)," >&2
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
    echo "Rebuild swift-toolchain with that backend, or set NUCLEUS_SWIFT_TOOLCHAIN to a matching Swift 6.4 toolchain that has it." >&2
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

Install it via sdkmanager:

  sdkmanager --channel=3 "ndk;$ndk_version"

Or override the path:

  NUCLEUS_ANDROID_NDK_HOME=/path/to/ndk ./build.sh
EOF
    exit 1
  fi
  mkdir -p "$ndk_cache_dir"
  local zip="$ndk_cache_dir/android-ndk-${ndk_version}-linux.zip"
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
  # owned by swift-toolchain).
  local subdir="android-$arch"
  local ndk_prebuilt="$ndk_home/toolchains/llvm/prebuilt/linux-x86_64"

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
    "PATH=/usr/lib/ccache:$toolchain_root/bin:$PATH"
    "CCACHE_PATH=$toolchain_root/bin"
    "LD_LIBRARY_PATH=$toolchain_root/lib:$toolchain_root/lib/swift/linux:${LD_LIBRARY_PATH:-}"
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
    # Cross-compile structure: cmake's CMAKE_FIND_ROOT_PATH points at
    # $destdir so Foundation/libdispatch resolve their external C deps
    # there. Output goes to $destdir/usr/... directly (no per-host
    # subdir nesting).
    --cross-compile-hosts="android-$arch"
    --cross-compile-deps-path="$destdir"
    --cross-compile-append-host-target-to-destdir=False
    # Per-component installs. Foundation/libdispatch/xctest are implied
    # by the matching --install-* flags; swift-testing is the new
    # framework (parallels XCTest) and works at API ≥ 33 without the
    # libandroid-execinfo backport.
    --build-swift-static-stdlib
    --xctest
    --swift-testing
    --install-swift
    --install-libdispatch
    --install-foundation
    --install-xctest
    --install-swift-testing
    --swift-install-components='compiler;clang-resource-dir-symlink;license;stdlib;sdk-overlay'
    --install-destdir="$destdir"
    # Workaround: cmake injects host-side -Wl flags into the cross
    # build's CMAKE_SHARED_LINKER_FLAGS, which lld then rejects when
    # targeting Android. Clearing the var lets Foundation/libdispatch
    # use only the flags build-script intentionally sets. Mirrors
    # finagolfin's sdks.yml:161.
    --foundation-cmake-options=-DCMAKE_SHARED_LINKER_FLAGS=''
    --libdispatch-cmake-options=-DCMAKE_SHARED_LINKER_FLAGS=''
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
    "swift-${source_id}_android": {
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
  # leak host x86_64 libc++/libunwind onto the Android link. Letting the plugin
  # own the tool path keeps the discovered NDK the single source of truth.
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

    # FoundationXML.swiftmodule autolinks its private C shim for both dynamic
    # and static consumers. Upstream installs the archive only in the static
    # resource tree, so stage it beside the normal Android module as well.
    local cfxml_archive="$swift_static_dst/android/lib_CFXMLInterface.a"
    if [[ ! -f "$cfxml_archive" ]]; then
      echo "missing FoundationXML support archive for $arch: $cfxml_archive" >&2
      return 1
    fi
    install -m 0644 "$cfxml_archive" "$swift_dst/android/lib_CFXMLInterface.a"

    # The static FoundationXML archive pulls libxml2's compression and iconv
    # backends. Those archives are SDK-private implementation details and are
    # not represented by Swift module autolink metadata, so encode the complete
    # closure in the SDK's static response file rather than requiring every
    # consumer manifest to rediscover it.
    local static_args="$swift_static_dst/android/static-stdlib-args.lnk"
    if [[ ! -f "$static_args" ]]; then
      echo "missing static stdlib link arguments for $arch: $static_args" >&2
      return 1
    fi
    if ! grep -qF -- '-l_CFXMLInterface' "$static_args"; then
      # Upstream's response file has no trailing newline.
      printf '\n' >> "$static_args"
      cat >> "$static_args" <<'EOF'
-lFoundationXML
-l_CFXMLInterface
-lxml2
-lz
-llzma
-liconv
EOF
    fi

    while IFS= read -r -d '' archive; do
      cp -a "$archive" "$resources_lib/"
      cp -a "$archive" "$swift_static_dst/android/"
    done < <(find "$install_usr/lib" -maxdepth 1 -type f -name '*.a' -print0)
  done

  if [[ -d "$resources_lib/pkgconfig" ]]; then
    while IFS= read -r -d '' pc; do
      sed -i -E \
        -e 's#^prefix=.*#prefix=${pcfiledir}/../..#' \
        -e 's#^exec_prefix=.*#exec_prefix=${prefix}#' \
        -e 's#^libdir=.*#libdir=${exec_prefix}/lib#' \
        -e 's#^includedir=.*#includedir=${prefix}/include#' \
        "$pc"
    done < <(find "$resources_lib/pkgconfig" -type f -name '*.pc' -print0)
  fi
  if [[ -d "$resources_lib/cmake" ]]; then
    while IFS= read -r -d '' cmake_file; do
      sed -i "s|$first_usr|\\\${_IMPORT_PREFIX}|g" "$cmake_file"
    done < <(find "$resources_lib/cmake" -type f -print0)
  fi

  tar -C "$install_root" -czf "$bundle_tar" "$(basename "$bundle_root")"
  sha256sum "$bundle_tar" | awk '{print $1}' > "$bundle_sha"
  echo "==> wrote $bundle_tar" >&2
  echo "==> wrote $bundle_sha" >&2
}

smoke_test() {
  echo "==> smoke test" >&2
  local readelf_tool="$ndk_home/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
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
    cxx11_syms=$(nm --dynamic --demangle "$lib" 2>/dev/null | grep -c "std::__cxx11::" || true)
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
