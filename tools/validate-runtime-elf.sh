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

libraries=(
  libNucleusFoundation.so
  libNucleus.so
  libNucleusLinux.so
  libNucleusLinuxDesktop.so
  libNucleusConfig.so
  libNucleusConfigIO.so
  libNucleusConfigService.so
  libNucleusControlService.so
  libNucleusIPCTransport.so
  libNucleusControlProtocol.so
  libNucleusControlClient.so
  libNucleusSessionProtocol.so
  libNucleusWindowClient.so
  libNucleusShellKit.so
  libNucleusRenderServer.so
  libSwiftWaylandProtocolRuntime.so
  libSwiftVulkan.so
  libSwiftTracy.so
)
executables=(
  NucleusCompositor
  NucleusShell
  NucleusSessionSupervisor
  NucleusConfigService
  NucleusControlService
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
    *.so|*.so.*)
      printf '%s/lib/%s\n' "$products" "$artifact"
      ;;
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

for artifact in "${libraries[@]}" "${executables[@]}"; do
  path=$(artifact_path "$artifact")
  [[ -f "$path" ]] ||
    fail "missing artifact $path"
  runpath=$(
    readelf -d "$path" |
      sed -n 's/.*Library runpath: \[\([^]]*\)\].*/\1/p'
  )
  if [[ $staged -eq 1 ]]; then
    if [[ "$artifact" == *.so ]]; then
      [[ "$runpath" == '$ORIGIN' ]] ||
        fail "$artifact has staged runpath '$runpath', expected \$ORIGIN"
    else
      [[ "$runpath" == '$ORIGIN/../lib' ]] ||
        fail "$artifact has staged runpath '$runpath', expected \$ORIGIN/../lib"
    fi
  else
    [[ "$runpath" == *'$ORIGIN'* ]] ||
      fail "$artifact has no origin-relative runtime search path"
  fi
  needed "$path" | grep -q / &&
    fail "$artifact contains a path-qualified dependency"
done

for library in "${libraries[@]}"; do
  soname=$(
    readelf -d "$(artifact_path "$library")" |
      sed -n 's/.*Library soname: \[\([^]]*\)\].*/\1/p'
  )
  [[ "$soname" == "$library" ]] ||
    fail "$library has SONAME '${soname:-<missing>}'"
done

require_needed NucleusShell libNucleusShellKit.so
require_needed libNucleusShellKit.so libNucleus.so
require_needed libNucleusShellKit.so libNucleusWindowClient.so
require_needed libNucleusShellKit.so libNucleusLinux.so
require_needed libNucleusShellKit.so libNucleusLinuxDesktop.so
require_needed libNucleusShellKit.so libNucleusSessionProtocol.so
require_needed NucleusCompositor libNucleusRenderServer.so
require_needed NucleusCompositor libNucleusFoundation.so
require_needed NucleusCompositor libNucleusSessionProtocol.so
require_needed NucleusSessionSupervisor libNucleusFoundation.so
require_needed NucleusSessionSupervisor libNucleusLinux.so
require_needed NucleusSessionSupervisor libNucleusSessionProtocol.so
require_needed NucleusConfigService libNucleusConfigService.so
require_needed NucleusControlService libNucleusControlService.so
require_needed libNucleusConfigService.so libNucleusConfig.so
require_needed libNucleusConfigService.so libNucleusConfigIO.so
require_needed libNucleusConfigService.so libNucleusLinux.so
require_needed libNucleusConfigService.so libNucleusSessionProtocol.so
require_needed libNucleusControlService.so libNucleusIPCTransport.so
require_needed libNucleusControlService.so libNucleusControlProtocol.so
require_needed libNucleusControlService.so libNucleusLinux.so
require_needed libNucleusControlService.so libNucleusSessionProtocol.so
require_needed nucleus libNucleusControlClient.so

for forbidden in \
  libNucleus.so \
  libNucleusLinuxDesktop.so \
  libNucleusConfigIO.so \
  libNucleusControlProtocol.so \
  libNucleusControlClient.so
