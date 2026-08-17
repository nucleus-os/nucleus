#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  swiftpm)
    shift
    if [[ -n "${NUCLEUS_SWIFTPM_SCRATCH:-}" ]]; then
      input=${NUCLEUS_SWIFTPM_INPUT:?}
      scratch=$NUCLEUS_SWIFTPM_SCRATCH
      products=${NUCLEUS_SWIFTPM_PRODUCTS:?}
      host_products=${NUCLEUS_SWIFTPM_HOST_PRODUCTS:?}
      mkdir -p "$scratch/.collider" "$products"
      if [[ -n "${NUCLEUS_SWIFTPM_RETAIN_CONTEXTS:-}" ]]; then
        retain_contexts=$NUCLEUS_SWIFTPM_RETAIN_CONTEXTS
        workspace_root=${NUCLEUS_SWIFTPM_WORKSPACE_ROOT:-/swiftpm-workspace}
        if [[ ! "$retain_contexts" =~ ^[1-9][0-9]*$ \
            || "$workspace_root" != /* \
            || "$workspace_root" == *..* \
            || "$(dirname "$scratch")" != "$workspace_root" \
            || ! "$(basename "$scratch")" =~ ^[0-9a-f]{64}$ ]]; then
          echo "error: invalid SwiftPM workspace retention configuration" >&2
          exit 64
        fi
        touch "$scratch"
        workspace_contexts=()
        for workspace_context in "$workspace_root"/*; do
          if [[ -d "$workspace_context" \
              && "$(basename "$workspace_context")" =~ ^[0-9a-f]{64}$ ]]; then
            workspace_contexts+=("$workspace_context")
          fi
        done
        if (( ${#workspace_contexts[@]} > retain_contexts )); then
          previous_ifs=$IFS
          IFS=$'\n'
          workspace_contexts=($(ls -dt "${workspace_contexts[@]}"))
          IFS=$previous_ifs
          for ((index = retain_contexts;
              index < ${#workspace_contexts[@]}; index++)); do
            rm -rf -- "${workspace_contexts[$index]}"
          done
        fi
      fi
      if [[ -f "$input/.collider/dependencies-resolved" ]] \
          && ! cmp -s \
              "$input/.collider/dependencies-resolved" \
              "$scratch/.collider/dependencies-resolved"; then
        for name in artifacts checkouts repositories workspace-state.json; do
          rm -rf "$scratch/$name"
          if [[ -e "$input/$name" ]]; then
            cp -a "$input/$name" "$scratch/$name"
          fi
        done
        cp "$input/.collider/dependencies-resolved" \
          "$scratch/.collider/dependencies-resolved"
      fi
      export_products=0
      for argument in "$@"; do
        if [[ "$argument" == --show-bin-path ]]; then
          export_products=1
          break
        fi
      done
      if [[ "$export_products" == 1 ]]; then
        bin_path=$("$@")
        find "$products" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        # The export root is a macOS bind mount. Copy the product tree and its
        # symlinks, but do not ask Linux to restore source timestamps or
        # ownership on the mount point; those metadata operations are not part
        # of the artifact and are rejected by the host filesystem boundary.
        cp -R "$bin_path"/. "$products"/
        printf '%s\n' "$host_products"
        exit 0
      fi
    fi
    ;;
  javascript)
    if [[ ! -f package.json || ! -f bun.lock ]]; then
      echo "error: working directory is not the Nucleus React Native workspace" >&2
      exit 64
    fi
    shift
    ;;
  wayland-generate)
    if [[ ! -x /native-wayland/bin/wayland-scanner ]]; then
      echo "error: produced wayland-scanner is not mounted" >&2
      exit 64
    fi
    if [[ ! -d Protocols || ! -d Sources/SwiftWaylandGenerator ]]; then
      echo "error: working directory is not the swift-wayland source root" >&2
      exit 64
    fi
    shift
    ;;
  extract-gn)
    if [[ "$#" -ne 1 \
        || ! -f /archive/gn-linux-arm64.zip \
        || ! -d /output \
        || ! -w /output ]]; then
      echo "error: extract-gn requires /archive/gn-linux-arm64.zip and writable /output" >&2
      exit 64
    fi
    unzip -o /archive/gn-linux-arm64.zip gn -d /output
    chmod 0755 /output/gn
    exit 0
    ;;
  skia-linux | skia-android)
    if [[ ! -d /build || ! -w /build ]]; then
      echo "error: /build is not the writable external native build root" >&2
      exit 64
    fi
    if [[ ! -d /ccache || ! -w /ccache ]]; then
      echo "error: /ccache is not the writable compiler cache" >&2
      exit 64
    fi
    if [[ ! -x /src/bin/gn || ! -f /src/DEPS ]]; then
      echo "error: /src is not the complete read-only Skia checkout" >&2
      exit 64
    fi
    shift
    ;;
  skia-export)
    shift
    if [[ ! -d /build || ! -d /export || ! -w /export || "$#" -eq 0 ]]; then
      echo "error: skia-export requires build and export roots plus archive names" >&2
      exit 64
    fi
    for archive in "$@"; do
      if [[ "$archive" == */* || ! -f "/build/$archive" ]]; then
        echo "error: missing Skia archive: $archive" >&2
        exit 66
      fi
    done
    find /export -mindepth 1 -maxdepth 1 -delete
    for archive in "$@"; do
      install --mode=0644 "/build/$archive" "/export/$archive"
    done
    exit 0
    ;;
  react-native)
    if [[ ! -d /build || ! -w /build ]]; then
      echo "error: /build is not the writable external native build root" >&2
      exit 64
    fi
    if [[ ! -d /ccache || ! -w /ccache ]]; then
      echo "error: /ccache is not the writable compiler cache" >&2
      exit 64
    fi
    if [[ ! -d /react-native/ReactCommon \
        || ! -d /core-cmake ]]; then
      echo "error: React Native builder inputs are incomplete" >&2
      exit 64
    fi
    shift
    ;;
  wayland)
    if [[ ! -d /build || ! -w /build \
        || ! -d /ccache || ! -w /ccache ]]; then
      echo "error: wayland requires writable build and compiler-cache workspaces" >&2
      exit 64
    fi
    if [[ -z "${NUCLEUS_WAYLAND_SDK:-}" \
        || ! -d "${NUCLEUS_WAYLAND_SDK}" \
        || ! -w "${NUCLEUS_WAYLAND_SDK}" ]]; then
      echo "error: NUCLEUS_WAYLAND_SDK is not the writable target Wayland SDK root" >&2
      exit 64
    fi
    if [[ ! -f /src/meson.build || ! -f /src/protocol/wayland.xml ]]; then
      echo "error: /src is not the complete read-only Wayland checkout" >&2
      exit 64
    fi
    shift
    ;;
  *)
    echo "error: expected builder mode: swiftpm, javascript, wayland-generate, extract-gn, skia-linux, skia-android, skia-export, react-native, or wayland" >&2
    exit 64
    ;;
esac

if [[ $# -eq 0 ]]; then
  echo "error: native builder mode has no command" >&2
  exit 64
fi

exec "$@"
