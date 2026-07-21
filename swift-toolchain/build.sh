#!/usr/bin/env bash
# Build the Swift release/6.4.x toolchain with libc++ baked in.
# Designed for Ubuntu hosts. See README.md for prerequisites.

set -euo pipefail

if [[ "${NUCLEUS_SWIFT_PLATFORM_ORCHESTRATED:-0}" != 1 ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec "$script_dir/../tools/nucleus" toolchain rebuild "$@"
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
workspace="${NUCLEUS_SWIFT_SOURCE_WORKSPACE:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-source/${source_id}}"
install_root="${NUCLEUS_SWIFT_SOURCE_INSTALL:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/${source_id}}"
log_root="${NUCLEUS_SWIFT_SOURCE_LOG_DIR:-$install_root/logs}"
log_file="${NUCLEUS_SWIFT_SOURCE_LOG:-$log_root/build-$(date +%Y%m%d-%H%M%S).log}"
latest_log="$log_root/latest.log"
run_info_file="$log_root/latest-run.env"
package_path="$install_root/swift-${source_id}-linux.tar.gz"
package_candidate="$install_root/.swift-${source_id}-linux.tar.gz.pending.$$"
assembly_root="$install_root/.assembly.$$"
published_usr="$install_root/usr"
published_usr_backup="$install_root/.usr.previous.$$"
fingerprint_root="$workspace/.nucleus-fingerprints"
phase_events="$log_root/latest-phases.tsv"
jobs="${NUCLEUS_SWIFT_BUILD_JOBS:-$(nproc)}"
# Default linker is lld. We tried mold as the default (which is 2-5×
# faster than lld on C++ link-heavy phases) but hit a hard mold
# internal assertion when linking SwiftPM's `libSwiftPMDataModel.so`:
#
#     ld.mold: ./src/output-chunks.cc:2351:
#       mold::EhFrameSection<X86_64>::copy_buf::<lambda>:
#       Assertion `rel.r_offset - fde.input_offset < contents.size()'
#       failed.
#
# Swift's emitted `.eh_frame` data contains relocations mold's frame
# writer can't process. Not a cmake flag we can fix; an actual mold
# bug. Sticking with lld unblocks the toolchain build. The 5-10%
# wall-time loss is acceptable — Nucleus's own link uses the
# toolchain's bundled lld anyway, so the toolchain linker choice
# doesn't affect downstream iteration speed.
linker="lld"
preset_file="$workspace/nucleus-build-presets.ini"
cmake_overrides_file="$workspace/nucleus-swift-cmake-overrides.cmake"

# Resolve the host compiler to an absolute path. Swift's build-script resolves
# --host-cc/--host-cxx relative to CWD if not absolute. Prefer the existing
# Nucleus bootstrap toolchain's Clang: it defaults to the bundled libc++, which
# keeps LLVM/Clang/Swift native objects ABI-compatible with Swift-in-Swift
# compiler modules emitted by that same bootstrap toolchain. A first build can
# fall back to the system Clang or override both paths explicitly.
bootstrap_toolchain_root="${NUCLEUS_SWIFT_BOOTSTRAP_ROOT:-/opt/nucleus-swift/current/usr}"
find_real_clang() {
  local name="$1"
  if [[ -x "$bootstrap_toolchain_root/bin/$name" ]]; then
    printf '%s\n' "$bootstrap_toolchain_root/bin/$name"
    return 0
  fi
  if [[ -x "/usr/bin/$name" ]]; then
    printf '%s\n' "/usr/bin/$name"
    return 0
  fi
  command -v "$name" || true
}
host_cc="${NUCLEUS_HOST_CC:-$(find_real_clang clang)}"
host_cxx="${NUCLEUS_HOST_CXX:-$(find_real_clang clang++)}"
if [[ -z "$host_cc" || ! -x "$host_cc" ]]; then
  echo "clang not found (install with: sudo apt install clang)" >&2
  exit 1
fi
if [[ -z "$host_cxx" || ! -x "$host_cxx" ]]; then
  echo "clang++ not found (install with: sudo apt install clang)" >&2
  exit 1
fi
host_toolchain_root="$(cd "$(dirname "$host_cxx")/.." && pwd -P)"

# The top-level build-script consumes --host-cc/--host-cxx, but nested CMake
# and SwiftPM helper builds consult CC/CXX directly. They must use the same
# compiler and C++ standard-library ABI as the main LLVM/Swift build.
export CC="$host_cc"
export CXX="$host_cxx"

usage() {
  cat <<USAGE
Usage: build.sh [--dry-run] [--reconfigure]

Build the pinned Swift source ref with libc++ baked into the toolchain.
Run on Ubuntu with the apt packages listed in apt-deps.txt installed.

Flags:
  --dry-run                       Print resolved commands and exit.
  --reconfigure                   Force CMake reconfigure for all build-script
                                  projects. Use after changing preset CMake
                                  cache values such as LLVM_TARGETS_TO_BUILD.

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
  NUCLEUS_SWIFT_BOOTSTRAP_ROOT    Bootstrap toolchain root. Default: ${bootstrap_toolchain_root}
  NUCLEUS_HOST_CC                 Host C compiler override.
  NUCLEUS_HOST_CXX                Host C++ compiler override.
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

# Verify host tools are present.
require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing host tool: $1 (install with: sudo apt install $2)" >&2
    exit 1
  fi
}
require_tool clang clang
require_tool clang++ clang
require_tool cmake cmake
require_tool ninja ninja-build
require_tool python3 python3
require_tool git git
require_tool patch patch
require_tool tar tar
require_tool patchelf patchelf
require_tool ccache ccache
require_tool flock util-linux
require_tool sha256sum coreutils

# Pin ccache's cache dir explicitly so the build-script's
# `--relocate-xdg-cache-home-under-build-subdir` (which redirects
# child-process `XDG_CACHE_HOME` to live under the build dir) does
# not redirect ccache to a fresh, per-build-subdir location.
# `CCACHE_DIR` takes precedence over `XDG_CACHE_HOME` in ccache, so
# exporting it here ensures every nested cmake/ninja/clang invocation
# reads and writes the same persistent ccache regardless of how the
# build-script massages the child env.
#
# Without this, every `--build-subdir` (or every nuked build dir)
# starts with an empty ccache that caps at the default 5 GiB and dies
# with the build tree, defeating the iteration speedup entirely.
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
mkdir -p "$CCACHE_DIR"

# Bump ccache's max size to comfortably hold a full LLVM + Swift build
# (~3-5 GiB compiled cache per configuration, multiplied by 4-6 build
# configs we cycle through during toolchain iteration). The default
# 5 GiB fills and starts evicting hot entries on the second rebuild,
# defeating the cache. Bumping to 30 GiB gives headroom for ~6-10
# concurrent build flavors (release/debug/asan/etc.). Idempotent —
# ccache stores the setting in the cache config.
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
  "--preset=nucleus_buildbot_linux,no_test"
  "linker=$linker"
  "host_cc=$host_cc"
  "host_cxx=$host_cxx"
  "cmake_overrides=$cmake_overrides_file"
  "install_destdir=$assembly_root"
  "installable_package=$package_candidate"
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
  printf 'assembly_root=%q\n' "$assembly_root"
  printf 'log_file=%q\n' "$log_file"
  printf 'installable_package=%q\n' "$package_path"
  printf 'source_ref=%q\n' "$source_ref"
  printf 'source_scheme=%q\n' "$source_scheme"
  printf 'host_cc=%q\n' "$host_cc"
  printf 'host_cxx=%q\n' "$host_cxx"
  printf 'linker=%q\n' "$linker"
  printf 'checkout_command: %q %q' python3 "$workspace/swift/utils/update-checkout"
  printf ' %q' "${update_checkout_args[@]}"
  printf '\n'
  printf 'build_command:'
  printf ' %q' "${build_cmd[@]}"
  printf '\n'
  exit 0
fi

mkdir -p "$log_root" "$(dirname "$log_file")"
exec 9>"$install_root/.build.lock"
if ! flock -n 9; then
  echo "another swift-toolchain build is already using $install_root" >&2
  exit 1
fi
ln -sfn "$log_file" "$latest_log"
cat > "$run_info_file" <<RUNINFO
workspace=$workspace
install_root=$install_root
assembly_root=$assembly_root
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

# Reset the per-run ccache stats counter so the post-build print
# (after the python build-script returns) reflects this build only,
# not cumulative lifetime numbers. Zeroing happens early enough that
# the configure-time bare-compiler invocations (which bypass ccache
# anyway because LLVM_CCACHE_BUILD only wraps production compiles)
# don't pollute the hit-rate number.
ccache --zero-stats >/dev/null 2>&1 || true

mkdir -p "$workspace"

# Scrub the inherited environment of variables that would pollute the
# build's cmake/clang/swiftc invocations.
#
# 1. Linker flag env vars (`LDFLAGS`, `CMAKE_*_LINKER_FLAGS`): cmake
#    reads these at configure time and bakes them into every
#    sub-build's link command. A `-fuse-ld=mold` baked in via the
#    user's interactive shell config (a common setup for speed on
#    casual builds) breaks swiftc invocations — swiftc uses
#    `-use-ld=`, not the clang `-fuse-ld=` syntax — and mold can't
#    find the build-tree libc++ libraries swift needs.
#
# Inherited compiler and linker flags violate the Ubuntu-native toolchain
# invariant. Scrub them once here so every sub-build receives the same host
# contract.
unset LDFLAGS CFLAGS CXXFLAGS
unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS \
      CMAKE_MODULE_LINKER_FLAGS CMAKE_STATIC_LINKER_FLAGS

# Pin the toolchain SwiftBuild discovers to the just-installed one,
# not whatever `swift` happens to be first on PATH.
#
# Background: the late phases of the build (indexstore-db,
# sourcekit-lsp) build via SwiftPM, which now uses SwiftBuild under
# the hood. SwiftBuild's plugin
# (swift-build/Sources/SWBGenericUnixPlatform/Plugin.swift) discovers
# the toolchain by first reading `SWIFT_EXEC`, then searching PATH
# for `swift`. It then asserts the parent dir is `usr/bin` or
# `usr/local/bin` — anything else throws "Unexpected toolchain layout
# for Swift installation path: …".
#
# Users with `swiftly` installed have `~/.local/share/swiftly/bin` on
# PATH (and we need it on PATH for the *bootstrap* swift-driver),
# but swiftly's `bin/` is not a `usr/bin/` layout, so SwiftBuild
# fails its assertion as soon as PATH is searched.
#
# Setting SWIFT_EXEC short-circuits the PATH search. If the install
# hasn't produced this binary yet (early phases), the env var points
# at a non-existent path and is silently ignored by the
# `compactMap { $0 }.first(where: fs.exists)` lookup. Once the install
# step writes `<install>/usr/bin/swift`, SwiftBuild picks it up
# unambiguously.
export SWIFT_EXEC="$assembly_root/usr/bin/swift"

# Isolate clang/swift's module cache to the workspace so a global
# $HOME/.cache/clang/ never gets touched across builds.
nucleus_xdg_cache="$workspace/.xdg-cache"
mkdir -p "$nucleus_xdg_cache"
export XDG_CACHE_HOME="$nucleus_xdg_cache"

# Tell both the bootstrap and build-tree Clang installations where to find the
# libc++ matching their ABI. The bootstrap paths are needed before the runtimes
# subbuild has populated <llvm-build>/lib; the build paths take precedence as
# soon as the new runtimes exist.
#
# Background: clang defaults to `-lc++` via
# `CLANG_DEFAULT_CXX_STDLIB=libc++`. clang's default library search
# (per `-print-search-dirs`) covers `<resource-dir>` and the
# gcc-toolchain lib paths, but not the bare `<llvm-build>/lib/` where
# libc++.so lives during this build.
#
# LIBRARY_PATH covers link-time lookup. LD_LIBRARY_PATH lets CMake probes and
# freshly linked host tools execute before their final install RPATH exists.
llvm_build_lib="$workspace/build/buildbot_linux/llvm-linux-x86_64/lib"
host_toolchain_lib="$host_toolchain_root/lib"
host_swift_linux_lib="$host_toolchain_root/lib/swift/linux"
export LIBRARY_PATH="$llvm_build_lib:$host_toolchain_lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$llvm_build_lib:$host_toolchain_lib:$host_swift_linux_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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
patches_dir="${NUCLEUS_SWIFT_PATCHES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patches}"

# update-checkout resets tracked files but deliberately retains untracked files.
# Patch-created fixtures and patch(1) .orig files from an interrupted run would
# therefore make the next application only partially reversible. These are
# generated upstream worktrees, so clean precisely the repositories we patch
# before applying the authoritative patch set.
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

# Top-level CMake include for the LLVM build. Handles two related
# tweaks:
#
#   1. Swift's build-script-impl creates <llvm-build>/include as a
#      symlink to /usr/include/c++ so the freshly-built clang's compile
#      tests find system C++ headers. On Ubuntu clang finds those
#      automatically; the symlink is harmless when it's just a redirect,
#      but it makes libcxx's configure_file() write through to
#      /usr/include/c++/v1, which is root-owned. Replace the symlink
#      with a real directory.
#
#   2. libcxx's CMakeLists writes its generated __config_site /
#      module.modulemap to ${LLVM_BINARY_DIR}/include/c++/v1/ via
#      configure_file(), but configure_file does not create the parent
#      directory. Pre-create it so the runtimes sub-build's libcxx
#      configure step succeeds.
cat > "$cmake_overrides_file" <<'OVERRIDES'
# Generated by swift-toolchain.
foreach(_nucleus_cxx_root IN ITEMS "${LLVM_BINARY_DIR}" "${CMAKE_BINARY_DIR}")
  if(NOT "${_nucleus_cxx_root}" STREQUAL "")
    set(_nucleus_cxx_dir "${_nucleus_cxx_root}/include/c++")
    if(IS_SYMLINK "${_nucleus_cxx_dir}")
      file(REMOVE "${_nucleus_cxx_dir}")
    endif()
    file(MAKE_DIRECTORY "${_nucleus_cxx_dir}/v1")
  endif()
endforeach()

# Wire BlocksRuntime into every shared/module link via `--as-needed`
# so only DSOs that actually reference Blocks runtime symbols
# (`_NSConcreteGlobalBlock`, `_Block_object_assign`, …) — i.e.
# `libIndexStore.so` — pick up the `DT_NEEDED` entry. The
# `--no-as-needed` after restores the linker's default mode for any
# subsequent `-l` flags HandleLLVMOptions or per-target rules inject.
#
# This setup lives in the overrides file rather than as
# `-DCMAKE_*_LINKER_FLAGS` because Swift's build-script splits
# `--extra-llvm-cmake-options` values on commas, mangling
# `-Wl,--as-needed,...` into separate cmake arguments.
set(_nucleus_blocks_link_flags
    "-Wl,--as-needed,-lBlocksRuntime,--no-as-needed")
# Write unconditionally (no read-modify-write): `CMAKE_PROJECT_TOP_LEVEL_INCLUDES`
# only fires on the top-level project() call, but the cache entry itself
# persists across reconfigures. Appending to the cached value would
# duplicate the flag (and any earlier garbage) on every rebuild.
# HandleLLVMOptions.cmake adds its own append (`-Wl,-z,defs` etc.) at
# scope level after this, so its flags are not lost.
foreach(_kind IN ITEMS EXE SHARED MODULE)
  set("CMAKE_${_kind}_LINKER_FLAGS"
      "${_nucleus_blocks_link_flags}"
      CACHE STRING "Linker flags (set by nucleus-swift-cmake-overrides)" FORCE)
endforeach()
OVERRIDES

# Preset that drives the Swift build-script. libc++ is baked in via
# LLVM_ENABLE_RUNTIMES + CLANG_DEFAULT_CXX_STDLIB.
cat > "$preset_file" <<'PRESET'
[preset: nucleus_buildbot_linux,no_test]
mixin-preset=
    mixin_linux_install_components_with_clang

# Do not inherit `buildbot_linux`: that release/CI preset deliberately carries
# `reconfigure`, all test modes, LLDB, editor tools, and package benchmarks.
# A bare flag inherited by a preset cannot be negated later. This preset names
# the distributable Nucleus graph explicitly so ordinary invocations preserve
# every CMake/Ninja build directory. `build.sh --reconfigure` is the sole
# reconfiguration control.
#
# `use-linker=` (build-script's `--use-linker`) is intentionally NOT
# passed. Swift release/6.4.x's build-script hardcodes argparse
# `choices=['gold', 'lld']`, so passing `--use-linker=mold` fails with
# `invalid choice`. The flag only affects `CLANG_DEFAULT_LINKER` in
# the produced toolchain (see llvm.py's `_use_linker` macro), which
# we set directly in `extra-llvm-cmake-options` below. LLVM's own
# self-link uses mold via `-DLLVM_USE_LINKER=mold` (also below).
host-cc=%(host_cc)s
host-cxx=%(host_cxx)s
build-subdir=buildbot_linux
release
no-assertions
no-swift-stdlib-assertions
swift-enable-ast-verifier=0
test=0
validation-test=0
long-test=0
stress-test=0
lldb=0
install-lldb=0
skip-build-lldb
# sourcekit-lsp and indexstore-db are disabled.
#
# Their build phase invokes swift-frontend's `-interpret` JIT mode on
# swift-foundation's Package.swift, which crashes in current
# release/6.4.x (LLVM ORC fails to materialize PackageDescription
# symbols, then swift-backtrace crashes during the dump). Reproduces
# in `env -i` so it isn't caused by anything we set in the build.
# Nothing in nucleus's build depends on sourcekit-lsp or
# indexstore-db; they're useful for editor LSP integration but not for
# nucleus compilation.
#
# Revisit once 6.4 stabilizes or split out as separate SwiftPM-driven
# builds against the installed toolchain (same plan slot as splitting
# foundation/libdispatch).
sourcekit-lsp=0
indexstore-db=0
foundation
libdispatch
xctest
llbuild
swiftpm
swift-driver
swift-testing
swift-testing-macros
swiftdocc=0
swiftformat=0
wasmkit=0
install-sourcekit-lsp=0
install-llvm
install-static-linux-config
install-swift
install-llbuild
install-foundation
install-libdispatch
install-xctest
install-swiftsyntax
install-swiftpm
install-swift-driver
install-swift-testing
install-swift-testing-macros
install-swiftdocc=0
install-swiftformat=0
install-wasmkit=0
install-prefix=/usr
install-destdir=%(install_destdir)s
installable-package=%(installable_package)s
relocate-xdg-cache-home-under-build-subdir
build-ninja
build-swift-static-stdlib=1
build-swift-static-sdk-overlay=0
build-swift-stdlib-unittest-extra=0
build-embedded-stdlib=0
build-embedded-stdlib-cross-compiling=0
build-wasi-stdlib=0
stdlib-deployment-targets=linux-x86_64
build-stdlib-deployment-targets=linux-x86_64
extra-llvm-cmake-options=
    -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES:PATH=%(cmake_overrides)s
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH:BOOL=TRUE
    -DCLANG_DEFAULT_LINKER:STRING=%(linker)s
    # `LLVM_USE_LINKER` controls what the LLVM stage-1 build uses to
    # link its own binaries (clang, lld, llvm-config, …). Distinct
    # from `CLANG_DEFAULT_LINKER`, which only affects the produced
    # clang's downstream link behavior. Setting both to mold means
    # every link step in the toolchain build (host LLVM build, plus
    # everything downstream Nucleus builds) uses mold.
    -DLLVM_USE_LINKER:STRING=%(linker)s
    # Enable Clang's Blocks language extension for every TU in the
    # LLVM stage. The Apple fork's
    # `clang/tools/IndexStore/IndexStore.exports` lists block-callback
    # variants (`indexstore_*_apply`) whose definitions in
    # `IndexStore.cpp` are guarded by `#if INDEXSTORE_HAS_BLOCKS`,
    # which is in turn gated on `__has_feature(blocks)`. Host Ubuntu
    # clang doesn't enable Blocks by default, so without `-fblocks`
    # the apply implementations are stripped and the version-script
    # link fails under modern lld's `--no-undefined-version` default.
    # Turning Blocks on lets the implementations compile, satisfying
    # the version script and matching the API surface Apple's macOS
    # toolchains expose. Requires `libblocksruntime-dev` from
    # `apt-deps.txt` for `Block.h` and the runtime lib.
    # `-mcx16` is NOT passed at the top level here even though it's
    # passed to the runtimes subbuild below. The build-script
    # tokenizes `--extra-llvm-cmake-options` values on whitespace, so
    # `-DCMAKE_C_FLAGS:STRING=-fblocks -mcx16` would split into two
    # cmake arguments (`-fblocks` becomes the value, `-mcx16` becomes
    # a free-standing arg that cmake rejects). The top-level CMAKE_*
    # _FLAGS only affect host LLVM binaries (clang, lld, llvm-tblgen,
    # etc.) which run on the provisioned Ubuntu host where libatomic is
    # available. The shipped libc++ / libc++abi /
    # libunwind / asan-runtime artifacts come from the runtimes
    # subbuild, and that's where `-mcx16` actually buys us the
    # `NEEDED libatomic.so.1` removal — see `RUNTIMES_CMAKE_ARGS`
    # below.
    -DCMAKE_C_FLAGS:STRING=-fblocks
    -DCMAKE_CXX_FLAGS:STRING=-fblocks
    # `CMAKE_*_LINKER_FLAGS` are set in `nucleus-swift-cmake-overrides.cmake`
    # (loaded via `CMAKE_PROJECT_TOP_LEVEL_INCLUDES` above). They can't
    # live here because Swift's build-script splits cmake-options values
    # on commas, mangling `-Wl,--as-needed,...` into separate cmake args.
    -DCLANG_DEFAULT_CXX_STDLIB:STRING=libc++
    # Wrap C/C++ compile commands in ccache. LLVM injects this via
    # CMake's `RULE_LAUNCH_COMPILE` so only production compiles route
    # through ccache; `try_compile` feature detection during configure
    # still runs the bare compiler, sidestepping the historic concern
    # about ccache returning stale "this flag works" results. First
    # build populates the cache; subsequent rebuilds with the same source
    # pin reuse most translation units. Bumping host_cc/host_cxx in build.sh
    # is not needed —
    # this flag and the absolute-path host_cc are independent.
    -DLLVM_CCACHE_BUILD:BOOL=ON
    -DLLVM_ENABLE_RUNTIMES:STRING=compiler-rt;libcxx;libcxxabi;libunwind
    -DLIBCXX_INCLUDE_TESTS:BOOL=OFF
    -DLIBCXX_INCLUDE_BENCHMARKS:BOOL=OFF
    -DLIBCXXABI_INCLUDE_TESTS:BOOL=OFF
    -DLIBUNWIND_INCLUDE_TESTS:BOOL=OFF
    -DCOMPILER_RT_BUILD_BUILTINS:BOOL=ON
    # AddressSanitizer is ON so the toolchain ships its own
    # libclang_rt.asan-x86_64.{a,so} alongside the libc++ it was
    # built against. Nucleus relies on this to debug heap corruption
    # without dragging in a second C++ stdlib from a host compiler-rt
    # package built against libstdc++, which would defeat the
    # single-libc++ invariant Nucleus's build enforces.
    #
    # `LLVM_ENABLE_RUNTIMES` configures compiler-rt as a runtimes
    # *sub-build* with its own CMake invocation. Top-level
    # `-DCOMPILER_RT_BUILD_*` vars do not propagate through —
    # they must be passed via `RUNTIMES_CMAKE_ARGS` (a
    # semicolon-separated list of args forwarded to the runtimes
    # subbuild's cmake). We pass the BUILD_SANITIZERS flag both
    # at the top level (for documentation / non-runtimes builds)
    # and via RUNTIMES_CMAKE_ARGS (where it actually takes effect).
    -DCOMPILER_RT_BUILD_SANITIZERS:BOOL=ON
    -DCOMPILER_RT_BUILD_XRAY:BOOL=OFF
    -DCOMPILER_RT_BUILD_LIBFUZZER:BOOL=OFF
    -DCOMPILER_RT_BUILD_PROFILE:BOOL=OFF
    -DCOMPILER_RT_BUILD_CTX_PROFILE:BOOL=OFF
    -DCOMPILER_RT_BUILD_MEMPROF:BOOL=OFF
    -DCOMPILER_RT_BUILD_ORC:BOOL=OFF
    -DCOMPILER_RT_BUILD_GWP_ASAN:BOOL=OFF
    # `COMPILER_RT_SUPPORTED_ARCH=x86_64` overrides compiler-rt's
    # automatic architecture detection. The auto-detect runs a C++
    # try_compile per candidate triple, but in our `LLVM_ENABLE_RUNTIMES
    # =compiler-rt;libcxx;libcxxabi;libunwind` config compiler-rt is
    # configured before libcxx is built. The link tests fail (no libc++
    # to link against yet) and compiler-rt concludes that no
    # architectures support sanitizers, generating no asan targets. With
    # the supported-arch set explicitly, the detection is skipped and
    # compiler-rt builds the x86_64 sanitizer libs against the freshly-
    # built libcxx in the same runtimes sub-build.
    #
    # Do NOT add `COMPILER_RT_DEFAULT_TARGET_ONLY=ON` alongside this:
    # compiler-rt errors with "COMPILER_RT_DEFAULT_TARGET_TRIPLE isn't
    # supported when building for default target only" because the
    # runtimes sub-build always sets the triple. The supported-arch
    # override alone is enough.
    # `SANITIZER_CXX_ABI=libc++` tells compiler-rt to use libc++ (with
    # libc++abi pulled transitively) as the C++ stdlib for the asan
    # runtime's own internal C++ code (symbolizer, demangler,
    # sanitizer_common). On Linux compiler-rt's default is libstdc++
    # (see `handle_default_cxx_lib` in compiler-rt/CMakeLists.txt) —
    # `CLANG_DEFAULT_CXX_STDLIB=libc++` only sets the clang driver
    # default for compiling user code, not the runtime's own
    # self-link. Without this override the shipped
    # libclang_rt.asan-x86_64.so NEEDs libstdc++.so.6, which would
    # defeat the single-libc++ invariant Nucleus's build enforces.
    # `libc++` (not `libcxxabi`) is the right value: the runtime uses
    # `std::string`/`std::vector` which need libc++ proper, not just
    # libc++abi.
    #
    # `COMPILER_RT_USE_LLVM_UNWINDER=ON` plus
    # `COMPILER_RT_ENABLE_STATIC_UNWINDER=ON` are the variables that
    # actually drive the asan runtime's libunwind link choice.
    # `SANITIZER_USE_STATIC_LLVM_UNWINDER=ON` is a sanitizer-internal
    # name that's distinct from these — confusingly, setting it
    # alone does NOT switch the link (see compiler-rt CMakeLists.txt
    # lines 636-645: the only check is on COMPILER_RT_USE_LLVM_UNWINDER
    # / COMPILER_RT_ENABLE_STATIC_UNWINDER). All three are set so any
    # downstream sanitizer code that gates on either name picks up
    # the right behavior. The end effect: asan's libunwind code is
    # statically embedded, removing libunwind.so.1 + libgcc_s.so.1
    # from the runtime's NEEDED entries — leaving just libc / libm /
    # libdl + libc++ + libc++abi from the toolchain.
    # `CMAKE_C_FLAGS=-march=x86-64-v3` / `CMAKE_CXX_FLAGS=-march=x86-64-v3`
    # pin the runtimes subbuild's ISA baseline to x86-64-v3 (2013+:
    # Haswell, Excavator, Zen 1). This affects every shipped runtime
    # — libc++, libc++abi, libunwind, compiler-rt builtins, and the
    # asan runtime.
    #
    # Why v3 specifically:
    #
    #   - **No `NEEDED libatomic.so.1` on libc++.** v3 includes
    #     `cmpxchg16b` (v2 already does), so the compiler inlines
    #     16-byte atomic ops (`std::atomic` on types larger than 8
    #     bytes) instead of emitting `__atomic_load_16` /
    #     `__atomic_store_16` / `__atomic_compare_exchange_16`
    #     libcalls that live in `libatomic.so`. Without this, libc++
    #     gains a `NEEDED libatomic.so.1` runtime dep whose RUNPATH
    #     semantics don't let the consumer's RUNPATH satisfy the
    #     transitive lookup, breaking exec on any host without
    #     libatomic on the default search path.
    #
    #   - **Modest libcxx perf win.** v3 adds AVX/AVX2/FMA/BMI1/BMI2/
    #     F16C/MOVBE, which let the compiler autovectorize libcxx's
    #     SIMD-amenable paths (`std::sort`, `std::find`,
    #     `char_traits` ops, PSTL backend). Not transformative for
    #     our workload but free.
    #
    #   - **Realistic floor.** Nucleus's compositor pipeline (Wayland
    #     + Skia Graphite + Vulkan) implies hardware from roughly the
    #     same era. There's no target we care about where a v3
    #     baseline excludes the host.
    #
    # Skip `-mtune=native` — its codegen depends on the exact host
    # CPU model, which would defeat ccache portability if we ever
    # build on a different chip. The v3 baseline alone gives the ISA
    # win without the tuning lock-in. Skip v4 — AVX-512 portability
    # is meaningfully worse and the libcxx perf delta is small.
    #
    # Top-level CMAKE_C_FLAGS / CMAKE_CXX_FLAGS above stay on
    # `-fblocks` alone because the build-script tokenizes
    # `--extra-llvm-cmake-options` values on whitespace and would
    # split `-fblocks -march=...` into two cmake args. Host LLVM/
    # Swift binaries (clang, lld, swiftc) only run inside our dev
    # shell so missing the runtime-side speedup there is fine.
    # RUNTIMES_CMAKE_ARGS is semicolon-separated with no whitespace
    # inside flag values, so single-flag `-march=x86-64-v3` passes
    # cleanly.
    # `LIBCXX_HAS_ATOMIC_LIB=NO` overrides libcxx's
    # `check_library_exists(atomic __atomic_fetch_add_8 ...)` probe
    # in `libcxx/cmake/config-ix.cmake`. The probe sees libatomic.so
    # available on the system and unconditionally adds `-latomic` to
    # libcxx's link inputs, which produces `NEEDED libatomic.so.1`
    # on the resulting libc++.so.1 regardless of whether codegen
    # actually emits any `__atomic_*_16` libcalls. Pre-setting the
    # cache var to NO short-circuits the probe — combined with
    # `-march=x86-64-v3` ensuring no `__atomic_*_16` is emitted in
    # the first place, libcxx links cleanly without libatomic and
    # the toolchain self-contains its C++ runtime.
    -DRUNTIMES_CMAKE_ARGS:STRING=-DCOMPILER_RT_BUILD_SANITIZERS=ON;-DCOMPILER_RT_BUILD_BUILTINS=ON;-DCOMPILER_RT_BUILD_XRAY=OFF;-DCOMPILER_RT_BUILD_LIBFUZZER=OFF;-DCOMPILER_RT_BUILD_PROFILE=OFF;-DCOMPILER_RT_BUILD_CTX_PROFILE=OFF;-DCOMPILER_RT_BUILD_MEMPROF=OFF;-DCOMPILER_RT_BUILD_ORC=OFF;-DCOMPILER_RT_BUILD_GWP_ASAN=OFF;-DCOMPILER_RT_SUPPORTED_ARCH=x86_64;-DSANITIZER_CXX_ABI=libc++;-DSANITIZER_USE_STATIC_LLVM_UNWINDER=ON;-DCOMPILER_RT_USE_LLVM_UNWINDER=ON;-DCOMPILER_RT_ENABLE_STATIC_UNWINDER=ON;-DCMAKE_C_FLAGS=-march=x86-64-v3;-DCMAKE_CXX_FLAGS=-march=x86-64-v3;-DLIBCXX_HAS_ATOMIC_LIB=NO
    # Drop LLVM assertions for build speed. The inherited
    # `--assertions` flag from `buildbot_linux,no_test` would set this
    # to TRUE; assertions add ~20-25% compile time across LLVM's
    # template-heavy hot paths AND make tablegen/clang runs (which
    # the build itself drives) slower. We don't iterate on LLVM
    # internals, so the diagnostic value is low for our use case.
    # Listed AFTER the upstream `-DLLVM_ENABLE_ASSERTIONS=TRUE` so
    # CMake's last-wins -D semantics make ours stick.
    -DLLVM_ENABLE_ASSERTIONS:BOOL=FALSE
    # Drop unused target backends. X86 is needed for the host Linux
    # toolchain itself; AArch64 is needed so host swiftc can emit Android
    # aarch64 object code for the sibling Android SDK build. The upstream
    # preset builds X86;ARM;AArch64;PowerPC;SystemZ;Mips;RISCV;WebAssembly;
    # AVR;BPF — 10 targets. Keeping only these two still avoids most of
    # that cold-build cost.
    -DLLVM_TARGETS_TO_BUILD:STRING=X86;AArch64
extra-swift-cmake-options=
    -DSWIFT_USE_LINKER:STRING=%(linker)s
    -DSWIFT_SHOULD_BUILD_EMBEDDED_STDLIB:BOOL=FALSE
    -DSWIFT_SHOULD_BUILD_EMBEDDED_STDLIB_CROSS_COMPILING:BOOL=FALSE
    # Keep swift-side assertions disabled explicitly as part of the
    # distributable configuration. Both add measurable compile time
    # and we do not iterate on Swift compiler internals here.
    -DSWIFT_ENABLE_ASSERTIONS:BOOL=FALSE
    -DSWIFTSYNTAX_ENABLE_ASSERTIONS:BOOL=FALSE
llbuild-cmake-options=
    -DBUILD_TESTING:BOOL=FALSE
PRESET

hash_file_set() {
  local path
  while IFS= read -r path; do
    sha256sum "$path"
  done | sha256sum | awk '{print $1}'
}

patch_fingerprint() {
  local directory
  for directory in "$@"; do
    if [[ -d "$directory" ]]; then
      find "$directory" -type f -name '*.patch' -print
    fi
  done | LC_ALL=C sort | hash_file_set
}

repo_revision() {
  local repo="$1"
  if git -C "$workspace/$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s=%s\n' "$repo" "$(git -C "$workspace/$repo" rev-parse HEAD)"
  else
    printf '%s=absent\n' "$repo"
  fi
}

patch_set_fingerprint="$(patch_fingerprint "$patches_dir")"
configuration_fingerprint="$({
  sha256sum "$preset_file" "$cmake_overrides_file"
  printf 'host_cc=%s\n' "$host_cc"
  printf 'host_cxx=%s\n' "$host_cxx"
  printf 'host_cc_version=%s\n' "$($host_cc --version | head -n 1)"
  printf 'linker=%s\n' "$linker"
  printf 'source_id=%s\n' "$source_id"
} | sha256sum | awk '{print $1}')"

