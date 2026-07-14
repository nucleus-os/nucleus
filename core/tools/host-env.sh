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

nucleus_require_commands() {
  local missing=0 command
  for command in "$@"; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "error: required command is missing: $command" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]]
}

nucleus_require_pkg_config() {
  local missing=0 module
  for module in "$@"; do
    if ! pkg-config --exists "$module"; then
      echo "error: required pkg-config module is missing: $module" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]]
}

nucleus_require_supported_node() {
  local major=""
  if command -v node >/dev/null 2>&1; then
    major="$(node -p 'process.versions.node.split(".")[0]')"
  fi
  if [[ "$major" == "22" || "$major" == "24" || ( "$major" =~ ^[0-9]+$ && "$major" -ge 26 ) ]]; then
    return 0
  fi

  local candidate candidate_major
  for candidate in "${FNM_DIR:-$HOME/.local/share/fnm}/node-versions"/v*/installation/bin/node; do
    [[ -x "$candidate" ]] || continue
    candidate_major="$($candidate -p 'process.versions.node.split(".")[0]')"
    if [[ "$candidate_major" == "22" || "$candidate_major" == "24" || "$candidate_major" -ge 26 ]]; then
      export PATH="$(dirname "$candidate"):$PATH"
      return 0
    fi
  done

  echo "error: React Native requires Node 22, 24, or 26+; found ${major:-none}" >&2
  return 1
}