do
  needed "$(artifact_path NucleusSessionSupervisor)" | grep -Fxq "$forbidden" &&
    fail "NucleusSessionSupervisor unexpectedly depends on $forbidden"
done

for artifact in NucleusCompositor NucleusShell; do
  for forbidden in \
    libNucleusConfigIO.so \
    libNucleusConfigService.so \
    libNucleusControlProtocol.so \
    libNucleusControlClient.so \
    libNucleusControlService.so
  do
    needed "$(artifact_path "$artifact")" | grep -Fxq "$forbidden" &&
      fail "$artifact unexpectedly depends on $forbidden"
  done
done

needed "$(artifact_path NucleusCompositor)" |
  grep -Fxq libNucleusShellKit.so &&
  fail "NucleusCompositor unexpectedly depends on libNucleusShellKit.so"

for forbidden in \
  libNucleus.so \
  libNucleusLinuxDesktop.so \
  libNucleusWindowClient.so \
  libNucleusRenderServer.so \
  libNucleusConfigIO.so
do
  needed "$(artifact_path libNucleusControlService.so)" |
    grep -Fxq "$forbidden" &&
    fail "libNucleusControlService.so unexpectedly depends on $forbidden"
done

for forbidden in \
  libNucleus.so \
  libNucleusLinuxDesktop.so \
  libNucleusWindowClient.so \
  libNucleusRenderServer.so \
  libNucleusControlProtocol.so \
  libwayland-client.so.0 \
  libwayland-server.so.0 \
  libdrm.so.2 \
  libgbm.so.1 \
  libvulkan.so.1
do
  needed "$(artifact_path libNucleusConfigService.so)" | grep -Fxq "$forbidden" &&
    fail "libNucleusConfigService.so unexpectedly depends on $forbidden"
done

for forbidden in \
  libvulkan.so.1 \
  libsystemd.so.0 \
  libdrm.so.2 \
  libgbm.so.1 \
  libxcb-ewmh.so.2 \
  libxcb-icccm.so.4 \
  libxcb-composite.so.0 \
  libxcb-xfixes.so.0 \
  libxcb-res.so.0 \
  libxcb.so.1 \
  libinput.so.10 \
  libudev.so.1 \
  libseat.so.1 \
  libxkbcommon.so.0 \
  libfontconfig.so.1 \
  libfreetype.so.6 \
  libz.so.1 \
  libwayland-client.so.0 \
  libwayland-server.so.0 \
  libharfbuzz.so.0 \
  libpng16.so.16 \
  libjpeg.so.8 \
  libwebp.so.7 \
  libexpat.so.1
do
  needed "$(artifact_path NucleusCompositor)" | grep -Fxq "$forbidden" &&
    fail "NucleusCompositor unexpectedly depends directly on $forbidden"
done

for forbidden in \
  libNucleus.so \
  libNucleusLinuxDesktop.so \
  libNucleusConfigIO.so
do
  needed "$(artifact_path nucleus)" | grep -Fxq "$forbidden" &&
    fail "nucleus unexpectedly depends on $forbidden"
done

for forbidden in \
  libdrm.so.2 \
  libgbm.so.1 \
  libinput.so.10 \
  libudev.so.1 \
  libseat.so.1 \
  libxcb.so.1 \
  libwayland-server.so.0
do
  needed "$(artifact_path libNucleusWindowClient.so)" | grep -Fxq "$forbidden" &&
    fail "libNucleusWindowClient.so unexpectedly depends on $forbidden"
done