compiler_fingerprint="$({
  for repo in swift llvm-project clang cmark swift-syntax; do
    repo_revision "$repo"
  done
  printf 'swift_patches=%s\nconfiguration=%s\n' \
    "$(patch_fingerprint "$patches_dir/swift")" \
    "$configuration_fingerprint"
} | sha256sum | awk '{print $1}')"
runtime_fingerprint="$({
  printf 'compiler=%s\n' "$compiler_fingerprint"
  for repo in swift-corelibs-libdispatch swift-corelibs-foundation \
              swift-foundation swift-foundation-icu swift-corelibs-xctest \
              swift-testing; do
    repo_revision "$repo"
  done
} | sha256sum | awk '{print $1}')"
tools_fingerprint="$({
  printf 'runtime=%s\n' "$runtime_fingerprint"
  for repo in llbuild swiftpm swift-driver swift-build swift-tools-support-core; do
    repo_revision "$repo"
  done
  printf 'tool_patches=%s\n' \
    "$(patch_fingerprint "$patches_dir/swift-driver" "$patches_dir/swift-build" \
                         "$patches_dir/swiftpm" "$patches_dir/indexstore-db" \
                         "$patches_dir/sourcekit-lsp")"
} | sha256sum | awk '{print $1}')"

mkdir -p "$fingerprint_root/current"
printf '%s\n' "$configuration_fingerprint" > "$fingerprint_root/current/configuration"
printf '%s\n' "$compiler_fingerprint" > "$fingerprint_root/current/compiler"
printf '%s\n' "$runtime_fingerprint" > "$fingerprint_root/current/runtime"
printf '%s\n' "$tools_fingerprint" > "$fingerprint_root/current/tools"

