#!/usr/bin/env bash
# Build the Swift release/6.4.x toolchain natively for macOS (Apple Silicon).
# Designed for macOS hosts. See README.md for prerequisites.
#
# This is deliberately a separate script from build.sh, not a branch inside
# it. build.sh bakes libc++ into the toolchain because Linux defaults to
# libstdc++; macOS already ships libc++ as the system C++ library and
# Swift's build-script has first-class Darwin support, so none of that
# machinery (LLVM_ENABLE_RUNTIMES, patchelf, ELF rpath/symlink plumbing,
# clang.cfg library-path injection) applies here. Swift-corelibs-foundation
# / swift-corelibs-libdispatch aren't built either — Darwin uses the
# OS-provided Foundation.framework / libdispatch.dylib.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${NUCLEUS_SWIFT_PLATFORM_ORCHESTRATED:-0}" != 1 ]]; then
  exec "$script_dir/../tools/nucleus" toolchain rebuild "$@"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-macos.sh is for macOS hosts; use build.sh on Linux." >&2
  exit 1
fi

if [[ -n "${NUCLEUS_SWIFT_SOURCE_REF:-}" ]]; then
  source_ref="$NUCLEUS_SWIFT_SOURCE_REF"
  source_scheme="${NUCLEUS_SWIFT_SOURCE_SCHEME:-$source_ref}"
  checkout_mode="${NUCLEUS_SWIFT_SOURCE_CHECKOUT_MODE:-branch}"
elif [[ -n "${NUCLEUS_SWIFT_SOURCE_TAG:-}" ]]; then
  source_ref="$NUCLEUS_SWIFT_SOURCE_TAG"
  source_scheme="${NUCLEUS_SWIFT_SOURCE_SCHEME:-main}"
  checkout_mode="${NUCLEUS_SWIFT_SOURCE_CHECKOUT_MODE:-tag}"
else
  source_ref="release/6.4.x"
  source_scheme="${NUCLEUS_SWIFT_SOURCE_SCHEME:-release/6.4.x}"
  checkout_mode="${NUCLEUS_SWIFT_SOURCE_CHECKOUT_MODE:-branch}"
fi
source_id="${NUCLEUS_SWIFT_SOURCE_ID:-$(printf '%s' "$source_ref" | sed -E 's#[^A-Za-z0-9._-]+#-#g')}"
arch="$(uname -m)"
# Kept separate from build.sh's Linux workspace/install paths: none of the
# patches under patches/ target Darwin, and a machine that builds both
# platforms (e.g. macOS host + a Linux container) should never let one
# platform's build tree or patches bleed into the other's.
workspace="${NUCLEUS_SWIFT_SOURCE_WORKSPACE:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-source/${source_id}-macos}"
install_root="${NUCLEUS_SWIFT_SOURCE_INSTALL:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/${source_id}-macos}"
log_root="${NUCLEUS_SWIFT_SOURCE_LOG_DIR:-$install_root/logs}"
log_file="${NUCLEUS_SWIFT_SOURCE_LOG:-$log_root/build-$(date +%Y%m%d-%H%M%S).log}"
latest_log="$log_root/latest.log"
run_info_file="$log_root/latest-run.env"
package_path="$install_root/swift-${source_id}-macos-${arch}.tar.gz"
package_candidate="$install_root/.swift-${source_id}-macos-${arch}.tar.gz.pending.$$"
detected_jobs="$(sysctl -n hw.ncpu)"
if (( detected_jobs > 16 )); then detected_jobs=16; fi
jobs="${NUCLEUS_SWIFT_BUILD_JOBS:-$detected_jobs}"
build_subdir="buildbot_macos"
preset_file="$workspace/nucleus-build-presets.ini"

# Resolve the host compiler to an absolute path, same reasoning as build.sh:
# Swift's build-script resolves --host-cc/--host-cxx relative to CWD if not
# absolute. /usr/bin/clang on macOS is a shim that forwards to the active
# Xcode's clang (via `xcode-select`), so this works whether Xcode.app or a
# bare toolchain is selected. Override with NUCLEUS_HOST_CC / NUCLEUS_HOST_CXX
# if a specific toolchain is desired.
find_real_clang() {
  local name="$1"
  if [[ -x "/usr/bin/$name" ]]; then
    printf '%s\n' "/usr/bin/$name"
    return 0
  fi
  command -v "$name" || true
}
host_cc="${NUCLEUS_HOST_CC:-$(find_real_clang clang)}"
host_cxx="${NUCLEUS_HOST_CXX:-$(find_real_clang clang++)}"
if [[ -z "$host_cc" || ! -x "$host_cc" ]]; then
  echo "clang not found (install Xcode.app and run: sudo xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi
