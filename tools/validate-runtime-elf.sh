#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: validate-runtime-elf.sh PRODUCTS_DIRECTORY OWNERSHIP_MANIFEST" >&2
  exit 64
fi

products=$1
manifest=$2
staged=0
if [[ -d "$products/bin" && -d "$products/lib" && -d "$products/libexec" ]]; then
  staged=1
fi

executables=(
  NucleusCompositor
  NucleusShell
  NucleusSessionSupervisor
  NucleusConfigService
  NucleusControlService
  NucleusShellPamHelper
  nucleus
)

fail() {
  echo "runtime ELF validation failed: $*" >&2
  exit 1
}

artifact_path() {
  local artifact=$1
  if [[ $staged -eq 0 ]]; then
    printf '%s/%s\n' "$products" "$artifact"
    return
  fi
  case "$artifact" in
    NucleusConfigService|NucleusControlService|NucleusSessionSupervisor|NucleusShellPamHelper)
      printf '%s/libexec/%s\n' "$products" "$artifact"
      ;;
    *)
      printf '%s/bin/%s\n' "$products" "$artifact"
      ;;
  esac
}

needed() {
  readelf -d "$1" |
    sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
}

require_needed() {
  local artifact=$1 dependency=$2
  needed "$(artifact_path "$artifact")" | grep -Fxq "$dependency" ||
    fail "$artifact does not depend on $dependency"
}

for artifact in "${executables[@]}"; do
  path=$(artifact_path "$artifact")
  [[ -x "$path" ]] ||
    fail "missing or non-executable artifact $path"
  readelf -h "$path" >/dev/null 2>&1 ||
    fail "$artifact is not an ELF executable"

  runpath=$(
    readelf -d "$path" |
      sed -n 's/.*Library runpath: \[\([^]]*\)\].*/\1/p'
  )
  if [[ $staged -eq 1 ]]; then
    [[ "$runpath" == '$ORIGIN/../lib' ]] ||
      fail "$artifact has staged runpath '$runpath', expected \$ORIGIN/../lib"
  else
    [[ "$runpath" == *'$ORIGIN'* ]] ||
      fail "$artifact has no origin-relative runtime search path"
  fi

  dependencies=$(needed "$path")
  grep -q / <<<"$dependencies" &&
    fail "$artifact contains a path-qualified dependency"
  grep -Eq '^lib(Nucleus|SwiftTracy|SwiftVulkan|SwiftWayland).*[.]so' \
    <<<"$dependencies" &&
    fail "$artifact depends on a first-party shared library"

  relocation=$(ldd -r "$path" 2>&1) ||
    fail "$artifact failed relocation validation: $relocation"
  grep -Eq 'not found|undefined symbol' <<<"$relocation" &&
    fail "$artifact has an unresolved dependency: $relocation"

  if [[ $staged -eq 1 ]]; then
    dynamic=$(readelf -d "$path")
    if grep -Eq \
      '/home/|/Users/|/nucleus-native-sdk|/\.nucleus/|/Products/' \
      <<<"$dynamic"
    then
      fail "$artifact retains a development path in its dynamic metadata"
    fi
  fi
done

# The compositor and shell statically own their first-party implementation
# graphs, so their native platform closures must remain direct dependencies.
require_needed NucleusCompositor libvulkan.so.1
require_needed NucleusCompositor libdrm.so.2
require_needed NucleusCompositor libwayland-server.so.0
require_needed NucleusShell libvulkan.so.1
require_needed NucleusShell libwayland-client.so.0
require_needed NucleusSessionSupervisor libsystemd.so.0
require_needed NucleusConfigService libsystemd.so.0
require_needed NucleusControlService libsystemd.so.0
require_needed NucleusShellPamHelper libpam.so.0

# Small service and privilege-boundary executables must not acquire render or
# desktop dependencies merely because all first-party code is in one package.
restricted=(
  NucleusSessionSupervisor
  NucleusConfigService
  NucleusControlService
  NucleusShellPamHelper
  nucleus
)
for artifact in "${restricted[@]}"; do
  for forbidden in \
    libvulkan.so.1 \
    libdrm.so.2 \
    libgbm.so.1 \
    libwayland-client.so.0 \
    libwayland-server.so.0 \
    libinput.so.10 \
    libudev.so.1 \
    libseat.so.1
  do
    needed "$(artifact_path "$artifact")" | grep -Fxq "$forbidden" &&
      fail "$artifact unexpectedly depends on $forbidden"
  done
done

# Each process statically owns its first-party implementation. Record the
# remaining dynamic closure for diagnostics; duplicate first-party definitions
# across different processes are expected and need no symbol-level manifest.
: >"$manifest"
for artifact in "${executables[@]}"; do
  needed "$(artifact_path "$artifact")" |
    LC_ALL=C sort |
    awk -v artifact="$artifact" '{ print artifact "\t" $0 }' >>"$manifest"
done

echo "runtime ELF validation passed: $manifest"