report_fingerprint_state() {
  local component current previous_file previous=""
  for component in compiler runtime tools; do
    current="$(<"$fingerprint_root/current/$component")"
    previous_file="$fingerprint_root/last-successful/$component"
    if [[ -f "$previous_file" ]]; then
      previous="$(<"$previous_file")"
    fi
    if [[ "$current" == "$previous" ]]; then
      echo "Component artifact identity unchanged: $component $current"
    elif [[ -n "$previous" ]]; then
      echo "Component artifact identity changed:   $component $previous -> $current"
    else
      echo "Component artifact identity new:       $component $current"
    fi
  done
}

reset_component_build_dirs() {
  local component="$1"
  shift
  local build_dir name
  echo "Resetting changed $component build artifacts"
  for name in "$@"; do
    build_dir="$workspace/build/buildbot_linux/$name-linux-x86_64"
    if [[ -e "$build_dir" || -L "$build_dir" ]]; then
      rm -rf -- "$build_dir"
    fi
  done
}

prepare_component_build_dirs() {
  local previous_config="" previous_runtime="" previous_tools=""
  [[ -f "$fingerprint_root/last-successful/configuration" ]] && \
    previous_config="$(<"$fingerprint_root/last-successful/configuration")"
  [[ -f "$fingerprint_root/last-successful/runtime" ]] && \
    previous_runtime="$(<"$fingerprint_root/last-successful/runtime")"
  [[ -f "$fingerprint_root/last-successful/tools" ]] && \
    previous_tools="$(<"$fingerprint_root/last-successful/tools")"

  # CMake options are not inputs in the generated Ninja graph. Reconfigure
  # automatically after a known successful configuration changes; the explicit
  # flag remains available for manual cache repair.
  if [[ -n "$previous_config" && "$previous_config" != "$configuration_fingerprint" ]] && \
     (( ! reconfigure )); then
    echo "Build configuration identity changed; enabling reconfigure"
    build_cmd+=(--reconfigure)
    reconfigure=1
  fi

  # Swift-produced modules must be rebuilt when their compiler identity changes.
  # The nested fingerprints propagate compiler changes into runtime and tools,
  # while retaining unaffected build directories for narrower source changes.
  if (( ! reconfigure )); then
    if [[ -n "$previous_runtime" && "$previous_runtime" != "$runtime_fingerprint" ]]; then
      reset_component_build_dirs runtime \
        libdispatch libdispatch_static foundation foundation_macros \
        foundation_static swifttesting swifttestingmacros xctest
    fi
    if [[ -n "$previous_tools" && "$previous_tools" != "$tools_fingerprint" ]]; then
      reset_component_build_dirs tools llbuild swiftpm swiftdriver
    fi
  fi
}

