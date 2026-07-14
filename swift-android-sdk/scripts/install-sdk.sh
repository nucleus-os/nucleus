#!/usr/bin/env bash
# Install the assembled Android Swift SDK artifactbundle AND wire it to the
# local NDK in a single step.
#
# `swift sdk install` alone leaves the bundle NDK-agnostic: ndk-sysroot/ is
# empty and ndk-toolchain/bin has no tools, so the swift driver silently falls
# back to the host clang as the link driver and leaks host x86_64
# libc++/libunwind onto Android links. setup-android-sdk.sh fixes that, but it
# is a separate manual step that is easy to forget. This wrapper runs both so
# the SDK is never left half-installed.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/android-sdk-env.sh"

source_id="${NUCLEUS_SWIFT_SOURCE_ID:-release-6.4.x}"
toolchain_root="${NUCLEUS_SWIFT_TOOLCHAIN:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/${source_id}/usr}"
install_root="${NUCLEUS_SWIFT_ANDROID_INSTALL:-${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-android-sdks/${source_id}}"
ndk_home="$(nucleus_android_ndk_home)"
bundle_name="swift-${source_id}_android.artifactbundle"
bundle_tar="$install_root/${bundle_name}.tar.gz"
bundle_sha="${bundle_tar}.sha256"
sdk_id="swift-${source_id}_android"
swift_bin="$toolchain_root/bin/swift"

if [[ ! -x "$swift_bin" ]]; then
  echo "swift not found at $swift_bin (build swift-toolchain first)" >&2
  exit 1
fi
if [[ ! -f "$bundle_tar" || ! -f "$bundle_sha" ]]; then
  echo "artifactbundle or checksum missing under $install_root (run ./build.sh first)" >&2
  exit 1
fi
if [[ ! -d "$ndk_home" ]]; then
  echo "Android NDK not found at $ndk_home (set NUCLEUS_ANDROID_NDK_HOME)" >&2
  exit 1
fi

export PATH="$toolchain_root/bin:$PATH"
export ANDROID_NDK_HOME="$ndk_home"

echo "==> installing $bundle_tar" >&2
"$swift_bin" sdk remove "$sdk_id" >/dev/null 2>&1 || true
"$swift_bin" sdk install "$bundle_tar" --checksum "$(cat "$bundle_sha")"

setup_script="$HOME/.swiftpm/swift-sdks/$bundle_name/swift-android/scripts/setup-android-sdk.sh"
if [[ ! -x "$setup_script" ]]; then
  echo "installed setup script not found at $setup_script" >&2
  exit 1
fi

echo "==> wiring installed SDK to NDK at $ANDROID_NDK_HOME" >&2
"$setup_script"

echo "==> done: $sdk_id installed and configured" >&2
"$swift_bin" sdk list
