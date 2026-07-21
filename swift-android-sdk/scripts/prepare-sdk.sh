#!/usr/bin/env bash
# Wire a staged Android Swift SDK directly to the configured NDK. The caller
# controls the user-level SDK search root; no global or system installation is
# performed here.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/android-sdk-env.sh"

source_id="${NUCLEUS_SWIFT_SOURCE_ID:-release-6.4.x}"
sdk_search_root="${NUCLEUS_SWIFT_SDKS_PATH:?NUCLEUS_SWIFT_SDKS_PATH is required}"
bundle_name="${NUCLEUS_SWIFT_ANDROID_BUNDLE_NAME:-swift-${source_id}_android.artifactbundle}"
setup_script="$sdk_search_root/$bundle_name/swift-android/scripts/setup-android-sdk.sh"
ndk_home="$(nucleus_android_ndk_home)"

if [[ ! -x "$setup_script" ]]; then
  echo "staged Android SDK setup script not found at $setup_script" >&2
  exit 1
fi
if [[ ! -d "$ndk_home" ]]; then
  echo "Android NDK not found at $ndk_home" >&2
  exit 1
fi

export ANDROID_NDK_HOME="$ndk_home"
exec "$setup_script"