record_phase_event() {
  local event="$1"
  printf '%s\t%s\n' "$(date +%s%N)" "$event" >> "$phase_events"
}

trace_build_output() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "$line"
    case "$line" in
      '--- Building '*|'--- Installing '*|'--- Cleaning '*|'Cleaning the '*)
        record_phase_event "$line"
        ;;
    esac
  done
}

report_phase_durations() {
  [[ -s "$phase_events" ]] || return 0
  echo "─── phase durations ───"
  awk -F '\t' '
    NR == 1 { previous_ns = $1; previous_name = $2; next }
    {
      seconds = ($1 - previous_ns) / 1000000000
      printf "  %8.3fs  %s\n", seconds, previous_name
      previous_ns = $1
      previous_name = $2
    }
  ' "$phase_events"
}

publication_started=0
publication_had_previous=0
phase_recording=0

finish_build_script() {
  local status=$?
  trap - EXIT
  if (( status != 0 && publication_started )); then
    rm -rf -- "$published_usr"
    if (( publication_had_previous )) && [[ -e "$published_usr_backup" ]]; then
      mv -- "$published_usr_backup" "$published_usr"
    fi
  fi
  if [[ -n "${package_candidate:-}" ]]; then
    rm -f -- "$package_candidate"
  fi
  if [[ -d "${assembly_root:-}" ]]; then
    rm -rf -- "$assembly_root"
  fi
  if (( status != 0 )); then
    echo "Swift source build failed or was interrupted. Durable log: $log_file" >&2
  fi
  if (( phase_recording )); then
    record_phase_event "process exit"
    report_phase_durations >&2
  fi
  # Print ccache stats for this build. A healthy incremental rebuild
  # should show 80%+ direct hits once the cache has warmed; the first
  # build will be ~100% miss (population). Big regressions (e.g.
  # cache_dir filling up and evicting hot entries) show up as a sharp
  # drop here from one build to the next.
  if command -v ccache >/dev/null 2>&1; then
    echo "─── ccache stats (this build) ───" >&2
    ccache -s 2>&1 | sed 's/^/  /' >&2
  fi
  exit "$status"
}

