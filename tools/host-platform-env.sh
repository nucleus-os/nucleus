#!/usr/bin/env bash
# Host-package paths shared by bootstrap and normal Nucleus builds.

if [[ "$(uname -s)" != Darwin ]]; then
  return 0 2>/dev/null || exit 0
fi

nucleus_homebrew_prefix="/opt/homebrew"
nucleus_icu_pkgconfig="$nucleus_homebrew_prefix/opt/icu4c@78/lib/pkgconfig"

if [[ ! -d "$nucleus_icu_pkgconfig" ]]; then
  echo "error: Homebrew icu4c@78 is required for Nucleus SwiftPM manifests" >&2
  return 127 2>/dev/null || exit 127
fi

nucleus_java_home="$(/usr/libexec/java_home -v 17 2>/dev/null)" || {
  echo "error: OpenJDK 17 is required for Nucleus Android builds" >&2
  return 127 2>/dev/null || exit 127
}

export PKG_CONFIG_PATH="$nucleus_icu_pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export JAVA_HOME="$nucleus_java_home"
export PATH="$JAVA_HOME/bin:$PATH"

unset nucleus_homebrew_prefix nucleus_icu_pkgconfig nucleus_java_home