if [[ -z "$host_cxx" || ! -x "$host_cxx" ]]; then
  echo "clang++ not found (install Xcode.app and run: sudo xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi

usage() {
  cat <<USAGE
Usage: build-macos.sh [--dry-run] [--reconfigure]

Build the pinned Swift source ref natively for macOS (Apple Silicon).
Requires full Xcode.app (not just Command Line Tools) plus cmake, ninja,
ccache from Homebrew. See README.md.

Flags:
  --dry-run                       Print resolved commands and exit.
  --reconfigure                   Force CMake reconfigure for all build-script
                                  projects. Use after changing preset CMake
                                  cache values.

Environment:
  NUCLEUS_SWIFT_SOURCE_REF        Swift source branch/ref. Default: ${source_ref}
  NUCLEUS_SWIFT_SOURCE_SCHEME     update-checkout branch scheme. Default: ${source_scheme}
  NUCLEUS_SWIFT_SOURCE_TAG        Legacy snapshot tag fallback.
  NUCLEUS_SWIFT_SOURCE_CHECKOUT_MODE
                                  branch or tag. Default: ${checkout_mode}
  NUCLEUS_SWIFT_SOURCE_ID         Filesystem/package identifier. Default: ${source_id}
  NUCLEUS_SWIFT_SOURCE_WORKSPACE  Checkout/build workspace. Default: ${workspace}
  NUCLEUS_SWIFT_SOURCE_INSTALL    Install root. Default: ${install_root}
  NUCLEUS_SWIFT_SOURCE_LOG_DIR    Durable log directory. Default: ${log_root}
  NUCLEUS_SWIFT_BUILD_JOBS        Parallel build jobs. Default: ${jobs}
  NUCLEUS_HOST_CC, NUCLEUS_HOST_CXX
                                  Host C/C++ compilers. Default: clang, clang++.
USAGE
}

dry_run=0
reconfigure=0
while (($#)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --reconfigure) reconfigure=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing host tool: $1 (install with: brew install $2)" >&2
    exit 1
  fi
}
require_tool cmake cmake
require_tool ninja ninja
require_tool python3 python3
require_tool git git
require_tool patch patch
require_tool tar tar
require_tool ccache ccache

# Same reasoning as build.sh: pin ccache's cache dir explicitly so
# build-script's XDG_CACHE_HOME redirection doesn't give every build
# subdir its own throwaway ccache.
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
mkdir -p "$CCACHE_DIR"
if ccache --max-size 30G >/dev/null 2>&1; then
  :
else
  echo "warning: failed to bump ccache max size; continuing with current limit" >&2
fi

build_cmd=(
  python3 "$workspace/swift/utils/build-script"
  --preset-file "$workspace/swift/utils/build-presets.ini"
  --preset-file "$preset_file"
  -j "$jobs"
  "--preset=nucleus_buildbot_macos,no_test"
  "host_cc=$host_cc"
  "host_cxx=$host_cxx"
  "install_destdir=$install_root"
)
if (( reconfigure )); then
  build_cmd+=(--reconfigure)
fi

update_checkout_args=(--clone --scheme "$source_scheme" --source-root "$workspace")
case "$checkout_mode" in
  branch) update_checkout_args+=(--reset-to-remote) ;;
  tag)    update_checkout_args+=(--tag "$source_ref") ;;
  *)
    echo "unsupported NUCLEUS_SWIFT_SOURCE_CHECKOUT_MODE: $checkout_mode" >&2
    exit 2
    ;;
esac