trap finish_build_script EXIT

mkdir -p "$install_root"
if [[ -e "$assembly_root" || -L "$assembly_root" ]]; then
  echo "Refusing to overwrite unexpected assembly path: $assembly_root" >&2
  exit 1
fi
mkdir -p "$assembly_root"

# The local llvm.py patch leaves an existing libc++ output directory intact
# instead of trying to replace it with /usr/include/c++. On the first configure,
# the top-level CMake include below converts the initial symlink into a real
# directory. Subsequent incremental invocations preserve the generated headers.
llvm_build_dir="$workspace/build/buildbot_linux/llvm-linux-x86_64"

# Place libc++/libc++abi/libunwind shared libs where the freshly-built
# swift-frontend can find them via its existing RUNPATH
# (`$ORIGIN/../lib/swift/linux`). Without this, swift-frontend fails at
# runtime with "libc++.so.1: cannot open shared object file" the first
# time it's invoked by a downstream cmake test compile.
#
# Two locations need this layout because both are reached during the
# overall build's flow:
#
#   1. <swift-build>/lib/swift/linux/  — used by the build-tree
#      swift-frontend while libdispatch/foundation/xctest/llbuild
#      compile.
#
#   2. <install>/usr/lib/swift/linux/  — used by the *installed*
#      swift-frontend that swift-testing-macros (and later
#      SwiftPM-built products) invoke after `--install-swift` runs.
#      LLVM's install puts libc++ at <install>/usr/lib/, not in the
#      swift-runtime-relative layout swift-frontend's RUNPATH expects.
#
# The install symlinks are relative so a tarball extracted to a
# different prefix (Nucleus OS .deb, /opt/nucleus-swift/, etc.) still
# resolves them.
swift_build_linux_dir="$workspace/build/buildbot_linux/swift-linux-x86_64/lib/swift/linux"
install_swift_linux_dir="$assembly_root/usr/lib/swift/linux"
mkdir -p "$swift_build_linux_dir" "$install_swift_linux_dir"
for lib in libc++.so libc++.so.1 libc++.so.1.0 \
           libc++abi.so libc++abi.so.1 libc++abi.so.1.0 \
           libunwind.so libunwind.so.1 libunwind.so.1.0; do
  ln -sfn "$llvm_build_dir/lib/$lib" "$swift_build_linux_dir/$lib"
  ln -sfn "../../$lib" "$install_swift_linux_dir/$lib"
