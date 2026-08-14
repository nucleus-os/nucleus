#!/usr/bin/env bash
# Shared host environment for Nucleus build entry points. Source this file.

if [[ -n "${ZSH_VERSION:-}" ]]; then
  nucleus_host_env_source="${(%):-%x}"
else
  nucleus_host_env_source="${BASH_SOURCE[0]}"
fi
nucleus_workspace_root="$(cd "$(dirname "$nucleus_host_env_source")/.." && pwd)"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "error: Collider currently requires a macOS host; Linux host support is not implemented" >&2
  return 69 2>/dev/null || exit 69
fi

source "$nucleus_workspace_root/tools/host-platform-env.sh"

nucleus_toolchain=""
nucleus_source_index="$(
  git -C "$nucleus_workspace_root" ls-files --stage -- swift-sdk/source \
    | awk '$1 == "160000" {
        sub(/^swift-sdk\/source\//, "", $4)
        if ($4 != "swift-sdk-generator") print $1, $2, $4
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
export NUCLEUS_SWIFT_SOURCE_ID="$nucleus_source_id"
nucleus_generator_source_id="$(
  git -C "$nucleus_workspace_root" ls-files --stage -- \
    swift-sdk/source/swift-sdk-generator \
    | awk '$1 == "160000" { print $2 }'
)"
if [[ -z "$nucleus_generator_source_id" ]]; then
  echo "error: the Swift SDK generator gitlink is missing" >&2
  return 127 2>/dev/null || exit 127
fi
export NUCLEUS_SWIFT_SDK_GENERATOR_SOURCE_ID="$nucleus_generator_source_id"
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

export SWIFT_TOOLCHAIN="$nucleus_toolchain"
export SWIFT="$nucleus_toolchain/bin/swift"
export SWIFTC="$nucleus_toolchain/bin/swiftc"
export PATH="$nucleus_toolchain/bin:$PATH"
: "${SWIFT_BACKTRACE:=enable=no}"
export SWIFT_BACKTRACE
: "${NUCLEUS_NATIVE_SDK_ROOT:=${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/nucleus-native-sdk/linux-$(uname -m | sed 's/aarch64/arm64/; s/amd64/x86_64/')}"
export NUCLEUS_NATIVE_SDK_ROOT

unset nucleus_host_env_source nucleus_workspace_root
unset nucleus_fnm_environment nucleus_source_index nucleus_source_digest
unset nucleus_generator_source_id nucleus_toolchain nucleus_swiftc nucleus_source_id
