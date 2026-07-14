#!/usr/bin/env bash

nucleus_android_ndk_version() {
  printf '%s\n' "${NUCLEUS_ANDROID_NDK_VERSION:-30.0.14904198}"
}

nucleus_android_ndk_home() {
  if [[ -n "${NUCLEUS_ANDROID_NDK_HOME:-}" ]]; then
    printf '%s\n' "$NUCLEUS_ANDROID_NDK_HOME"
  elif [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    printf '%s\n' "$ANDROID_NDK_HOME"
  elif [[ "$(uname -s)" == Darwin ]]; then
    printf '%s\n' "$HOME/Library/Android/sdk/ndk/$(nucleus_android_ndk_version)"
  else
    printf '%s\n' "$HOME/Android/Sdk/ndk/$(nucleus_android_ndk_version)"
  fi
}