done

# Tell the installed clang/clang++ to always add the install-tree lib
# dir to its library search path. This matters for build phases that
# spawn clang++ via nested tools (SwiftPM/xcbuild) whose env-var
# propagation is unreliable — LIBRARY_PATH from this script doesn't
# always reach those subprocesses.
#
# clang reads `<binary-name>.cfg` from its bin dir at startup, so
# both clang.cfg and clang++.cfg are required (clang++ does NOT
# inherit clang.cfg). `<CFGDIR>` is substituted by clang at runtime
# to the directory containing the .cfg file, so the toolchain stays
# relocatable: extract the tarball to /opt/nucleus-swift/ and the
# -L points at /opt/nucleus-swift/usr/lib without modification.
install_bin="$assembly_root/usr/bin"
mkdir -p "$install_bin"
for cfg in clang.cfg clang++.cfg; do
  cat > "$install_bin/$cfg" <<'CLANG_CFG'
# swift-toolchain: append install-tree lib dir for libc++
# discovery, since LIBRARY_PATH doesn't always propagate through
# SwiftPM / xcbuild's nested compile/link invocations.
-L<CFGDIR>/../lib
CLANG_CFG
done

report_fingerprint_state
prepare_component_build_dirs
: > "$phase_events"
phase_recording=1
record_phase_event "toolchain build"
"${build_cmd[@]}" 2>&1 | trace_build_output
record_phase_event "post-build assembly"

