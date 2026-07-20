#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/scripts/chromium-env.sh"

prefix="${PREFIX:-$HOME/.local}"
runtime_dir="$prefix/lib/nucleus-browser"
private_vaapi_dir="${NUCLEUS_NVIDIA_VAAPI_DIR:-$HOME/.local/lib/nvidia-vaapi-driver/current/lib/dri}"
missing=0

check_required() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf 'ok      %s\n' "$path"
  else
    printf 'missing %s\n' "$path"
    missing=$((missing + 1))
  fi
}

report_file() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf 'present %s\n' "$path"
  else
    printf 'absent  %s\n' "$path"
  fi
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

echo "Nucleus Browser diagnostics"
echo "Wayland display: ${WAYLAND_DISPLAY:-<unset>}"
echo "build output:    $CHROMIUM_BROWSER_OUT"
echo "runtime:         $runtime_dir"
echo

check_required "$prefix/bin/nucleus-browser"
check_required "$prefix/share/applications/dev.nucleus.Browser.desktop"
check_required \
  "$prefix/share/icons/hicolor/128x128/apps/dev.nucleus.Browser.png"
check_required "$runtime_dir/nucleus-browser-bin"
check_required "$runtime_dir/chrome_crashpad_handler"
check_required "$runtime_dir/resources.pak"
check_required "$runtime_dir/chrome_100_percent.pak"
check_required "$runtime_dir/chrome_200_percent.pak"
check_required "$runtime_dir/icudtl.dat"
check_required "$runtime_dir/locales"
check_required "$runtime_dir/libEGL.so"
check_required "$runtime_dir/libGLESv2.so"
check_required "$runtime_dir/libvulkan.so.1"
check_required "$runtime_dir/WidevineCdm/manifest.json"
check_required \
  "$runtime_dir/WidevineCdm/_platform_specific/linux_x64/libwidevinecdm.so"
if [[ -f "$runtime_dir/v8_context_snapshot.bin" ]] ||
   [[ -f "$runtime_dir/snapshot_blob.bin" ]]; then
  echo "ok      V8 startup snapshot"
else
  echo "missing V8 startup snapshot"
  missing=$((missing + 1))
fi
report_file "$CHROMIUM_BROWSER_OUT/chrome"
if [[ -e /proc/driver/nvidia/version ]]; then
  echo "NVIDIA kernel driver: present (GPU-child selection follows Wayland main_device)"
  report_file "$private_vaapi_dir/nvidia_drv_video.so"
else
  echo "NVIDIA kernel driver: absent; system VA-API discovery applies"
fi

runtime_sandbox="$runtime_dir/chrome-sandbox"
system_sandbox_dir="/usr/local/libexec/nucleus-browser"
system_sandbox="$system_sandbox_dir/chrome-sandbox"
if [[ -e "$runtime_sandbox" ]]; then
  if setuid_sandbox_is_valid "$runtime_sandbox" &&
     setuid_sandbox_directory_is_valid "$runtime_dir"; then
    stat -c 'sandbox helper: %A %U:%G %n' "$runtime_sandbox"
  else
    stat -c 'invalid sandbox helper: %A %U:%G %n' "$runtime_sandbox"
    echo "adjacent helper requires a root-owned mode-0755 runtime directory"
    missing=$((missing + 1))
  fi
elif [[ -e "$system_sandbox" ]]; then
  if setuid_sandbox_is_valid "$system_sandbox" &&
     setuid_sandbox_directory_is_valid "$system_sandbox_dir"; then
    stat -c 'sandbox helper: %A %U:%G %n' "$system_sandbox"
  elif user_namespace_sandbox_works; then
    stat -c 'ignored invalid sandbox helper: %A %U:%G %n' "$system_sandbox"
    echo "sandbox: user-namespace mode (runtime probe succeeded)"
  else
    stat -c 'invalid sandbox helper: %A %U:%G %n' "$system_sandbox"
    echo "system helper requires a root-owned mode-0755 directory"
    missing=$((missing + 1))
  fi
elif user_namespace_sandbox_works; then
  echo "sandbox helper: user-namespace mode (runtime probe succeeded)"
else
  echo "missing usable Chromium sandbox (user-namespace probe failed)"
  missing=$((missing + 1))
fi

echo
echo "Runtime renderer/media facts are reported by Chromium's chrome://gpu and chrome://media-internals pages."
echo "Expected compositor: Skia Graphite / Dawn Vulkan on the Wayland main_device."

if [[ $missing -ne 0 ]]; then
  echo "$missing required runtime artifact(s) are missing." >&2
  exit 1
fi
