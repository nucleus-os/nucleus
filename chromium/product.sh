#!/usr/bin/env bash
# Internal standalone-browser product stages. Use `tools/nucleus chromium ...`.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/scripts/chromium-env.sh"

if [[ "${NUCLEUS_CHROMIUM_ORCHESTRATED:-0}" != 1 ]]; then
  echo "chromium/product.sh is an internal product stage; use tools/nucleus chromium" >&2
  exit 2
fi

operation="${1:-}"
if [[ $# -ne 1 || ! "$operation" =~ ^(build|package|validate|test)$ ]]; then
  echo "internal usage: chromium/product.sh build|package|validate|test" >&2
  exit 2
fi

metadata="$script_dir/scripts/build-metadata.py"
atomic_publish="$workspace_root/cef/scripts/atomic-publish-directory.py"
source_manifest="$NUCLEUS_CEF_SRC_ROOT/nucleus-source-manifest.json"
built_manifest="$CHROMIUM_BROWSER_OUT/.nucleus-built-build.json"
export PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0

verify_source() {
  python3 "$metadata" verify-source \
    --workspace "$workspace_root" \
    --cef-branch "$NUCLEUS_CEF_BRANCH" \
    --cef-checkout "$NUCLEUS_CEF_CHECKOUT" \
    --chromium-version "$NUCLEUS_CEF_CHROMIUM_VERSION" \
    --chromium-checkout "$NUCLEUS_CHROMIUM_CHECKOUT" \
    --depot-tools-revision "$NUCLEUS_DEPOT_TOOLS_REVISION" \
    --source-root "$NUCLEUS_CEF_SRC_ROOT" \
    --depot-tools "$NUCLEUS_CEF_DEPOT_TOOLS" \
    --manifest "$source_manifest" >/dev/null
}

build_metadata() {
  local mode="$1"
  local manifest="$2"
  python3 "$metadata" "$mode" \
    --product browser \
    --source-root "$NUCLEUS_CEF_SRC_ROOT" \
    --source-manifest "$source_manifest" \
    --gn-args "$CHROMIUM_BROWSER_OUT/args.gn" \
    --manifest "$manifest"
}

find_product_icon() {
  local size="$1"
  local candidate
  for candidate in \
    "$CHROMIUM_BROWSER_OUT/product_logo_${size}.png" \
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

build_browser() {
  verify_source
  echo "-- generating standalone browser GN output"
  (
    cd "$NUCLEUS_CHROMIUM_SRC_ROOT"
    "$NUCLEUS_CHROMIUM_SRC_ROOT/buildtools/linux64/gn" gen \
      "$CHROMIUM_BROWSER_OUT" --args="$CHROMIUM_BROWSER_GN_DEFINES_BASE"
  )
  local expected="$CHROMIUM_BROWSER_OUT/.nucleus-expected-build.json"
  build_metadata write-build "$expected" >/dev/null
  echo "-- building Nucleus Browser with $NUCLEUS_CHROMIUM_JOBS local Siso jobs"
  autoninja -j "$NUCLEUS_CHROMIUM_JOBS" -C "$CHROMIUM_BROWSER_OUT" \
    chrome chrome_sandbox
  local temporary="$CHROMIUM_BROWSER_OUT/.nucleus-built-build.$$.tmp"
  install -m 0644 "$expected" "$temporary"
  mv -f "$temporary" "$built_manifest"
  build_metadata verify-build "$built_manifest" >/dev/null
}

install_required() {
  local destination_root="$1"
  local source_name="$2"
  local destination_name="${3:-$source_name}"
  local mode="${4:-0644}"
  local source="$CHROMIUM_BROWSER_OUT/$source_name"
  [[ -e "$source" ]] || {
    echo "required browser artifact is missing: $source" >&2
    exit 1
  }
  install -D -m "$mode" "$source" "$destination_root/$destination_name"
}

install_optional() {
  local destination_root="$1"
  local source_name="$2"
  local destination_name="${3:-$source_name}"
  local mode="${4:-0644}"
  if [[ -e "$CHROMIUM_BROWSER_OUT/$source_name" ]]; then
    install -D -m "$mode" "$CHROMIUM_BROWSER_OUT/$source_name" \
      "$destination_root/$destination_name"
  fi
}

validate_browser_generation() (
  local generation="$1"
  local runtime="$generation/runtime"
  for required in \
    nucleus-browser-bin \
    chrome_crashpad_handler \
    chrome_sandbox \
    icudtl.dat \
    resources.pak \
    chrome_100_percent.pak \
    chrome_200_percent.pak \
    locales \
    libEGL.so \
    libGLESv2.so \
    libvulkan.so.1; do
    [[ -e "$runtime/$required" ]] || {
      echo "browser generation is missing: $runtime/$required" >&2
      return 1
    }
  done
  [[ -f "$generation/share/icons/hicolor/128x128/apps/dev.nucleus.Browser.png" ]] || {
    echo "browser generation is missing its required 128x128 icon" >&2
    return 1
  }
  [[ -f "$generation/nucleus-build-manifest.json" ]] || {
    echo "browser generation build manifest is missing" >&2
    return 1
  }
  if ldd "$runtime/nucleus-browser-bin" | grep -F 'not found'; then
    echo "browser generation has unresolved dynamic libraries" >&2
    return 1
  fi
  "$runtime/nucleus-browser-bin" --version

  local smoke
  smoke="$(mktemp -d)"
  trap 'rm -rf -- "$smoke"' EXIT
  mkdir -p "$smoke/home" "$smoke/config" "$smoke/cache"
  local output="$smoke/output.html"
  timeout 90 env \
    HOME="$smoke/home" \
    XDG_CONFIG_HOME="$smoke/config" \
    XDG_CACHE_HOME="$smoke/cache" \
    LD_LIBRARY_PATH="$runtime" \
    "$runtime/nucleus-browser-bin" \
      --headless=new \
      --no-sandbox \
      --disable-gpu \
      --no-first-run \
      --user-data-dir="$smoke/profile" \
      --dump-dom 'data:text/html,<title>nucleus-smoke</title><p>nucleus-smoke</p>' \
      > "$output"
  grep -F 'nucleus-smoke' "$output" >/dev/null
)

package_browser() {
  verify_source
  build_metadata verify-build "$built_manifest" >/dev/null
  local build_id
  build_id="$(python3 "$metadata" build-id --manifest "$built_manifest")"
  local generations="$NUCLEUS_BROWSER_DIST_ROOT/generations"
  mkdir -p "$generations"
  local prepared
  prepared="$(mktemp -d "$generations/.${build_id}.XXXXXX.prepared")"
  trap '[[ -z "${prepared:-}" || ! -d "$prepared" ]] || rm -rf -- "$prepared"' EXIT
  local runtime="$prepared/runtime"
  mkdir -p "$runtime"

  install_required "$runtime" chrome nucleus-browser-bin 0755
  install_required "$runtime" chrome_crashpad_handler chrome_crashpad_handler 0755
  install_required "$runtime" chrome_sandbox chrome_sandbox 0755
  install_required "$runtime" icudtl.dat
  install_required "$runtime" resources.pak
  install_required "$runtime" chrome_100_percent.pak
  install_required "$runtime" chrome_200_percent.pak
  if [[ -f "$CHROMIUM_BROWSER_OUT/v8_context_snapshot.bin" ]]; then
    install_required "$runtime" v8_context_snapshot.bin
  else
    install_required "$runtime" snapshot_blob.bin
  fi
  install_optional "$runtime" chrome_management_service chrome_management_service 0755
  install_required "$runtime" libEGL.so libEGL.so 0755
  install_required "$runtime" libGLESv2.so libGLESv2.so 0755
  install_required "$runtime" libvulkan.so.1 libvulkan.so.1 0755

  local directory
  for directory in locales default_apps MEIPreload PrivacySandboxAttestationsPreloaded; do
    if [[ -d "$CHROMIUM_BROWSER_OUT/$directory" ]]; then
      cp -a "$CHROMIUM_BROWSER_OUT/$directory" "$runtime/$directory"
    fi
  done
  install -D -m 0755 "$script_dir/launcher/nucleus-browser" \
    "$prepared/bin/nucleus-browser"
  install -D -m 0644 \
    "$script_dir/share/applications/dev.nucleus.Browser.desktop.in" \
    "$prepared/share/applications/dev.nucleus.Browser.desktop.in"
  local size icon
  for size in 16 22 24 32 48 64 128 256; do
    if icon="$(find_product_icon "$size")"; then
      install -D -m 0644 "$icon" \
        "$prepared/share/icons/hicolor/${size}x${size}/apps/dev.nucleus.Browser.png"
    fi
  done
  install -m 0644 "$built_manifest" "$prepared/nucleus-build-manifest.json"
  validate_browser_generation "$prepared"
  python3 "$atomic_publish" "$prepared" "$generations/$build_id"
  prepared=""
  local current_temporary="$NUCLEUS_BROWSER_DIST_ROOT/.current.$$.tmp"
  ln -s "generations/$build_id" "$current_temporary"
  mv -Tf "$current_temporary" "$NUCLEUS_BROWSER_DIST_ROOT/current"
  trap - EXIT
  echo "browser artifact generation: $NUCLEUS_BROWSER_DIST_ROOT/current"
}

validate_browser() {
  verify_source
  build_metadata verify-build "$built_manifest" >/dev/null
  local build_id
  build_id="$(python3 "$metadata" build-id --manifest "$built_manifest")"
  [[ "$(readlink "$NUCLEUS_BROWSER_DIST_ROOT/current")" == "generations/$build_id" ]] || {
    echo "published browser generation does not match built output $build_id" >&2
    exit 1
  }
  cmp -s "$built_manifest" "$NUCLEUS_BROWSER_DIST_ROOT/current/nucleus-build-manifest.json" || {
    echo "published browser manifest does not match built output $build_id" >&2
    exit 1
  }
  validate_browser_generation "$NUCLEUS_BROWSER_DIST_ROOT/current"
}

test_browser() {
  verify_source
  build_metadata verify-build "$built_manifest" >/dev/null
  autoninja -j "$NUCLEUS_CHROMIUM_JOBS" -C "$CHROMIUM_BROWSER_OUT" \
    ui/ozone:ozone_unittests \
    components/viz/service:output_presenter_ozone_unittests
  "$CHROMIUM_BROWSER_OUT/ozone_unittests" \
    --gtest_filter='*OzonePresenter*' --single-process-tests
  "$CHROMIUM_BROWSER_OUT/output_presenter_ozone_unittests" \
    --gtest_filter='OutputPresenterOzoneTest.*' --single-process-tests
  validate_browser
}

case "$operation" in
  build) build_browser ;;
  package) package_browser ;;
  validate) validate_browser ;;
  test) test_browser ;;
esac