install_bin="$assembly_root/usr/bin"
install_lib="$assembly_root/usr/lib"

# FoundationXML's installed Swift module carries an autolink entry for its
# private C shim. The shim is built as a static archive even for the dynamic
# Foundation configuration, but upstream installs it only in swift_static.
# Ordinary host tools (SwiftPM plugins, macros, generators) search the normal
# resource directory, so keep the archive beside FoundationXML.swiftmodule.
cfxml_static="$install_lib/swift_static/linux/lib_CFXMLInterface.a"
cfxml_dynamic="$install_lib/swift/linux/lib_CFXMLInterface.a"
if [[ ! -f "$cfxml_static" ]]; then
  echo "Swift build completed but FoundationXML support is missing: $cfxml_static" >&2
  exit 1
fi
install -m 0644 "$cfxml_static" "$cfxml_dynamic"

# SwiftBuild applies --static-swift-stdlib to host plugins and macros. Encode
# the complete static SDK-overlay closure in the artifact itself so installing
# the tarball never has to rewrite its link metadata.
static_stdlib_args="$install_lib/swift_static/linux/static-stdlib-args.lnk"
if [[ ! -f "$static_stdlib_args" ]]; then
  echo "Swift build completed but static link metadata is missing: $static_stdlib_args" >&2
  exit 1
fi
if ! grep -qF -- '-lswift_StringProcessing' "$static_stdlib_args"; then
  printf '\n' >> "$static_stdlib_args"
  cat >> "$static_stdlib_args" <<'EOF'
