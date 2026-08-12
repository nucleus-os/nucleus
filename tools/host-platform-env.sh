#!/usr/bin/env bash
# Host-package paths shared by bootstrap and normal Nucleus builds.

if [[ "$(uname -s)" != Darwin ]]; then
  return 0 2>/dev/null || exit 0
fi

unset XDG_CACHE_HOME
export NUCLEUS_BUILD_ROOT="$HOME/Library/Developer/Nucleus/Collider/build"
export NUCLEUS_NATIVE_SDK_ROOT="$HOME/Library/Caches/Nucleus/Collider/native-sdks/linux-arm64"
export ANDROID_SDK_ROOT="$HOME/Library/Caches/Nucleus/Collider/android-sdks"
export ANDROID_HOME="$ANDROID_SDK_ROOT"

nucleus_java_home="$(/usr/libexec/java_home -v 17 2>/dev/null)" || {
  echo "error: OpenJDK 17 is required for Nucleus Android builds" >&2
  return 127 2>/dev/null || exit 127
}

export JAVA_HOME="$nucleus_java_home"
export PATH="$JAVA_HOME/bin:$PATH"

unset nucleus_java_home
