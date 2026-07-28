#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: normalize-runtime-elf.sh PRODUCTS_DIRECTORY" >&2
  exit 64
fi

products=$1
compositor="$products/NucleusCompositor"

[[ -f "$compositor" ]] || {
  echo "runtime ELF normalization failed: missing $compositor" >&2
  exit 1
}

# SwiftPM propagates a dynamic product's native linker settings into consumers.
# Those libraries are unused by the composition-root object but lld records them
# as direct NEEDED entries. Remove only the render-server closure that is already
# owned and resolved by libNucleusRenderServer.so.
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
  if patchelf --print-needed "$compositor" | grep -Fxq "$dependency"; then
    patchelf --remove-needed "$dependency" "$compositor"
  fi
done

echo "runtime ELF normalization passed: $compositor"
