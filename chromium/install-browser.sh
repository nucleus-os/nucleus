#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/scripts/chromium-env.sh"

prefix="${PREFIX:-$HOME/.local}"
out_dir="${CHROMIUM_BROWSER_OUT}"
widevine_dir="${NUCLEUS_WIDEVINE_DIR:-}"

find_product_icon() {
  local size="$1"
  local candidate
  for candidate in \
    "$out_dir/product_logo_${size}.png" \
    "$NUCLEUS_CHROMIUM_SRC_ROOT/chrome/app/theme/chromium/linux/product_logo_${size}.png" \
    "$NUCLEUS_CHROMIUM_SRC_ROOT/chrome/app/theme/default_100_percent/chromium/linux/product_logo_${size}.png" \
    "$NUCLEUS_CHROMIUM_SRC_ROOT/chrome/app/theme/chromium/product_logo_${size}.png"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

usage() {
  cat <<'EOF'
Usage: chromium/install-browser.sh [--prefix DIR] [--out-dir DIR] [--widevine-dir DIR]

Stages the completed Chromium output under a relocatable private runtime,
installs the launcher and desktop entry, and configures a usable Chromium
sandbox. When the kernel denies an actual unprivileged user-namespace probe,
the installer uses sudo for only the root-owned setuid helper.

Options:
  --prefix DIR   Install prefix. Default: $PREFIX or ~/.local
  --out-dir DIR  Chromium GN output. Default: $CHROMIUM_BROWSER_OUT
  --widevine-dir DIR
                 Existing WidevineCdm directory to stage. When omitted, use
                 the build output or an installed Google Chrome CDM.
EOF
}

user_namespace_sandbox_works() {
  command -v unshare >/dev/null 2>&1 &&
    unshare --user --map-root-user -- true >/dev/null 2>&1
}

setuid_sandbox_is_valid() {
  local path="$1"
  [[ -f "$path" ]] &&
    [[ "$(stat -c '%u:%g:%a' "$path" 2>/dev/null)" == "0:0:4755" ]]
}

setuid_sandbox_directory_is_valid() {
  local path="$1"
  [[ -d "$path" ]] &&
    [[ ! -L "$path" ]] &&
    [[ "$(stat -c '%u:%g:%a' "$path" 2>/dev/null)" == "0:0:755" ]]
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
if ! application_icon="$(find_product_icon 128)" &&
   ! application_icon="$(find_product_icon 48)"; then
  echo "required Chromium application icon is missing from the build output and source theme" >&2
  exit 1
fi

runtime_dir="$prefix/lib/nucleus-browser"
prepared="$prefix/lib/.nucleus-browser.$$.prepared"
previous="$prefix/lib/.nucleus-browser.$$.previous"
trap 'rm -rf "$prepared" "$previous"' EXIT
rm -rf "$prepared"
install -d -m 0755 "$prepared"

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

system_sandbox_dir="/usr/local/libexec/nucleus-browser"
system_sandbox="$system_sandbox_dir/chrome-sandbox"
if [[ $EUID -eq 0 ]]; then
  if [[ ! -x "$out_dir/chrome_sandbox" ]]; then
    echo "setuid sandbox artifact is missing: $out_dir/chrome_sandbox" >&2
    exit 1
  fi
  install -o root -g root -m 0755 "$out_dir/chrome_sandbox" \
    "$prepared/chrome-sandbox"
  chmod 4755 "$prepared/chrome-sandbox"
elif ! user_namespace_sandbox_works; then
  if [[ ! -x "$out_dir/chrome_sandbox" ]]; then
    echo "setuid sandbox artifact is missing: $out_dir/chrome_sandbox" >&2
    exit 1
  fi
  if setuid_sandbox_directory_is_valid "$system_sandbox_dir" &&
     setuid_sandbox_is_valid "$system_sandbox" &&
     cmp -s "$out_dir/chrome_sandbox" "$system_sandbox"; then
    echo "Installed setuid sandbox is already current."
  else
    if ! command -v sudo >/dev/null 2>&1; then
      echo "unprivileged user namespaces are unavailable and sudo is missing" >&2
      echo "install $out_dir/chrome_sandbox as root:root mode 4755 at $system_sandbox" >&2
      exit 1
    fi
    echo "Unprivileged user namespaces are unavailable; installing the setuid sandbox."
    sudo install -d -o root -g root -m 0755 "$system_sandbox_dir"
    if ! setuid_sandbox_directory_is_valid "$system_sandbox_dir"; then
      echo "setuid sandbox directory is not securely installed: $system_sandbox_dir" >&2
      exit 1
    fi
    sudo install -o root -g root -m 0755 \
      "$out_dir/chrome_sandbox" "$system_sandbox"
    sudo chmod 4755 "$system_sandbox"
  fi
  if ! setuid_sandbox_is_valid "$system_sandbox"; then
    echo "setuid sandbox installation is invalid: $system_sandbox" >&2
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
  if icon_source="$(find_product_icon "$size")"; then
    # The external product name is Nucleus Browser, but until a dedicated icon
    # exists it intentionally uses Chromium's application icon.
    install -D -m 0644 "$icon_source" \
      "$prefix/share/icons/hicolor/${size}x${size}/apps/dev.nucleus.Browser.png"
  fi
done

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
fi

echo "Nucleus Browser installed"
echo "launcher: $prefix/bin/nucleus-browser"
echo "runtime:  $runtime_dir"
