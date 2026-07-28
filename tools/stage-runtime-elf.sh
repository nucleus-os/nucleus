#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: stage-runtime-elf.sh PRODUCTS_DIRECTORY STAGING_PREFIX" >&2
  exit 64
fi

products=$1
prefix=$2

libraries=(
  libNucleusFoundation.so
  libNucleus.so
  libNucleusLinux.so
  libNucleusLinuxDesktop.so
  libNucleusConfig.so
  libNucleusConfigIO.so
  libNucleusConfigService.so
  libNucleusIPCTransport.so
  libNucleusControlProtocol.so
  libNucleusControlClient.so
  libNucleusControlService.so
  libNucleusWindowClient.so
  libNucleusRenderServer.so
  libNucleusShellKit.so
  libSwiftWaylandProtocolRuntime.so
  libSwiftVulkan.so
  libSwiftTracy.so
  libNucleusSessionProtocol.so
)

bin_executables=(
  NucleusCompositor
  NucleusShell
  nucleus
)

libexec_executables=(
  NucleusConfigService
  NucleusControlService
  NucleusShellPamHelper
  NucleusSessionSupervisor
)

fail() {
  echo "runtime ELF staging failed: $*" >&2
  exit 1
}

copy_artifact() {
  local name=$1 destination=$2
  [[ -f "$products/$name" ]] ||
    fail "missing build artifact $products/$name"
  install -m 0755 "$products/$name" "$destination/$name"
}

mkdir -p "$prefix/bin" "$prefix/lib" "$prefix/libexec" "$prefix/share/nucleus"

for artifact in "${libraries[@]}"; do
  copy_artifact "$artifact" "$prefix/lib"
done
for artifact in "${bin_executables[@]}"; do
  copy_artifact "$artifact" "$prefix/bin"
done
for artifact in "${libexec_executables[@]}"; do
  copy_artifact "$artifact" "$prefix/libexec"
done

# SwiftPM propagates the render-server's native linker settings into its
# composition-root executable. The implementation DSO owns those dependencies;
# remove the unused direct edges from the launch stub.
server_native_dependencies=(
  libvulkan.so.1
  libsystemd.so.0
  libdrm.so.2
  libgbm.so.1
  libxcb-ewmh.so.2
  libxcb-icccm.so.4
  libxcb-composite.so.0
  libxcb-xfixes.so.0
  libxcb-res.so.0
  libxcb.so.1
  libinput.so.10
  libudev.so.1
  libseat.so.1
  libxkbcommon.so.0
  libfontconfig.so.1
  libfreetype.so.6
  libz.so.1
  libwayland-client.so.0
  libwayland-server.so.0
  libharfbuzz.so.0
  libpng16.so.16
  libjpeg.so.8
  libwebp.so.7
  libexpat.so.1
)

for dependency in "${server_native_dependencies[@]}"; do
  if patchelf --print-needed "$prefix/bin/NucleusCompositor" |
    grep -Fxq "$dependency"
  then
    patchelf --remove-needed "$dependency" "$prefix/bin/NucleusCompositor"
  fi
done

# Resolve the non-system dynamic closure while the copied artifacts still carry
# their build-time runpaths. Host libraries under /lib and /usr/lib remain host
# dependencies. Toolchain-owned Swift, Foundation, Dispatch, libc++, and unwind
# libraries are copied into the runtime so the installed tree has no dependency
# on a developer toolchain path.
queue=()
for artifact in "$prefix"/bin/* "$prefix"/lib/* "$prefix"/libexec/*; do
  [[ -f "$artifact" ]] && queue+=("$artifact")
done

index=0
while [[ $index -lt ${#queue[@]} ]]; do
  artifact=${queue[$index]}
  index=$((index + 1))

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /lib/*|/lib64/*|/usr/lib/*|/usr/lib64/*)
        continue
        ;;
    esac

    name=${dependency##*/}
    destination="$prefix/lib/$name"
    if [[ -e "$destination" ]]; then
      continue
    fi
    [[ -f "$dependency" ]] ||
      fail "$artifact resolves a dependency to a missing file: $dependency"
    install -m 0755 "$dependency" "$destination"
    queue+=("$destination")
  done < <(
    ldd "$artifact" |
      awk '
        /=> \// { print $3; next }
        /^[[:space:]]*\// { sub(/^[[:space:]]*/, "", $1); print $1 }
      '
  )
done

for artifact in "$prefix"/lib/*; do
  patchelf --set-rpath '$ORIGIN' "$artifact"
done
for artifact in "$prefix"/bin/NucleusCompositor \
                "$prefix"/bin/NucleusShell \
                "$prefix"/bin/nucleus \
                "$prefix"/libexec/*; do
  patchelf --set-rpath '$ORIGIN/../lib' "$artifact"
done

# Strip only debug sections. Swift reflection metadata, dynamic symbols, and
# executable entry points remain intact and are validated after staging.
for artifact in "$prefix"/bin/NucleusCompositor \
                "$prefix"/bin/NucleusShell \
                "$prefix"/bin/nucleus \
                "$prefix"/lib/* \
                "$prefix"/libexec/*; do
  strip --strip-debug "$artifact"
done

echo "runtime ELF staging passed: $prefix"