if [[ $staged -eq 1 ]]; then
  for artifact in \
    "$products/bin/NucleusCompositor" \
    "$products/bin/NucleusShell" \
    "$products/bin/nucleus" \
    "$products/libexec/NucleusConfigService" \
    "$products/libexec/NucleusControlService" \
    "$products/libexec/NucleusSessionSupervisor" \
    "$products/libexec/NucleusShellPamHelper"
  do
    [[ -x "$artifact" ]] ||
      fail "staged executable is missing or non-executable: $artifact"
  done

  for helper_forbidden in \
    libNucleus.so \
    libNucleusLinux.so \
    libNucleusLinuxDesktop.so \
    libNucleusWindowClient.so \
    libNucleusRenderServer.so \
    libNucleusShellKit.so \
    libSwiftVulkan.so \
    libvulkan.so.1 \
    libwayland-client.so.0 \
    libwayland-server.so.0 \
    libdrm.so.2 \
    libgbm.so.1
  do
    needed "$(artifact_path NucleusShellPamHelper)" |
      grep -Fxq "$helper_forbidden" &&
      fail "NucleusShellPamHelper unexpectedly depends on $helper_forbidden"
  done

  while IFS= read -r artifact; do
    readelf -h "$artifact" >/dev/null 2>&1 || continue
    dynamic=$(readelf -d "$artifact")
    if grep -Eq \
      '/home/|/Users/|/nucleus-native-sdk|/\\.nucleus/|/Products/' \
      <<<"$dynamic"
    then
      fail "$artifact retains a development path in its dynamic metadata"
    fi

    relocation=$(ldd -r "$artifact" 2>&1) ||
      fail "$artifact failed relocation validation: $relocation"
    grep -q 'not found' <<<"$relocation" &&
      fail "$artifact has an unresolved dependency: $relocation"

    while read -r dependency resolved; do
      [[ -n "$dependency" && -n "$resolved" ]] || continue
      expected=$(readlink -f "$products/lib/$dependency")
      resolved=$(readlink -f "$resolved")
      [[ "$resolved" == "$expected" ]] ||
        fail "$artifact resolves $dependency outside the staged tree: $resolved"
    done < <(
      awk '
        $1 ~ /^lib(Nucleus|Swift).*[.]so([.][0-9]+)*$/ && $2 == "=>" {
          print $1, $3
        }
      ' <<<"$relocation"
    )
  done < <(
    find "$products/bin" "$products/lib" "$products/libexec" \
      -maxdepth 1 -type f -print | LC_ALL=C sort
  )
fi

skia_pattern='_ZN(K)?[0-9]+Sk|_ZN[0-9]+skgpu|_ZN[0-9]+skia'
owner_skia_count=$(
  nm --defined-only "$(artifact_path libNucleus.so)" |
    grep -Ec "$skia_pattern" || true
)
[[ "$owner_skia_count" -gt 0 ]] ||
  fail "libNucleus.so contains no Skia implementation symbols"

for artifact in "${libraries[@]}" "${executables[@]}"; do
  [[ "$artifact" == libNucleus.so ]] && continue
  if nm --defined-only "$(artifact_path "$artifact")" | grep -Eq "$skia_pattern"; then
    fail "$artifact contains Skia implementation symbols"
  fi
done

if nm -D --defined-only "$(artifact_path libNucleus.so)" |
  grep -Eq "$skia_pattern"
then
  fail "libNucleus.so exports Skia implementation symbols"
fi

ipc_owners=$(
  for artifact in "${libraries[@]}" "${executables[@]}"; do
    if nm -D --defined-only "$(artifact_path "$artifact")" |
      grep -Eq ' nucleus_ipc_(send|receive|connect|listen|accept|socket_pair)$'
    then
      printf '%s\n' "$artifact"
    fi
  done
)
[[ "$ipc_owners" == libNucleusIPCTransport.so ]] ||
  fail "packet transport implementation owners are '${ipc_owners:-<none>}'"

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
: >"$temporary/symbols"
: >"$manifest"

for artifact in "${libraries[@]}" "${executables[@]}"; do
  nm -D --defined-only --format=posix "$(artifact_path "$artifact")" |
    awk -v artifact="$artifact" '
      ($1 ~ /^\$s/ || $1 ~ /^nucleus_/ || $1 ~ /^wl_.*_interface$/) {
        print $1 "\t" artifact
      }
    ' >>"$temporary/symbols"
done

LC_ALL=C sort -k1,1 -k2,2 "$temporary/symbols" >"$manifest"
duplicates=$(
  cut -f1 "$manifest" |
    uniq -d |
    head -20
)
[[ -z "$duplicates" ]] ||
  fail "first-party dynamic symbols have multiple owners: $duplicates"

echo "runtime ELF validation passed: $manifest"