if (( dry_run )); then
  printf 'workspace=%q\n' "$workspace"
  printf 'install_root=%q\n' "$install_root"
  printf 'log_file=%q\n' "$log_file"
  printf 'installable_package=%q\n' "$package_path"
  printf 'source_ref=%q\n' "$source_ref"
  printf 'source_scheme=%q\n' "$source_scheme"
  printf 'host_cc=%q\n' "$host_cc"
  printf 'host_cxx=%q\n' "$host_cxx"
  printf 'arch=%q\n' "$arch"
  printf 'checkout_command: %q %q' python3 "$workspace/swift/utils/update-checkout"
  printf ' %q' "${update_checkout_args[@]}"
  printf '\n'
  printf 'build_command:'
  printf ' %q' "${build_cmd[@]}"
  printf '\n'
  exit 0
fi

mkdir -p "$install_root" "$log_root" "$(dirname "$log_file")"
ln -sfn "$log_file" "$latest_log"
cat > "$run_info_file" <<RUNINFO
workspace=$workspace
install_root=$install_root
source_ref=$source_ref
source_scheme=$source_scheme
source_id=$source_id
checkout_mode=$checkout_mode
log_file=$log_file
latest_log=$latest_log
installable_package=$package_path
RUNINFO
exec > >(tee -a "$log_file") 2>&1

echo "Swift source build log: $log_file"
echo "Swift source build package target: $package_path"
echo "Host compiler: $host_cc / $host_cxx"
ccache_dir="$(ccache --get-config cache_dir 2>/dev/null || echo unknown)"
ccache_max="$(ccache --get-config max_size 2>/dev/null || echo unknown)"
ccache_used="$(ccache -s 2>/dev/null | awk '/Cache size/ {print $4, $5; exit}')"
echo "ccache: dir=$ccache_dir max=$ccache_max used=${ccache_used:-unknown}"
ccache --zero-stats >/dev/null 2>&1 || true

mkdir -p "$workspace"

# Scrub linker/compiler flag env vars that would leak into cmake/clang
# invocations from an interactive shell config, same reasoning as build.sh.
unset LDFLAGS CFLAGS CXXFLAGS
unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS \
      CMAKE_MODULE_LINKER_FLAGS CMAKE_STATIC_LINKER_FLAGS

# Upstream product helpers may print their complete inherited environment in
# verbose command traces. The compiler graph does not need checkout or service
# credentials, so keep credential-shaped variables out of durable build logs.
scrub_sensitive_build_environment() {
  local variable_name
  while IFS='=' read -r variable_name _; do
    case "$variable_name" in
      *TOKEN*|*PASSWORD*|*PASSWD*|*SECRET*|*CREDENTIAL*|*PRIVATE_KEY*|*ACCESS_KEY*|*API_KEY*)
        unset "$variable_name"
        ;;
    esac
  done < <(env)
}

# Pin the compiler driver SwiftBuild discovers to the just-installed one, not
# whatever `swift` happens to be first on PATH. SWIFT_EXEC must select swiftc;
# selecting the swift interpreter prevents SwiftPM from emitting compiled
# manifest executables. See build.sh for the complete discovery rationale.
export SWIFT_EXEC="$install_root/usr/bin/swiftc"

# Isolate clang/swift's module cache to the workspace so a global
# $HOME/.cache/clang/ never gets touched across builds.
nucleus_xdg_cache="$workspace/.xdg-cache"
mkdir -p "$nucleus_xdg_cache"
export XDG_CACHE_HOME="$nucleus_xdg_cache"

if [[ ! -d "$workspace/swift/.git" ]]; then
  git clone https://github.com/swiftlang/swift.git "$workspace/swift"
fi

case "$checkout_mode" in
  branch)
    git -C "$workspace/swift" fetch origin "$source_ref"
    git -C "$workspace/swift" reset --hard FETCH_HEAD
    git -C "$workspace/swift" clean -fd
    ;;
  tag)
    git -C "$workspace/swift" fetch --tags origin "$source_ref"
    git -C "$workspace/swift" reset --hard "$source_ref"
    git -C "$workspace/swift" clean -fd
    ;;
esac

python3 "$workspace/swift/utils/update-checkout" "${update_checkout_args[@]}"

