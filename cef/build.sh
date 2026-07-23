#!/usr/bin/env bash
# Internal CEF product stages. Use `tools/nucleus chromium ...`; the workspace
# Chromium orchestrator owns source/output/publication locks and run logging.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workspace_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/scripts/cef-env.sh"
source "$workspace_root/chromium/scripts/patch-stack.sh"

if [[ "${NUCLEUS_CHROMIUM_ORCHESTRATED:-0}" != 1 ]]; then
  echo "cef/build.sh is an internal product stage; use tools/nucleus chromium" >&2
  exit 2
fi

operation="${1:-}"
if [[ $# -ne 1 || ! "$operation" =~ ^(bootstrap|prepare|build|package|validate)$ ]]; then
  echo "internal usage: cef/build.sh bootstrap|prepare|build|package|validate" >&2
  exit 2
fi

metadata="$workspace_root/chromium/scripts/build-metadata.py"
atomic_publish="$script_dir/scripts/atomic-publish-directory.py"
source_manifest="$NUCLEUS_CEF_SRC_ROOT/nucleus-source-manifest.json"

source_metadata_arguments() {
  printf '%s\n' \
    --workspace "$workspace_root" \
    --cef-branch "$NUCLEUS_CEF_BRANCH" \
    --cef-checkout "$NUCLEUS_CEF_CHECKOUT" \
    --chromium-version "$NUCLEUS_CEF_CHROMIUM_VERSION" \
    --chromium-checkout "$NUCLEUS_CHROMIUM_CHECKOUT" \
    --depot-tools-revision "$NUCLEUS_DEPOT_TOOLS_REVISION" \
    --source-root "$NUCLEUS_CEF_SRC_ROOT" \
    --depot-tools "$NUCLEUS_CEF_DEPOT_TOOLS" \
    --manifest "$source_manifest"
}

verify_source() {
  local arguments=()
  mapfile -t arguments < <(source_metadata_arguments)
  python3 "$metadata" verify-source "${arguments[@]}" >/dev/null
}

pin_depot_tools() {
  if [[ ! -d "$NUCLEUS_CEF_DEPOT_TOOLS/.git" ]]; then
    if [[ -e "$NUCLEUS_CEF_DEPOT_TOOLS" ]]; then
      echo "depot_tools path exists but is not a Git checkout: $NUCLEUS_CEF_DEPOT_TOOLS" >&2
      exit 1
    fi
    mkdir -p "$(dirname -- "$NUCLEUS_CEF_DEPOT_TOOLS")"
    (
      local preparing
      preparing="$(mktemp -d "$(dirname -- "$NUCLEUS_CEF_DEPOT_TOOLS")/.depot-tools.XXXXXX.preparing")"
      trap 'rm -rf -- "$preparing"' EXIT
      rmdir -- "$preparing"
      echo "-- cloning pinned depot_tools $NUCLEUS_DEPOT_TOOLS_REVISION"
      git clone --filter=blob:none --no-checkout \
        https://chromium.googlesource.com/chromium/tools/depot_tools.git \
        "$preparing"
      git -C "$preparing" fetch --depth 1 origin "$NUCLEUS_DEPOT_TOOLS_REVISION"
      git -C "$preparing" checkout --detach "$NUCLEUS_DEPOT_TOOLS_REVISION"
      mv -- "$preparing" "$NUCLEUS_CEF_DEPOT_TOOLS"
      trap - EXIT
    )
  fi
  if ! git -C "$NUCLEUS_CEF_DEPOT_TOOLS" diff --quiet -- ||
     ! git -C "$NUCLEUS_CEF_DEPOT_TOOLS" diff --cached --quiet --; then
    echo "depot_tools contains tracked local changes: $NUCLEUS_CEF_DEPOT_TOOLS" >&2
    exit 1
  fi
  if [[ "$(git -C "$NUCLEUS_CEF_DEPOT_TOOLS" rev-parse HEAD 2>/dev/null || true)" != "$NUCLEUS_DEPOT_TOOLS_REVISION" ]]; then
    echo "-- fetching pinned depot_tools $NUCLEUS_DEPOT_TOOLS_REVISION"
    git -C "$NUCLEUS_CEF_DEPOT_TOOLS" fetch --depth 1 origin "$NUCLEUS_DEPOT_TOOLS_REVISION"
    git -C "$NUCLEUS_CEF_DEPOT_TOOLS" checkout --detach "$NUCLEUS_DEPOT_TOOLS_REVISION"
  fi
  if [[ ! -f "$NUCLEUS_CEF_DEPOT_TOOLS/python3_bin_reldir.txt" ]]; then
    echo "-- bootstrapping depot_tools"
    "$NUCLEUS_CEF_DEPOT_TOOLS/ensure_bootstrap"
  fi
}

install_bootstrap_dependencies() {
  local packages=()
  mapfile -t packages < <(
    sed -E '/^[[:space:]]*(#|$)/d; s/[[:space:]]+#.*$//' "$script_dir/apt-deps.txt"
  )
  if [[ ${#packages[@]} -eq 0 ]]; then
    echo "bootstrap package list is empty: $script_dir/apt-deps.txt" >&2
    exit 1
  fi
  echo "-- installing Chromium bootstrap host packages"
  sudo apt-get install -y "${packages[@]}"
}

export PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH"
export DEPOT_TOOLS_UPDATE=0
export CEF_USE_GN=1
export GN_DEFINES="$NUCLEUS_CEF_GN_DEFINES_BASE"

ensure_linux_pgo_profile() {
  local chromium_root="$1/chromium/src"
  local descriptor="$chromium_root/chrome/build/linux.pgo.txt"
  if [[ ! -f "$descriptor" ]]; then
    echo "Chromium Linux PGO descriptor is missing: $descriptor" >&2
    exit 1
  fi
  local profile_name profile_path
  profile_name="$(tr -d '\r\n' < "$descriptor")"
  if [[ -z "$profile_name" || "$profile_name" == */* ]]; then
    echo "Chromium Linux PGO descriptor is invalid: $profile_name" >&2
    exit 1
  fi
  profile_path="$chromium_root/chrome/build/pgo_profiles/$profile_name"
  if [[ ! -s "$profile_path" ]]; then
    echo "-- fetching branch-matched Chromium Linux PGO profile"
    (
      cd "$chromium_root"
      python3 tools/update_pgo_profiles.py \
        --target=linux update \
        --gs-url-base=chromium-optimization-profiles/pgo_profiles
    )
  fi
  [[ -s "$profile_path" ]] || {
    echo "Chromium Linux PGO profile was not provisioned: $profile_path" >&2
    exit 1
  }
}

ensure_v8_builtins_pgo_profile() {
  local chromium_root="$1/chromium/src"
  local profile="$chromium_root/v8/tools/builtins-pgo/profiles/x64.profile"
  if [[ ! -s "$profile" ]]; then
    echo "-- fetching branch-matched V8 builtins PGO profiles"
    (
      cd "$chromium_root"
      python3 v8/tools/builtins-pgo/download_profiles.py \
        download --depot-tools third_party/depot_tools --check-v8-revision
    )
  fi
  [[ -s "$profile" ]] || {
    echo "V8 builtins PGO profile was not provisioned: $profile" >&2
    exit 1
  }
}

apply_project_patches() {
  local generation="$1"
  local chromium_root="$generation/chromium/src"
  nucleus_apply_patch_stack \
    "$chromium_root" "$workspace_root/chromium/patches/common" "Chromium common"
  nucleus_apply_patch_stack \
    "$chromium_root" "$script_dir/patches" "Chromium/CEF"
  nucleus_apply_patch_stack \
    "$chromium_root" "$workspace_root/chromium/patches/browser" "Chromium browser"
  nucleus_apply_patch_stack \
    "$chromium_root/third_party/dawn" "$workspace_root/chromium/patches/dawn" "Dawn"

  echo "-- regenerating CEF C/C++ translation and API hashes"
  (
    cd "$chromium_root"
    python3 cef/tools/translator.py --root-dir cef
  )
  (
    cd "$chromium_root/cef"
    python3 tools/version_manager.py -c --force-update
    python3 tools/version_manager.py -c
  )
  git -C "$chromium_root" diff --check
  git -C "$chromium_root/cef" diff --check
  git -C "$chromium_root/third_party/dawn" diff --check
}

publish_source_current() {
  local temporary="$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS/.current.$$.tmp"
  ln -s "$NUCLEUS_CHROMIUM_SOURCE_ID" "$temporary"
  mv -Tf "$temporary" "$NUCLEUS_CHROMIUM_SOURCE_CURRENT"
}

prepare_source() {
  local install_dependencies="${1:-0}"
  pin_depot_tools
  mkdir -p "$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS"
  if [[ -f "$source_manifest" ]]; then
    echo "-- verifying prepared source generation $NUCLEUS_CHROMIUM_SOURCE_ID"
    verify_source
    publish_source_current
    if [[ "$install_dependencies" == 1 ]]; then
      sudo "$NUCLEUS_CHROMIUM_SRC_ROOT/build/install-build-deps.sh" \
        --no-prompt --no-arm --no-chromeos-fonts
    fi
    return
  fi
  if [[ -e "$NUCLEUS_CEF_SRC_ROOT" ]]; then
    echo "source generation exists without valid metadata: $NUCLEUS_CEF_SRC_ROOT" >&2
    exit 1
  fi

  local preparing
  preparing="$(mktemp -d "$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS/.${NUCLEUS_CHROMIUM_SOURCE_ID}.XXXXXX.preparing")"
  cleanup_preparing() {
    if [[ -n "${preparing:-}" && -d "$preparing" ]]; then
      rm -rf -- "$preparing"
    fi
  }
  trap cleanup_preparing EXIT

  local automate="$preparing/automate-git.py"
  echo "-- fetching automate-git.py from exact CEF commit $NUCLEUS_CEF_CHECKOUT"
  curl -fsSL "$(nucleus_cef_automate_url)" -o "$automate"
  local automate_arguments=(
    "--download-dir=$preparing"
    "--depot-tools-dir=$NUCLEUS_CEF_DEPOT_TOOLS"
    "--branch=$NUCLEUS_CEF_BRANCH"
    "--checkout=$NUCLEUS_CEF_CHECKOUT"
    --x64-build
    --no-debug-build
    --no-chromium-history
    --with-pgo-profiles
    --build-target=cefsimple
    --force-config
    --no-build
    --no-distrib
  )
  echo "-- preparing pristine pinned Chromium/CEF checkout"
  python3 "$automate" "${automate_arguments[@]}"
  if [[ "$install_dependencies" == 1 ]]; then
    sudo "$preparing/chromium/src/build/install-build-deps.sh" \
      --no-prompt --no-arm --no-chromeos-fonts
  fi
  ensure_linux_pgo_profile "$preparing"
  ensure_v8_builtins_pgo_profile "$preparing"

  echo "-- generating upstream CEF build configuration"
  (
    cd "$preparing/chromium/src/cef"
    python3 tools/gclient_hook.py
  )
  apply_project_patches "$preparing"

  # The final path does not exist yet; metadata is path-independent.
  local arguments=()
  local original_source_root="$NUCLEUS_CEF_SRC_ROOT"
  NUCLEUS_CEF_SRC_ROOT="$preparing"
  source_manifest="$preparing/nucleus-source-manifest.json"
  mapfile -t arguments < <(source_metadata_arguments)
  python3 "$metadata" write-source "${arguments[@]}" >/dev/null
  NUCLEUS_CEF_SRC_ROOT="$original_source_root"
  source_manifest="$NUCLEUS_CEF_SRC_ROOT/nucleus-source-manifest.json"

  mv -- "$preparing" "$NUCLEUS_CEF_SRC_ROOT"
  preparing=""
  trap - EXIT
  verify_source
  publish_source_current
  echo "prepared source generation: $NUCLEUS_CEF_SRC_ROOT"
}

build_manifest_arguments() {
  local mode="$1"
  local manifest="$2"
  local release_out="$NUCLEUS_CHROMIUM_SRC_ROOT/out/Release_GN_x64"
  python3 "$metadata" "$mode" \
    --product cef \
    --source-root "$NUCLEUS_CEF_SRC_ROOT" \
    --source-manifest "$source_manifest" \
    --gn-args "$release_out/args.gn" \
    --manifest "$manifest"
}

build_cef() {
  verify_source
  local release_out="$NUCLEUS_CHROMIUM_SRC_ROOT/out/Release_GN_x64"
  echo "-- regenerating CEF GN output"
  (
    cd "$NUCLEUS_CHROMIUM_SRC_ROOT"
    "$NUCLEUS_CHROMIUM_SRC_ROOT/buildtools/linux64/gn" gen "$release_out"
  )
  local expected="$release_out/.nucleus-expected-build.json"
  build_manifest_arguments write-build "$expected" >/dev/null
  echo "-- building CEF release targets with $NUCLEUS_CHROMIUM_JOBS local Siso jobs"
  autoninja -j "$NUCLEUS_CHROMIUM_JOBS" -C "$release_out" cefsimple chrome_sandbox
  local built_temporary="$release_out/.nucleus-built-build.$$.tmp"
  install -m 0644 "$expected" "$built_temporary"
  mv -f "$built_temporary" "$release_out/.nucleus-built-build.json"
  build_manifest_arguments verify-build "$release_out/.nucleus-built-build.json" >/dev/null
}

validate_cef_sdk() (
  local sdk="$1"
  for required in \
    Release/libcef.so \
    Release/chrome-sandbox \
    Release/icudtl.dat \
    Resources \
    include/cef_version_info.h \
    nucleus-build-manifest.json; do
    [[ -e "$sdk/$required" ]] || {
      echo "CEF SDK artifact is missing: $sdk/$required" >&2
      return 1
    }
  done
  if ldd "$sdk/Release/libcef.so" | grep -F 'not found'; then
    echo "CEF SDK has unresolved dynamic libraries" >&2
    return 1
  fi
  local smoke
  smoke="$(mktemp -d)"
  trap 'rm -rf -- "$smoke"' EXIT
  printf '%s\n' \
    '#include "include/cef_version_info.h"' \
    'int main(void) { return cef_version_info(0) > 0 ? 0 : 1; }' \
    > "$smoke/consumer.c"
  cc -I "$sdk" "$smoke/consumer.c" \
    -L "$sdk/Release" -Wl,-rpath,"$sdk/Release" -lcef \
    -o "$smoke/consumer"
  "$smoke/consumer"
)

package_cef() {
  verify_source
  local release_out="$NUCLEUS_CHROMIUM_SRC_ROOT/out/Release_GN_x64"
  local built_manifest="$release_out/.nucleus-built-build.json"
  build_manifest_arguments verify-build "$built_manifest" >/dev/null
  local build_id
  build_id="$(python3 "$metadata" build-id --manifest "$built_manifest")"

  local automate="$NUCLEUS_CEF_SRC_ROOT/automate-git.py"
  local distribute_arguments=(
    "--download-dir=$NUCLEUS_CEF_SRC_ROOT"
    "--depot-tools-dir=$NUCLEUS_CEF_DEPOT_TOOLS"
    "--branch=$NUCLEUS_CEF_BRANCH"
    "--checkout=$NUCLEUS_CEF_CHECKOUT"
    --x64-build
    --no-debug-build
    --no-chromium-history
    --with-pgo-profiles
    --build-target=cefsimple
    --no-update
    --no-build
    --force-distrib
    --minimal-distrib-only
  )
  echo "-- generating exact CEF minimal distribution"
  python3 "$automate" "${distribute_arguments[@]}"

  local distribution_root="$NUCLEUS_CHROMIUM_SRC_ROOT/cef/binary_distrib"
  local checkout_short="${NUCLEUS_CEF_CHECKOUT:0:7}"
  local produced_matches=()
  shopt -s nullglob
  produced_matches=("$distribution_root"/cef_binary_*+g"$checkout_short"+chromium-"$NUCLEUS_CEF_CHROMIUM_VERSION"_linux64_minimal)
  shopt -u nullglob
  if [[ ${#produced_matches[@]} -ne 1 ]]; then
    echo "expected exactly one current CEF distribution, found ${#produced_matches[@]}" >&2
    exit 1
  fi
  local produced="${produced_matches[0]}"

  local releases="$NUCLEUS_CEF_DIST_ROOT/releases"
  mkdir -p "$releases"
  local prepared_release
  prepared_release="$(mktemp -d "$releases/.${build_id}.XXXXXX.prepared")"
  local prepared_sdk="$prepared_release/sdk"
  local prepared_artifacts="$prepared_release/artifacts"
  mkdir -p "$prepared_sdk" "$prepared_artifacts"
  cleanup_package() {
    [[ -z "${prepared_release:-}" || ! -d "$prepared_release" ]] || rm -rf -- "$prepared_release"
  }
  trap cleanup_package EXIT
  cp -a "$produced/." "$prepared_sdk/"
  install -m 0644 "$built_manifest" "$prepared_sdk/nucleus-build-manifest.json"
  rm -f \
    "$prepared_sdk/Release/libvk_swiftshader.so" \
    "$prepared_sdk/Release/vk_swiftshader_icd.json"
  if [[ -d "$prepared_sdk/Resources" ]]; then
    local resource
    for resource in "$prepared_sdk"/Resources/*; do
      ln -sfn "../Resources/$(basename "$resource")" \
        "$prepared_sdk/Release/$(basename "$resource")"
    done
  fi
  validate_cef_sdk "$prepared_sdk"

  local version tarball checksum
  version="$(basename "$produced" | sed -E 's/^cef_binary_(.+)_linux64_minimal$/\1/')"
  tarball="cef-${version}-linux64-codecs.tar.gz"
  tar -C "$prepared_release" -czf "$prepared_artifacts/$tarball" \
    --transform="s,^sdk,$build_id," sdk
  checksum="$(sha256sum "$prepared_artifacts/$tarball" | cut -d' ' -f1)"
  printf '%s  %s\n' "$checksum" "$tarball" > "$prepared_artifacts/$tarball.sha256"
  (cd "$prepared_artifacts" && sha256sum -c "$tarball.sha256")
  install -m 0644 "$built_manifest" "$prepared_artifacts/nucleus-build-manifest.json"

  python3 "$atomic_publish" "$prepared_release" "$releases/$build_id"
  prepared_release=""
  local release_temporary="$NUCLEUS_CEF_DIST_ROOT/.current-release.$$.tmp"
  local current_temporary="$NUCLEUS_CEF_DIST_ROOT/.current.$$.tmp"
  local artifacts_temporary="$NUCLEUS_CEF_DIST_ROOT/.artifacts-current.$$.tmp"
  ln -s "releases/$build_id" "$release_temporary"
  mv -Tf "$release_temporary" "$NUCLEUS_CEF_DIST_ROOT/current-release"
  ln -s "current-release/sdk" "$current_temporary"
  ln -s "current-release/artifacts" "$artifacts_temporary"
  mv -Tf "$current_temporary" "$NUCLEUS_CEF_DIST_ROOT/current"
  mv -Tf "$artifacts_temporary" "$NUCLEUS_CEF_DIST_ROOT/artifacts-current"
  trap - EXIT
  echo "CEF SDK generation: $NUCLEUS_CEF_DIST_ROOT/current"
  echo "CEF artifact generation: $NUCLEUS_CEF_DIST_ROOT/artifacts-current"
}

validate_cef() {
  verify_source
  local release_out="$NUCLEUS_CHROMIUM_SRC_ROOT/out/Release_GN_x64"
  build_manifest_arguments verify-build "$release_out/.nucleus-built-build.json" >/dev/null
  local build_id
  build_id="$(python3 "$metadata" build-id --manifest "$release_out/.nucleus-built-build.json")"
  [[ "$(readlink "$NUCLEUS_CEF_DIST_ROOT/current-release")" == "releases/$build_id" ]] || {
    echo "published CEF SDK does not match built output $build_id" >&2
    exit 1
  }
  cmp -s "$release_out/.nucleus-built-build.json" \
    "$NUCLEUS_CEF_DIST_ROOT/current/nucleus-build-manifest.json" || {
    echo "published CEF SDK manifest does not match built output $build_id" >&2
    exit 1
  }
  cmp -s "$release_out/.nucleus-built-build.json" \
    "$NUCLEUS_CEF_DIST_ROOT/artifacts-current/nucleus-build-manifest.json" || {
    echo "published CEF artifact manifest does not match built output $build_id" >&2
    exit 1
  }
  validate_cef_sdk "$NUCLEUS_CEF_DIST_ROOT/current"
  (
    cd "$NUCLEUS_CHROMIUM_SRC_ROOT/cef"
    python3 tools/version_manager.py -c
  )
}

case "$operation" in
  prepare)
    prepare_source
    ;;
  bootstrap)
    install_bootstrap_dependencies
    prepare_source 1
    ;;
  build)
    build_cef
    ;;
  package)
    package_cef
    ;;
  validate)
    validate_cef
    ;;
esac
