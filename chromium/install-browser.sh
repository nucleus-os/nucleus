#!/usr/bin/env bash
# Internal atomic installer for the latest validated browser artifact.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/scripts/chromium-env.sh"

if [[ "${NUCLEUS_CHROMIUM_ORCHESTRATED:-0}" != 1 ]]; then
  echo "install-browser.sh is internal; use tools/nucleus chromium install" >&2
  exit 2
fi

prefix="${PREFIX:-$HOME/.local}"
prefix="$(realpath -m -- "$prefix")"
artifact="$NUCLEUS_BROWSER_DIST_ROOT/current"
metadata="$script_dir/scripts/build-metadata.py"
atomic_publish="$workspace_root/cef/scripts/atomic-publish-directory.py"

[[ -d "$artifact" && ! -L "$artifact/runtime" ]] || {
  echo "validated browser artifact is missing: $artifact" >&2
  exit 1
}
build_manifest="$artifact/nucleus-build-manifest.json"
build_id="$(python3 "$metadata" build-id --manifest "$build_manifest")"
[[ "$(readlink "$NUCLEUS_BROWSER_DIST_ROOT/current")" == "generations/$build_id" ]] || {
  echo "browser artifact current pointer does not match its build manifest" >&2
  exit 1
}

widevine_dir=""
for candidate in \
  "$artifact/runtime/WidevineCdm" \
  /opt/google/chrome/WidevineCdm \
  /opt/google/chrome-unstable/WidevineCdm; do
  if [[ -f "$candidate/manifest.json" ]] &&
     [[ -f "$candidate/_platform_specific/linux_x64/libwidevinecdm.so" ]]; then
    widevine_dir="$candidate"
    break
  fi
done
[[ -n "$widevine_dir" ]] || {
  echo "a complete Linux x64 WidevineCdm installation is required" >&2
  exit 1
}
widevine_id="$(
  sha256sum \
    "$widevine_dir/manifest.json" \
    "$widevine_dir/_platform_specific/linux_x64/libwidevinecdm.so" |
    sha256sum | cut -d' ' -f1
)"

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
  [[ -d "$path" && ! -L "$path" ]] &&
    [[ "$(stat -c '%u:%g:%a' "$path" 2>/dev/null)" == "0:0:755" ]]
}

system_sandbox_dir="/usr/local/libexec/nucleus-browser"
system_sandbox="$system_sandbox_dir/chrome-sandbox"
sandbox_source="$artifact/runtime/chrome_sandbox"
sandbox_id="user-namespace"
if ! user_namespace_sandbox_works; then
  [[ -x "$sandbox_source" ]] || {
    echo "setuid sandbox build artifact is missing: $sandbox_source" >&2
    exit 1
  }
  if ! setuid_sandbox_directory_is_valid "$system_sandbox_dir" ||
     ! setuid_sandbox_is_valid "$system_sandbox" ||
     ! cmp -s "$sandbox_source" "$system_sandbox"; then
    echo "Unprivileged user namespaces are unavailable; updating the setuid sandbox."
    sudo install -d -o root -g root -m 0755 "$system_sandbox_dir"
    sudo install -o root -g root -m 4755 "$sandbox_source" "$system_sandbox"
  fi
  setuid_sandbox_directory_is_valid "$system_sandbox_dir" &&
    setuid_sandbox_is_valid "$system_sandbox" &&
    cmp -s "$sandbox_source" "$system_sandbox" || {
      echo "setuid sandbox installation is invalid: $system_sandbox" >&2
      exit 1
    }
  sandbox_id="$(sha256sum "$system_sandbox" | cut -d' ' -f1)"
fi

launcher_path="$prefix/bin/nucleus-browser"
if [[ "$launcher_path" == *$'\n'* ||
      "$launcher_path" == *$'\r'* ||
      "$launcher_path" == *'\\'* ||
      "$launcher_path" == *'"'* ||
      "$launcher_path" == *'$'* ||
      "$launcher_path" == *'`'* ||
      "$launcher_path" == *'%'* ]]; then
  echo "install prefix cannot be represented safely in a desktop Exec field: $prefix" >&2
  exit 1