# Apply patches under patches/<repo>/ to each upstream subrepo via patch -p1
# with idempotency enforced by `patch -R --dry-run`. See patches/README.md.
#
# This used to be skipped entirely on macOS, on the assumption that every
# patch here targets Linux libc++/CxxStdlib wiring or Android cross-compile
# fixes and none touch Darwin code paths. That was true when this script
# only produced a host-only macOS toolchain, but swift-android-sdk
# now reuses this exact workspace and this exact swiftc to cross-compile to
# Android from macOS — so the Android-oriented patches (e.g.
# patches/swift/0001-...-cxxstdlib.patch's ClangImporter wchar.h fix) are
# just as necessary here as on Linux. Every patch is internally gated on the
# triple it targets (isOSLinux()/isAndroid()), so applying the full set
# unconditionally is a no-op for anything that only ever compiles for
# Darwin targets.
patches_dir="${NUCLEUS_SWIFT_PATCHES_DIR:-$script_dir/patches}"

# Keep repeated patch application deterministic after interrupted runs.
for patched_repo in swift swift-driver swift-build swiftpm indexstore-db sourcekit-lsp; do
  if [[ -d "$workspace/$patched_repo/.git" || -f "$workspace/$patched_repo/.git" ]]; then
    git -C "$workspace/$patched_repo" clean -fd
  fi
done