-Xlinker --start-group
-lFoundation
-lFoundationEssentials
-lFoundationInternationalization
-lFoundationNetworking
-lFoundationXML
-l_CFXMLInterface
-lCoreFoundation
-l_FoundationICU
-l_FoundationCShims
-l_FoundationCollections
-lswift_StringProcessing
-lswift_RegexParser
-lswiftRegexBuilder
-lswift_Concurrency
-lswiftObservation
-lswiftSynchronization
-lswiftSwiftOnoneSupport
-Xlinker --end-group
EOF
elif ! grep -qF -- '-l_CFXMLInterface' "$static_stdlib_args"; then
  printf '\n-l_CFXMLInterface\n' >> "$static_stdlib_args"
fi
if ! grep -qF -- '-lxml2' "$static_stdlib_args"; then
  # FoundationXML's private C shim calls libxml2 directly. SwiftBuild applies
  # --static-swift-stdlib to host plugins and generators during an Android build,
  # so the static SDK closure must carry this system-library edge itself rather
  # than requiring every FoundationXML-using build tool to add it manually.
  printf '\n-lxml2\n' >> "$static_stdlib_args"
fi

testing_interop="$workspace/build/buildbot_linux/swifttesting-linux-x86_64/lib/lib_TestingInterop.so"
if [[ -f "$testing_interop" && -d "$install_lib/swift/linux" ]]; then
  cp "$testing_interop" "$install_lib/swift/linux/lib_TestingInterop.so"
  chmod 0755 "$install_lib/swift/linux/lib_TestingInterop.so"
fi

candidate=""
if [[ -x "$assembly_root/usr/bin/swiftc" ]]; then
  candidate="$assembly_root/usr/bin/swiftc"
fi
if [[ -z "$candidate" ]]; then
  echo "Swift build completed but no swiftc executable was found under $assembly_root" >&2
  exit 1
fi

"$candidate" --version

fingerprint_manifest="$assembly_root/usr/share/nucleus/component-fingerprints.env"
mkdir -p "$(dirname "$fingerprint_manifest")"
cat > "$fingerprint_manifest" <<FINGERPRINTS
source_id=$source_id
source_ref=$source_ref
configuration=$configuration_fingerprint
patch_set=$patch_set_fingerprint
compiler=$compiler_fingerprint
runtime=$runtime_fingerprint
tools=$tools_fingerprint
FINGERPRINTS

# Repackage into a same-filesystem candidate. The previously published
# tarball remains untouched until this candidate passes every smoke test.
rm -f -- "$package_candidate"
echo "--- Creating candidate installable package ---"
record_phase_event "package candidate"
( cd "$assembly_root" && tar -c -z -f "$package_candidate" --owner=0 --group=0 usr/ )

# Smoke test the package: extract it to a temp dir, build a tiny Swift
# package with it, confirm it runs.
smoke_root="$install_root/package-smoke"
package_toolchain="$smoke_root/toolchain"
smoke_home="$smoke_root/home"
smoke_tmp="$smoke_root/tmp"
smoke_src="$smoke_root/NucleusPackageSmoke.swift"
smoke_bin="$smoke_root/main"
package_dir="$smoke_root/swiftpm"

rm -rf "$smoke_root"
mkdir -p "$package_toolchain" "$smoke_home" "$smoke_tmp" "$package_dir"

echo "--- Smoking installable package ---"
record_phase_event "package smoke"
tar -x -z -f "$package_candidate" -C "$package_toolchain"

toolchain_bin="$package_toolchain/usr/bin"
for required in swift swiftc; do
  if [[ ! -x "$toolchain_bin/$required" ]]; then
    echo "Installable package smoke failed; $required is missing" >&2
    exit 1
  fi
done
if [[ ! -f "$package_toolchain/usr/share/nucleus/component-fingerprints.env" ]]; then
  echo "Installable package smoke failed; component fingerprints are missing" >&2
  exit 1
fi

clean_env=(
  env -i
  "HOME=$smoke_home"
  "USER=${USER:-nucleus}"
  "TMPDIR=$smoke_tmp"
  "PATH=$toolchain_bin:/usr/bin:/bin"
)

cat > "$smoke_src" <<'SWIFT'
import Foundation
import FoundationXML

@main
struct NucleusPackageSmoke {
    static func main() {
        let parser = XMLParser(data: Data("<nucleus/>".utf8))
        guard parser.parse() else {
            fatalError("FoundationXML parser smoke failed")
        }
        print("swift package FoundationXML smoke ok")
    }
}
SWIFT
"${clean_env[@]}" "$toolchain_bin/swift" --version
"${clean_env[@]}" "$toolchain_bin/swiftc" -parse-as-library "$smoke_src" -o "$smoke_bin"
"$smoke_bin"

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
  cp "$smoke_src" Sources/NucleusPackageSmoke/NucleusPackageSmoke.swift
  "${clean_env[@]}" "$toolchain_bin/swift" build -v
  "${clean_env[@]}" "$toolchain_bin/swift" run NucleusPackageSmoke
)

rm -rf "$smoke_root"
echo "Installable package smoke passed"

# Publish the verified assembly without ever building into the previous
# toolchain tree. The EXIT trap restores the old usr/ tree if publication
# fails before the package rename completes.
record_phase_event "publish assembly"
if [[ -e "$published_usr_backup" || -L "$published_usr_backup" ]]; then
  echo "Refusing to overwrite unexpected rollback path: $published_usr_backup" >&2
  exit 1
fi
if [[ -e "$published_usr" || -L "$published_usr" ]]; then
  mv -- "$published_usr" "$published_usr_backup"
  publication_had_previous=1
fi
publication_started=1
mv -- "$assembly_root/usr" "$published_usr"
mv -f -- "$package_candidate" "$package_path"
package_candidate=""
publication_started=0
if (( publication_had_previous )); then
  rm -rf -- "$published_usr_backup"
  publication_had_previous=0
fi
rm -rf -- "$assembly_root"

mkdir -p "$fingerprint_root/last-successful.new.$$"
cp "$fingerprint_root/current/configuration" "$fingerprint_root/last-successful.new.$$/configuration"
cp "$fingerprint_root/current/compiler" "$fingerprint_root/last-successful.new.$$/compiler"
cp "$fingerprint_root/current/runtime" "$fingerprint_root/last-successful.new.$$/runtime"
cp "$fingerprint_root/current/tools" "$fingerprint_root/last-successful.new.$$/tools"
rm -rf -- "$fingerprint_root/last-successful"
mv -- "$fingerprint_root/last-successful.new.$$" "$fingerprint_root/last-successful"
record_phase_event "complete"
echo "Installable package published"
echo "Swift toolchain available at:    $install_root/usr"
echo "Distributable tarball available: $package_path"
echo "Build log retained at:           $log_file"
