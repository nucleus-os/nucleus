#!/usr/bin/env bash
# Shared host environment for Nucleus build entry points. Source this file.

nucleus_toolchain=""
if [[ -n "${NUCLEUS_SWIFT_TOOLCHAIN:-}" && -x "$NUCLEUS_SWIFT_TOOLCHAIN/bin/swift-build" ]]; then
  nucleus_toolchain="$NUCLEUS_SWIFT_TOOLCHAIN"
elif [[ -x /opt/nucleus-swift/current/usr/bin/swift-build ]]; then
  nucleus_toolchain=/opt/nucleus-swift/current/usr
elif [[ -x "${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/release-6.4.x/usr/bin/swift-build" ]]; then
  nucleus_toolchain="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/swift-toolchains/release-6.4.x/usr"
fi

if [[ -z "$nucleus_toolchain" ]]; then
  echo "error: the Nucleus Swift 6.4 toolchain is not installed" >&2
  echo "       install it under /opt/nucleus-swift/current/usr or set NUCLEUS_SWIFT_TOOLCHAIN" >&2
  return 127 2>/dev/null || exit 127
fi

export SWIFT_TOOLCHAIN="$nucleus_toolchain"
export SWIFT="$nucleus_toolchain/bin/swift"
export SWIFTC="$nucleus_toolchain/bin/swiftc"
export SWIFT_LIBRARY_PATH="$nucleus_toolchain/lib/swift/linux"
export PATH="$nucleus_toolchain/bin:$PATH"
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
nucleus_workspace_root="$(cd "$(dirname "$nucleus_host_env_source")/../.." && pwd)"
export SWIFT_JAVA_JNI_CORE_PATH="$nucleus_workspace_root/third-party/swift-java-jni-core"
unset nucleus_host_env_source nucleus_workspace_root
unset nucleus_toolchain
