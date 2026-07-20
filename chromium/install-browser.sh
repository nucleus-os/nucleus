#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/scripts/chromium-env.sh"

prefix="${PREFIX:-$HOME/.local}"
out_dir="${CHROMIUM_BROWSER_OUT}"
widevine_dir="${NUCLEUS_WIDEVINE_DIR:-}"

usage() {
  cat <<'EOF'
Usage: chromium/install-browser.sh [--prefix DIR] [--out-dir DIR] [--widevine-dir DIR]

Stages the completed Chromium output under a relocatable private runtime,
installs the launcher and desktop entry, and configures either the
setuid sandbox (when run as root) or Chromium's user-namespace sandbox.

Options:
  --prefix DIR   Install prefix. Default: $PREFIX or ~/.local
  --out-dir DIR  Chromium GN output. Default: $CHROMIUM_BROWSER_OUT
  --widevine-dir DIR
                 Existing WidevineCdm directory to stage. When omitted, use
                 the build output or an installed Google Chrome CDM.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      prefix="$2"
      shift
      ;;
    --out-dir)
      out_dir="$2"
      shift
      ;;
    --widevine-dir)
      widevine_dir="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -x "$out_dir/chrome" ]]; then
  echo "Chromium has not been built: $out_dir/chrome is missing" >&2
  exit 1
fi
if [[ ! -f "$out_dir/product_logo_128.png" ]]; then
  echo "required Chromium application icon is missing: $out_dir/product_logo_128.png" >&2
  exit 1
fi

runtime_dir="$prefix/lib/nucleus-browser"
prepared="$prefix/lib/.nucleus-browser.$$.prepared"
previous="$prefix/lib/.nucleus-browser.$$.previous"
trap 'rm -rf "$prepared" "$previous"' EXIT
rm -rf "$prepared"
mkdir -p "$prepared"

install_required() {
  local source="$out_dir/$1"
  local destination="${2:-$1}"
  local mode="${3:-0644}"
  if [[ ! -e "$source" ]]; then
    echo "required browser runtime artifact is missing: $source" >&2
    exit 1
  fi
  install -D -m "$mode" "$source" "$prepared/$destination"
}

install_optional() {
  local source="$out_dir/$1"
  local destination="${2:-$1}"
  local mode="${3:-0644}"
  if [[ -e "$source" ]]; then
    install -D -m "$mode" "$source" "$prepared/$destination"
  fi
}

install_required chrome nucleus-browser-bin 0755
install_required chrome_crashpad_handler chrome_crashpad_handler 0755
install_required icudtl.dat
install_required resources.pak
install_required chrome_100_percent.pak
install_required chrome_200_percent.pak
if [[ -f "$out_dir/v8_context_snapshot.bin" ]]; then
  install_required v8_context_snapshot.bin
elif [[ -f "$out_dir/snapshot_blob.bin" ]]; then
  install_required snapshot_blob.bin
else
  echo "required V8 startup snapshot is missing from $out_dir" >&2
  exit 1
fi
install_optional chrome_management_service chrome_management_service 0755

# These are ANGLE's Vulkan frontend libraries. Their historical EGL/GLES names
# do not imply an OpenGL compositor fallback.
install_required libEGL.so libEGL.so 0755
install_required libGLESv2.so libGLESv2.so 0755
install_required libvulkan.so.1 libvulkan.so.1 0755

for directory in \
  locales \
  default_apps \
  MEIPreload \
  PrivacySandboxAttestationsPreloaded; do
  if [[ -d "$out_dir/$directory" ]]; then
    cp -a "$out_dir/$directory" "$prepared/$directory"
  fi
done

if [[ ! -d "$prepared/locales" ]]; then
  echo "required browser locale bundle is missing: $out_dir/locales" >&2
  exit 1
fi

if [[ -z "$widevine_dir" ]]; then
  for candidate in \
    "$out_dir/WidevineCdm" \
    /opt/google/chrome/WidevineCdm \
    /opt/google/chrome-unstable/WidevineCdm; do
    if [[ -f "$candidate/manifest.json" ]] &&
       [[ -f "$candidate/_platform_specific/linux_x64/libwidevinecdm.so" ]]; then
      widevine_dir="$candidate"
      break
    fi
  done
fi
if [[ -z "$widevine_dir" ]] ||
   [[ ! -f "$widevine_dir/manifest.json" ]] ||
   [[ ! -f "$widevine_dir/_platform_specific/linux_x64/libwidevinecdm.so" ]]; then
  echo "a complete Linux x64 WidevineCdm directory is required" >&2
  echo "pass --widevine-dir or install Google Chrome's Widevine component" >&2
  exit 1
fi
cp -a "$widevine_dir" "$prepared/WidevineCdm"

if [[ $EUID -eq 0 ]]; then
  if [[ ! -x "$out_dir/chrome_sandbox" ]]; then
    echo "setuid sandbox artifact is missing: $out_dir/chrome_sandbox" >&2
    exit 1
  fi
  install -o root -g root -m 4755 "$out_dir/chrome_sandbox" \
    "$prepared/chrome-sandbox"
else
  userns_enabled=1
  if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
    userns_enabled="$(< /proc/sys/kernel/unprivileged_userns_clone)"
  fi
  if [[ "$userns_enabled" != 1 ]]; then
    echo "unprivileged user namespaces are disabled; rerun as root to install the setuid sandbox" >&2
    exit 1
  fi
fi

rm -rf "$previous"
if [[ -e "$runtime_dir" ]]; then
  mv "$runtime_dir" "$previous"
fi
if ! mv "$prepared" "$runtime_dir"; then
  if [[ -e "$previous" ]]; then
    mv "$previous" "$runtime_dir"
  fi
  exit 1
fi
rm -rf "$previous"

install -D -m 0755 "$script_dir/launcher/nucleus-browser" \
  "$prefix/bin/nucleus-browser"
install -D -m 0644 \
  "$script_dir/share/applications/dev.nucleus.Browser.desktop" \
  "$prefix/share/applications/dev.nucleus.Browser.desktop"
for size in 16 22 24 32 48 64 128 256; do
  if [[ -f "$out_dir/product_logo_${size}.png" ]]; then
    # The external product name is Nucleus Browser, but until a dedicated icon
    # exists it intentionally uses Chromium's generated application icon.
    install -D -m 0644 "$out_dir/product_logo_${size}.png" \
      "$prefix/share/icons/hicolor/${size}x${size}/apps/dev.nucleus.Browser.png"
  fi
done

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
fi

echo "Nucleus Browser installed"
echo "launcher: $prefix/bin/nucleus-browser"
echo "runtime:  $runtime_dir"