fi

install_id="$(
  printf '%s\n' \
    "$build_id" \
    "$widevine_id" \
    "$sandbox_id" \
    "$prefix" \
    "$(sha256sum "$artifact/bin/nucleus-browser" | cut -d' ' -f1)" \
    "$(sha256sum "$artifact/share/applications/dev.nucleus.Browser.desktop.in" | cut -d' ' -f1)" |
    sha256sum | cut -c1-24
)"

runtime_root="$prefix/lib/nucleus-browser"
generations="$runtime_root/generations"
mkdir -p "$generations"
prepared="$(mktemp -d "$generations/.${install_id}.XXXXXX.prepared")"
trap '[[ -z "${prepared:-}" || ! -d "$prepared" ]] || rm -rf -- "$prepared"' EXIT
cp -a "$artifact/." "$prepared/"
cp -a "$widevine_dir" "$prepared/runtime/WidevineCdm"

desktop="$prepared/share/applications/dev.nucleus.Browser.desktop"
while IFS= read -r line || [[ -n "$line" ]]; do
  printf '%s\n' "${line//@NUCLEUS_BROWSER_LAUNCHER@/$launcher_path}"
done < "$prepared/share/applications/dev.nucleus.Browser.desktop.in" > "$desktop"
rm -f "$prepared/share/applications/dev.nucleus.Browser.desktop.in"
bash -n "$prepared/bin/nucleus-browser"
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$desktop"
fi
if ldd "$prepared/runtime/nucleus-browser-bin" | grep -F 'not found'; then
  echo "installed browser generation has unresolved dynamic libraries" >&2
  exit 1
fi

python3 - "$prepared/nucleus-install-manifest.json" \
  "$install_id" "$build_id" "$widevine_id" "$sandbox_id" "$prefix" <<'PY'
import json
import sys

path, install_id, build_id, widevine_id, sandbox_id, prefix = sys.argv[1:]
with open(path, "w", encoding="utf-8") as destination:
    json.dump(
        {
            "schema": 1,
            "install_id": install_id,
            "build_id": build_id,
            "widevine_sha256": widevine_id,
            "sandbox": sandbox_id,
            "prefix": prefix,
        },
        destination,
        indent=2,
        sort_keys=True,
    )
    destination.write("\n")
PY

python3 "$atomic_publish" "$prepared" "$generations/$install_id"
prepared=""

atomic_symlink() {
  local target="$1"
  local destination="$2"
  local temporary="$(dirname "$destination")/.${destination##*/}.$$.tmp"
  mkdir -p "$(dirname "$destination")"
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$destination"
}

atomic_symlink \
  "../lib/nucleus-browser/current/bin/nucleus-browser" \
  "$prefix/bin/nucleus-browser"
atomic_symlink \
  "../../lib/nucleus-browser/current/share/applications/dev.nucleus.Browser.desktop" \
  "$prefix/share/applications/dev.nucleus.Browser.desktop"
for icon in "$generations/$install_id"/share/icons/hicolor/*/apps/dev.nucleus.Browser.png; do
  size="$(basename "$(dirname "$(dirname "$icon")")")"
  atomic_symlink \
    "../../../../../lib/nucleus-browser/current/share/icons/hicolor/$size/apps/dev.nucleus.Browser.png" \
    "$prefix/share/icons/hicolor/$size/apps/dev.nucleus.Browser.png"
done

current_temporary="$runtime_root/.current.$$.tmp"
ln -s "generations/$install_id" "$current_temporary"
mv -Tf "$current_temporary" "$runtime_root/current"
python3 "$script_dir/scripts/prune-cache.py" installed \
  --runtime-root "$runtime_root"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$prefix/share/applications" >/dev/null 2>&1 || true
fi

trap - EXIT
echo "Nucleus Browser installed"
echo "generation: $runtime_root/current"
echo "launcher:   $prefix/bin/nucleus-browser"
