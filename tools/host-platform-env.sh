#!/usr/bin/env bash
# Host-package paths shared by bootstrap and normal Nucleus builds.

if [[ "$(uname -s)" != Darwin ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ -n "${ZSH_VERSION:-}" ]]; then
  nucleus_platform_env_source="${(%):-%x}"
else
  nucleus_platform_env_source="${BASH_SOURCE[0]}"
fi
nucleus_platform_workspace_root="$(
  cd "$(dirname "$nucleus_platform_env_source")/.." && pwd
)"
nucleus_platform_contract="$nucleus_platform_workspace_root/tools/macos-builder/contract.json"

if [[ ! -r "$nucleus_platform_contract" ]]; then
  echo "error: Nucleus macOS builder contract is missing: $nucleus_platform_contract" >&2
  return 127 2>/dev/null || exit 127
fi

export XDG_CACHE_HOME="$(
  /usr/bin/plutil -extract environment.xdgCacheHome raw -o - \
    "$nucleus_platform_contract"
)"
export NUCLEUS_NATIVE_SDK_ROOT="$(
  /usr/bin/plutil -extract environment.nativeSDKRoot raw -o - \
    "$nucleus_platform_contract"
)"
export ANDROID_SDK_ROOT="$(
  /usr/bin/plutil -extract environment.androidSDKRoot raw -o - \
    "$nucleus_platform_contract"
)"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

nucleus_java_home="$(/usr/libexec/java_home -v 17 2>/dev/null)" || {
  echo "error: OpenJDK 17 is required for Nucleus Android builds" >&2
  return 127 2>/dev/null || exit 127
}

export JAVA_HOME="$nucleus_java_home"
export PATH="$JAVA_HOME/bin:$PATH"

unset nucleus_platform_env_source nucleus_platform_workspace_root
unset nucleus_platform_contract nucleus_java_home
