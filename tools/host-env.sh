#!/usr/bin/env bash
# Shared host environment for Nucleus build entry points. Source this file.

nucleus_toolchain=""
nucleus_source_id="${NUCLEUS_SWIFT_SOURCE_ID:-release-6.4.x}"
nucleus_platform_id="$nucleus_source_id"
if [[ "$(uname -s)" == Darwin ]]; then nucleus_platform_id="$nucleus_source_id-macos"; fi
if [[ -n "${NUCLEUS_SWIFT_TOOLCHAIN:-}" && -x "$NUCLEUS_SWIFT_TOOLCHAIN/bin/swift-build" ]]; then
  nucleus_toolchain="$NUCLEUS_SWIFT_TOOLCHAIN"
elif [[ -x "${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-platforms/$nucleus_platform_id/current/toolchain/usr/bin/swift-build" ]]; then
  nucleus_toolchain="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-platforms/$nucleus_platform_id/current/toolchain/usr"
fi

if [[ -z "$nucleus_toolchain" ]]; then
  echo "error: the Nucleus Swift 6.4 toolchain is not installed" >&2
  echo "       run ./collider-setup.sh or set NUCLEUS_SWIFT_TOOLCHAIN" >&2
  return 127 2>/dev/null || exit 127
fi

export SWIFT_TOOLCHAIN="$nucleus_toolchain"
export SWIFT="$nucleus_toolchain/bin/swift"
export SWIFTC="$nucleus_toolchain/bin/swiftc"
if [[ "$(uname -s)" == Darwin ]]; then
  export SWIFT_LIBRARY_PATH="$nucleus_toolchain/lib/swift/macosx"
else
  export SWIFT_LIBRARY_PATH="$nucleus_toolchain/lib/swift/linux"
fi
export PATH="$nucleus_toolchain/bin:$PATH"
export SWIFTCI_USE_LOCAL_DEPS=1
: "${SWIFT_BACKTRACE:=enable=no}"
export SWIFT_BACKTRACE

# swift-java exposes this explicit override for workspace integrators. Nucleus
# always resolves its paired JNI ABI fork from the pinned root submodule; this is
# a declared build-environment choice, not conditional sibling discovery.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  nucleus_host_env_source="${(%):-%x}"
else
  nucleus_host_env_source="${BASH_SOURCE[0]}"
fi
nucleus_workspace_root="$(cd "$(dirname "$nucleus_host_env_source")/.." && pwd)"
export SWIFT_JAVA_JNI_CORE_PATH="$nucleus_workspace_root/third-party/swift-java-jni-core"
unset nucleus_host_env_source nucleus_workspace_root
unset nucleus_toolchain nucleus_source_id nucleus_platform_id