apply_patches() {
  local repo_patches="$1"
  local target_repo="$2"
  if [[ ! -d "$repo_patches" || ! -d "$target_repo" ]]; then
    return 0
  fi
  shopt -s nullglob
  local patch_file
  for patch_file in "$repo_patches"/*.patch; do
    if (cd "$target_repo" && patch -R -p1 --dry-run --silent < "$patch_file") >/dev/null 2>&1; then
      continue
    fi
    echo "applying $(basename "$patch_file") to $(basename "$target_repo")"
    if ! (cd "$target_repo" && patch -p1 --silent < "$patch_file"); then
      echo "failed to apply $patch_file to $target_repo" >&2
      exit 1
    fi
  done
  shopt -u nullglob
}

apply_patches "$patches_dir/swift" "$workspace/swift"
apply_patches "$patches_dir/swift-driver" "$workspace/swift-driver"
apply_patches "$patches_dir/swift-build" "$workspace/swift-build"
apply_patches "$patches_dir/swiftpm" "$workspace/swiftpm"
apply_patches "$patches_dir/indexstore-db" "$workspace/indexstore-db"
apply_patches "$patches_dir/sourcekit-lsp" "$workspace/sourcekit-lsp"

# Preset that drives the Swift build-script for the official Darwin product
# surface. Foundation and libdispatch remain OS-provided, and Darwin already
# links the SDK's libc++.tbd by default. The compiler, LLDB, embedded runtime,
# universal host tools, and Apple platform overlays are toolchain products.
cat > "$preset_file" <<PRESET
[preset: nucleus_buildbot_macos,no_test]
host-cc=%(host_cc)s
host-cxx=%(host_cxx)s
compiler-vendor=apple
release
test=0
validation-test=0
long-test=0
stress-test=0
test-installable-package=
toolchain-benchmarks=0

ios
tvos
watchos
xros
infer-cross-compile-hosts-on-darwin

lldb
no-lldb-assertions
lldb-configure-tests=0
lldb-use-system-debugserver

llbuild
swiftpm
swift-driver
swiftsyntax
swift-testing
swift-testing-macros
indexstore-db
sourcekit-lsp
swiftdocc
swiftformat
wasmkit
install-lldb
install-swiftpm
install-swift-driver
install-swiftsyntax
install-swift-testing
install-swift-testing-macros
install-sourcekit-lsp
install-swiftdocc
install-swiftformat
install-wasmkit

# swiftpm's bootstrap and the swift-testing-macros TestingMacros plugin
# are self-hosted: they configure/build against a *just-built* swiftc
# staged at install_destdir/install_prefix/bin/. Without install-llvm /
# install-swift / install-llbuild (to actually populate that staged
# tree) and install-destdir wired to a real value (upstream's own
# presets get this for free via mixin_linux_installation /
# mixin_osx_package_base; our preset mixes in nothing, so it must set
# this explicitly), that tree stays empty and both self-hosted stages
# fail with "not a full path to an existing compiler". install-prefix=
# /usr (not a nested Darwin .xctoolchain-style path) matches build.sh's
# Linux convention and keeps the final tree at install_destdir/usr/,
# which is what the rest of this script assumes.
#
# Deliberately NOT setting installable-package= here: build-script-impl's
# own packaging step assumes install-prefix looks like
# "SomeName.xctoolchain/usr" (it tars up dirname(install_prefix), i.e.
# the toolchain-bundle dir one level above usr/, plus writes an
# Info.plist / handles codesigning) — Apple's real toolchain-bundle
# ceremony, which our flat /usr layout doesn't have and doesn't need.
# With install-prefix=/usr, dirname is "/", and the packaging step tars
# an empty path and fails. We package the plain usr/ tree ourselves at
# the end of this script instead.
install-prefix=/usr
install-destdir=%(install_destdir)s
install-llvm
install-swift
install-llbuild

build-swift-stdlib-unittest-extra=0
build-embedded-stdlib=1
build-embedded-stdlib-cross-compiling=1
build-wasi-stdlib=0

extra-llvm-cmake-options=
    -DLLVM_CCACHE_BUILD:BOOL=ON
    -DLLVM_ENABLE_ASSERTIONS:BOOL=FALSE
extra-swift-cmake-options=
    -DSWIFT_ENABLE_ASSERTIONS:BOOL=FALSE
    -DSWIFTSYNTAX_ENABLE_ASSERTIONS:BOOL=FALSE
llbuild-cmake-options=
    -DBUILD_TESTING:BOOL=FALSE
PRESET

finish_build_script() {
  local status=$?
  if [[ -n "${package_candidate:-}" ]]; then
    rm -f -- "$package_candidate"
  fi
  if (( status != 0 )); then
    echo "Swift source build failed or was interrupted. Durable log: $log_file" >&2
  fi
  if command -v ccache >/dev/null 2>&1; then
    echo "─── ccache stats (this build) ───" >&2
    ccache -s 2>&1 | sed 's/^/  /' >&2
  fi
  exit "$status"
}
trap finish_build_script EXIT

mkdir -p "$install_root"
if [[ -d "$install_root/usr/bin" ]]; then
  rm -f \
    "$install_root/usr/bin/swift" \
    "$install_root/usr/bin/swiftc" \
    "$install_root/usr/bin/swift-frontend" \
    "$install_root/usr/bin/swift-driver" \
    "$install_root/usr/bin/swift-driver-new" \
    "$install_root/usr/bin/swift-legacy-driver" \
    "$install_root/usr/bin/swiftc-legacy-driver" \
    "$install_root/usr/bin/swift-help"
fi
scrub_sensitive_build_environment
"${build_cmd[@]}"

verify_product_surface() {
  local toolchain_root="$1"
  local label="$2"
  local required target target_output frontend_arches

  for required in \
    swift swiftc swift-frontend clang \
    lldb lldb-argdumper lldb-dap lldb-server repl_swift \
    sourcekit-lsp swift-format docc wasmkit; do
    if [[ ! -x "$toolchain_root/bin/$required" ]]; then
      echo "$label is missing required executable: bin/$required" >&2
      return 1
    fi
  done

  for required in \
    lib/libIndexStore.dylib \
    lib/libSwiftSourceKitClientPlugin.dylib \
    lib/libSwiftSourceKitPlugin.dylib \
    lib/swift/macosx \
    lib/swift/iphoneos \
    lib/swift/iphonesimulator \
    lib/swift/appletvos \
    lib/swift/appletvsimulator \
    lib/swift/watchos \
    lib/swift/watchsimulator \
    lib/swift/xros \
    lib/swift/xrsimulator \
    lib/swift/embedded \
    share/docc/render; do
    if [[ ! -e "$toolchain_root/$required" ]]; then
      echo "$label is missing required product: $required" >&2
      return 1
    fi
  done

  frontend_arches="$(lipo -archs "$toolchain_root/bin/swift-frontend")"
  for required in arm64 x86_64; do
    if [[ " $frontend_arches " != *" $required "* ]]; then
      echo "$label swift-frontend is missing Darwin architecture: $required" >&2
      return 1
    fi
  done

  target_output="$("$toolchain_root/bin/clang" --print-targets)"
  for target in aarch64 arm wasm32 x86; do
    if ! grep -Eq "^[[:space:]]+$target[[:space:]]+-" <<<"$target_output"; then
      echo "$label Clang is missing required LLVM target: $target" >&2
      return 1
    fi
  done
}

candidate=""
if [[ -x "$install_root/usr/bin/swiftc" ]]; then
  candidate="$install_root/usr/bin/swiftc"
fi
if [[ -z "$candidate" ]]; then
  echo "Swift build completed but no swiftc executable was found under $install_root" >&2
  exit 1
fi

"$candidate" --version
verify_product_surface "$install_root/usr" "assembled toolchain"

# Repackage into a same-filesystem candidate. The previously published
# tarball remains untouched until this candidate passes every smoke test.
rm -f -- "$package_candidate"
echo "--- Creating candidate installable package ---"
( cd "$install_root" && tar -c -z -f "$package_candidate" --uid=0 --gid=0 usr/ )

# Smoke test the package: extract it to a temp dir, build a tiny Swift
# package with it, confirm it runs.
smoke_root="$install_root/package-smoke"
package_toolchain="$smoke_root/toolchain"
smoke_home="$smoke_root/home"
smoke_tmp="$smoke_root/tmp"
smoke_src="$smoke_root/main.swift"
smoke_bin="$smoke_root/main"
package_dir="$smoke_root/swiftpm"

rm -rf "$smoke_root"
mkdir -p "$package_toolchain" "$smoke_home" "$smoke_tmp" "$package_dir"

echo "--- Smoking installable package ---"
tar -x -z -f "$package_candidate" -C "$package_toolchain"

toolchain_bin="$package_toolchain/usr/bin"
verify_product_surface "$package_toolchain/usr" "installable package"

# Unlike Linux (no SDK concept — swiftc just needs glibc), macOS swiftc
# resolves libSystem and friends via an SDK path. It normally falls
# back to `xcrun --sdk macosx --show-sdk-path`, but that lookup doesn't
# reliably survive inside `env -i`'s stripped environment, so link
# fails with "ld: library 'System' not found". Resolve it up front in
# the real environment and pass it through explicitly via SDKROOT.
macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
clean_env=(
  env -i
  "HOME=$smoke_home"
  "USER=${USER:-nucleus}"
  "TMPDIR=$smoke_tmp"
  "PATH=$toolchain_bin:/usr/bin:/bin"
  "SDKROOT=$macos_sdk_path"
)

printf '%s\n' 'print("swift package smoke ok")' > "$smoke_src"
"${clean_env[@]}" "$toolchain_bin/swift" --version
"${clean_env[@]}" "$toolchain_bin/swiftc" -g "$smoke_src" -o "$smoke_bin"
"$smoke_bin"

embedded_smoke_src="$smoke_root/embedded.swift"
embedded_smoke_ir="$smoke_root/embedded.ll"
cat > "$embedded_smoke_src" <<'SWIFT'
public func nucleusEmbeddedSmoke() -> Int { 42 }
SWIFT
"${clean_env[@]}" "$toolchain_bin/swiftc" \
  -target arm64-apple-none-macho \
  -wmo \
  -enable-experimental-feature Embedded \
  -emit-ir \
  "$embedded_smoke_src" \
  -o "$embedded_smoke_ir"

"${clean_env[@]}" "$toolchain_bin/lldb" \
  --batch \
  -o 'breakpoint set --name main' \
  -o run \
  -o 'thread backtrace' \
  "$smoke_bin"

python3 "$script_dir/validate-products.py" \
  --toolchain "$package_toolchain/usr" \
  --platform macos \
  --work-directory "$smoke_root/toolchain-products"

(
  cd "$package_dir"
  cat > Package.swift <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "NucleusPackageSmoke",
    targets: [
        .executableTarget(name: "NucleusPackageSmoke"),
    ]
)
SWIFT
  mkdir -p Sources/NucleusPackageSmoke
  cp "$smoke_src" Sources/NucleusPackageSmoke/main.swift
  "${clean_env[@]}" "$toolchain_bin/swift" build -v
)

rm -rf "$smoke_root"
echo "Installable package smoke passed"

# rename(2) within install_root publishes the complete, verified artifact in
# one step. A failed or interrupted build leaves the previous package intact.
mv -f -- "$package_candidate" "$package_path"
package_candidate=""
echo "Installable package published"
echo "Swift toolchain available at:    $install_root/usr"
echo "Distributable tarball available: $package_path"
echo "Build log retained at:           $log_file"
