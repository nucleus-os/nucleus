#!/usr/bin/env bash
# Shared host environment for Nucleus build entry points. Source this file.

if [[ -n "${ZSH_VERSION:-}" ]]; then
  nucleus_host_env_source="${(%):-%x}"
else
  nucleus_host_env_source="${BASH_SOURCE[0]}"
fi
nucleus_workspace_root="$(cd "$(dirname "$nucleus_host_env_source")/.." && pwd)"

source "$nucleus_workspace_root/tools/host-platform-env.sh"

if ! command -v fnm >/dev/null 2>&1; then
  echo "error: fnm is required to activate the Nucleus Node.js toolchain" >&2
  return 127 2>/dev/null || exit 127
fi
nucleus_fnm_environment="$(fnm env --shell bash)" || {
  echo "error: fnm could not initialize the Nucleus Node.js environment" >&2
  return 127 2>/dev/null || exit 127
}
eval "$nucleus_fnm_environment"
if ! fnm use --log-level quiet 26; then
  echo "error: Node.js 26 is not installed under fnm" >&2
  return 127 2>/dev/null || exit 127
fi

nucleus_toolchain=""
if [[ -n "${NUCLEUS_SWIFT_SOURCE_ID:-}" ]]; then
  nucleus_source_id="$NUCLEUS_SWIFT_SOURCE_ID"
else
  nucleus_source_index="$(
    git -C "$nucleus_workspace_root" ls-files --stage -- swift-sdk/source \
      | awk '$1 == "160000" {
          sub(/^swift-sdk\/source\//, "", $4)
          print $1, $2, $4
        }'
  )"
  if [[ -z "$nucleus_source_index" ]]; then
    echo "error: the Swift source gitlink graph is missing" >&2
    return 127 2>/dev/null || exit 127
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    nucleus_source_digest="$(printf '%s\n' "$nucleus_source_index" | sha256sum)"
  else
    nucleus_source_digest="$(printf '%s\n' "$nucleus_source_index" | shasum -a 256)"
  fi
  nucleus_source_id="${nucleus_source_digest%% *}"
  nucleus_source_id="${nucleus_source_id:0:24}"
fi
export NUCLEUS_SWIFT_SOURCE_ID="$nucleus_source_id"
nucleus_platform_id="$nucleus_source_id-linux-amd64"
if [[ "$(uname -s)" == Darwin ]]; then
  nucleus_swiftc="$(xcrun --find swiftc 2>/dev/null)" || {
    echo "error: full Xcode 27 with Swift 6.4 must be selected" >&2
    return 127 2>/dev/null || exit 127
  }
  if ! "$nucleus_swiftc" --version 2>/dev/null \
      | grep -Fq "Apple Swift version 6.4"; then
    echo "error: the selected Xcode does not provide Apple Swift 6.4" >&2
    return 127 2>/dev/null || exit 127
  fi
  nucleus_toolchain="$(cd "$(dirname "$nucleus_swiftc")/.." && pwd)"
elif [[ -n "${NUCLEUS_SWIFT_TOOLCHAIN:-}" && -x "$NUCLEUS_SWIFT_TOOLCHAIN/bin/swift-build" ]]; then
  nucleus_toolchain="$NUCLEUS_SWIFT_TOOLCHAIN"
elif [[ -x "${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-platforms/$nucleus_platform_id/current/toolchain/usr/bin/swift-build" ]]; then
  nucleus_toolchain="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-platforms/$nucleus_platform_id/current/toolchain/usr"
else
  echo "error: the Nucleus Linux amd64 Swift 6.4 toolchain is not installed" >&2
  echo "       run ./collider-setup.sh or set NUCLEUS_SWIFT_TOOLCHAIN" >&2
  return 127 2>/dev/null || exit 127
fi

export SWIFT_TOOLCHAIN="$nucleus_toolchain"
export SWIFT="$nucleus_toolchain/bin/swift"
export SWIFTC="$nucleus_toolchain/bin/swiftc"
if [[ "$(uname -s)" != Darwin ]]; then
  export SWIFT_LIBRARY_PATH="$nucleus_toolchain/lib/swift/linux"
fi
export PATH="$nucleus_toolchain/bin:$PATH"
export SWIFTCI_USE_LOCAL_DEPS=1
: "${SWIFT_BACKTRACE:=enable=no}"
export SWIFT_BACKTRACE
: "${NUCLEUS_NATIVE_SDK_ROOT:=${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/nucleus-native-sdk}"
export NUCLEUS_NATIVE_SDK_ROOT

# swift-java exposes this explicit override for workspace integrators. Nucleus
# always resolves its paired JNI ABI fork from the pinned root submodule; this is
# a declared build-environment choice, not conditional sibling discovery.
export SWIFT_JAVA_JNI_CORE_PATH="$nucleus_workspace_root/third-party/swift-java-jni-core"

# The workspace build directory, published by Collider when it resolves the
# default build context. A manifest that needs SwiftPM's generated header
# directory reads it here, so a language server build and a Collider build name
# the same directory instead of recompiling each other. Absent before the first
# build, which is the same as a checkout that has never been built.
if [[ -r "$nucleus_workspace_root/.nucleus/swiftpm/environment.sh" ]]; then
  source "$nucleus_workspace_root/.nucleus/swiftpm/environment.sh"
fi
: "${NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH:=$nucleus_workspace_root/.nucleus/swiftpm/generated-module-maps}"
export NUCLEUS_SWIFTPM_GENERATED_MODULE_MAPS_PATH

unset nucleus_host_env_source nucleus_workspace_root
unset nucleus_fnm_environment nucleus_source_index nucleus_source_digest
unset nucleus_toolchain nucleus_swiftc nucleus_source_id nucleus_platform_id
