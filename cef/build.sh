#!/usr/bin/env bash
# Build the Chromium Embedded Framework (CEF) from source WITH proprietary
# codecs (H.264/AAC), which official CEF distributions omit for patent-licensing
# reasons. Produces a self-consistent minimal binary distribution (libcef.so +
# libcef_dll wrapper source + resources) plus a checksummed tarball under
# ~/.cache/nucleus/cef, consumed by the desktop shell's embedded browser.
#
# This is a long-running, explicit native build in the same class as
# swift-toolchain/build.sh and swift-android-sdk/build.sh — it is NOT part of an
# ordinary `tools/nucleus build all`. See README.md.

set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/scripts/cef-env.sh"
source "$script_dir/../chromium/scripts/patch-stack.sh"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
force_clean=0
package_only=0
skip_deps=0
run_install_build_deps=0
no_update=0
prepare_only=0

usage() {
  cat <<EOF
Usage: cef/build.sh [options]

Builds CEF branch ${NUCLEUS_CEF_BRANCH} (Chromium ${NUCLEUS_CEF_CHROMIUM_VERSION})
with proprietary codecs, then packages a minimal distribution + sha256 into
${NUCLEUS_CEF_DIST_ROOT}.

Options:
  --force-clean          Wipe and re-sync the Chromium checkout before building.
  --package-only         Skip build; just (re)package the last build's distrib.
  --no-update            Reuse the current checkout, apply project patches,
                         then rebuild and package it.
  --prepare-only         Sync and apply CEF patches without building or packaging.
  --skip-deps            Do not clone/update depot_tools (assume present).
  --install-build-deps   Run Chromium's install-build-deps.sh (needs sudo) after
                         the first sync. Do this once on a fresh host.
  -h, --help             Show this help.

Key environment overrides (see scripts/cef-env.sh):
  NUCLEUS_CEF_BRANCH           CEF/Chromium branch          (${NUCLEUS_CEF_BRANCH})
  NUCLEUS_CEF_CHECKOUT         exact CEF version to pin     (${NUCLEUS_CEF_CHECKOUT:-<branch head>})
  NUCLEUS_CEF_GN_EXTRA         extra GN args appended
  NUCLEUS_CEF_JOBS             parallel jobs                (${NUCLEUS_CEF_JOBS})
  NUCLEUS_CEF_CACHE_ROOT       output root                  (${NUCLEUS_CEF_CACHE_ROOT})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-clean) force_clean=1 ;;
    --package-only) package_only=1 ;;
    --no-update) no_update=1 ;;
    --prepare-only) prepare_only=1 ;;
    --skip-deps) skip_deps=1 ;;
    --install-build-deps) run_install_build_deps=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
nucleus_cef_require_tool git git
nucleus_cef_require_tool python3 python3
nucleus_cef_require_tool curl curl
nucleus_cef_require_tool tar tar
nucleus_cef_require_tool sha256sum coreutils
nucleus_cef_require_tool ccache ccache

mkdir -p "$NUCLEUS_CEF_CACHE_ROOT" "$NUCLEUS_CEF_SRC_ROOT" "$NUCLEUS_CEF_DIST_ROOT" "$NUCLEUS_CEF_LOG_DIR"

log_file="$NUCLEUS_CEF_LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
ln -sf "$(basename "$log_file")" "$NUCLEUS_CEF_LOG_DIR/latest.log"
# Mirror all output to the log while keeping it on the console.
exec > >(tee -a "$log_file") 2>&1

echo "== nucleus CEF build =="
echo "branch:        $NUCLEUS_CEF_BRANCH"
echo "chromium:      $NUCLEUS_CEF_CHROMIUM_VERSION"
echo "checkout pin:  ${NUCLEUS_CEF_CHECKOUT:-<branch head>}"
echo "jobs:          $NUCLEUS_CEF_JOBS"
echo "src root:      $NUCLEUS_CEF_SRC_ROOT"
echo "dist root:     $NUCLEUS_CEF_DIST_ROOT"
echo "ccache dir:    $CCACHE_DIR"
echo "log:           $log_file"

# ---------------------------------------------------------------------------
# depot_tools
# ---------------------------------------------------------------------------
if [[ $skip_deps -eq 0 ]]; then
  if [[ ! -d "$NUCLEUS_CEF_DEPOT_TOOLS/.git" ]]; then
    echo "-- cloning depot_tools"
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git \
      "$NUCLEUS_CEF_DEPOT_TOOLS"
  fi
fi

# A fresh depot_tools checkout does not contain its pinned Python/CIPD tools.
# Bootstrap it once before disabling self-updates; otherwise wrappers such as
# `gn` fail because python3_bin_reldir.txt has not been generated.
if [[ ! -f "$NUCLEUS_CEF_DEPOT_TOOLS/python3_bin_reldir.txt" ]]; then
  echo "-- bootstrapping depot_tools"
  "$NUCLEUS_CEF_DEPOT_TOOLS/ensure_bootstrap"
fi

export PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH"
# We manage depot_tools ourselves; disable its self-update mid-build.
export DEPOT_TOOLS_UPDATE=0

# ---------------------------------------------------------------------------
# automate-git.py (fetched fresh from the pinned branch)
# ---------------------------------------------------------------------------
automate="$NUCLEUS_CEF_SRC_ROOT/automate-git.py"
if [[ $package_only -eq 0 ]]; then
  echo "-- fetching automate-git.py for branch $NUCLEUS_CEF_BRANCH"
  curl -fsSL "$(nucleus_cef_automate_url)" -o "$automate"
fi

# ---------------------------------------------------------------------------
# One-time Chromium host build deps (large; needs sudo).
# ---------------------------------------------------------------------------
if [[ $run_install_build_deps -eq 1 ]]; then
  ibd="$NUCLEUS_CEF_SRC_ROOT/chromium/src/build/install-build-deps.sh"
  if [[ -x "$ibd" ]]; then
    echo "-- running Chromium install-build-deps.sh"
    sudo "$ibd" --no-prompt --no-arm --no-chromeos-fonts
  else
    echo "!! install-build-deps.sh not found yet ($ibd)."
    echo "   Run one sync first (drop --install-build-deps), then re-run with it."
  fi
fi

# ---------------------------------------------------------------------------
# Build via automate-git.py
# ---------------------------------------------------------------------------
export CEF_USE_GN=1
export GN_DEFINES="$NUCLEUS_CEF_GN_DEFINES_BASE ${NUCLEUS_CEF_GN_EXTRA}"
echo "-- GN_DEFINES: $GN_DEFINES"

pgo_profile_name=""
pgo_profile_path=""

ensure_linux_pgo_profile() {
  local chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  local descriptor="$chromium_root/chrome/build/linux.pgo.txt"
  if [[ ! -f "$descriptor" ]]; then
    echo "!! Chromium Linux PGO descriptor is missing: $descriptor" >&2
    exit 1
  fi

  pgo_profile_name="$(tr -d '\r\n' < "$descriptor")"
  if [[ -z "$pgo_profile_name" || "$pgo_profile_name" == */* ]]; then
    echo "!! Chromium Linux PGO descriptor is invalid: $pgo_profile_name" >&2
    exit 1
  fi
  pgo_profile_path="$chromium_root/chrome/build/pgo_profiles/$pgo_profile_name"
  if [[ ! -f "$pgo_profile_path" ]]; then
    echo "-- fetching branch-matched Chromium Linux PGO profile: $pgo_profile_name"
    (
      cd "$chromium_root"
      python3 tools/update_pgo_profiles.py \
        --target=linux update \
        --gs-url-base=chromium-optimization-profiles/pgo_profiles
    )
  fi
  if [[ ! -s "$pgo_profile_path" ]]; then
    echo "!! Chromium Linux PGO profile was not provisioned: $pgo_profile_path" >&2
    exit 1
  fi
  echo "-- PGO profile ready: $pgo_profile_name"
}

ensure_v8_builtins_pgo_profiles() {
  local chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  local profile="$chromium_root/v8/tools/builtins-pgo/profiles/x64.profile"
  if [[ ! -s "$profile" ]]; then
    echo "-- fetching branch-matched V8 builtins PGO profiles"
    (
      cd "$chromium_root"
      PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH" \
        python3 v8/tools/builtins-pgo/download_profiles.py \
          download \
          --depot-tools third_party/depot_tools \
          --check-v8-revision
    )
  fi
  if [[ ! -s "$profile" ]]; then
    echo "!! V8 x64 builtins PGO profile was not provisioned: $profile" >&2
    exit 1
  fi
  echo "-- V8 builtins PGO profile ready"
}

reverse_nucleus_cef_patches() {
  local chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"

  # A browser preparation adds one product layer to this shared source tree.
  # Remove it first so CEF refreshes against its unchanged source contract.
  nucleus_reverse_patch_stack \
    "$chromium_root" \
    "$script_dir/../chromium/patches/browser" \
    "$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-browser-patches" \
    "Nucleus Browser"

  # Remove project changes before CEF updates its own Chromium patch stack.
  # Several Chromium files intentionally overlap CEF's patches.
  nucleus_reverse_patch_stack \
    "$chromium_root" \
    "$script_dir/patches" \
    "$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-patches" \
    "Chromium/CEF"
  nucleus_reverse_patch_stack \
    "$chromium_root" \
    "$script_dir/../chromium/patches/common" \
    "$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-common-patches" \
    "Chromium common"
  nucleus_reverse_patch_stack \
    "$chromium_root/third_party/dawn" \
    "$script_dir/../chromium/patches/dawn" \
    "$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-dawn-patches" \
    "Dawn"
}

apply_nucleus_cef_patches() {
  local chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  local applied_patch_dir="$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-patches"
  local generated_api_patch="9999-generated-cef-api-hashes.patch"

  nucleus_apply_patch_stack \
    "$chromium_root" \
    "$script_dir/../chromium/patches/common" \
    "$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-common-patches" \
    "Chromium common"
  nucleus_apply_patch_stack \
    "$chromium_root" \
    "$script_dir/patches" \
    "$applied_patch_dir" \
    "Chromium/CEF"
  nucleus_apply_patch_stack \
    "$chromium_root/third_party/dawn" \
    "$script_dir/../chromium/patches/dawn" \
    "$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-dawn-patches" \
    "Dawn"

  # Public API patches must reach both sides of CEF's generated C/C++ bridge
  # before libcef is compiled. Packaging also runs the translator, but that is
  # too late: the shared library and the distributed wrapper would otherwise
  # be built from different virtual-method contracts on a clean checkout.
  echo "-- regenerating CEF C/C++ API translation"
  (
    cd "$chromium_root"
    python3 cef/tools/translator.py --root-dir cef
  )

  # API hashes cover the complete public-header surface and are branch-local
  # generated output. Always derive them from the synced CEF checkout after the
  # source patches have landed; never carry hashes forward from another branch.
  echo "-- regenerating CEF API hashes for branch $NUCLEUS_CEF_BRANCH"
  (
    cd "$chromium_root/cef"
    python3 tools/version_manager.py -c --force-update
  )

  git -C "$chromium_root/cef" diff \
    --src-prefix=a/cef/ --dst-prefix=b/cef/ -- cef_api_versions.json \
    >"$applied_patch_dir/$generated_api_patch"
  if [[ ! -s "$applied_patch_dir/$generated_api_patch" ]]; then
    echo "!! CEF API hash regeneration produced no patch" >&2
    exit 1
  fi
}

if [[ $package_only -eq 0 ]]; then
  automate_common=(
    "--download-dir=$NUCLEUS_CEF_SRC_ROOT"
    "--depot-tools-dir=$NUCLEUS_CEF_DEPOT_TOOLS"
    "--branch=$NUCLEUS_CEF_BRANCH"
    --x64-build
    --no-debug-build          # Release only — halves build time + disk
    --no-chromium-history     # shallow Chromium checkout — big disk saving
    --with-pgo-profiles       # exact branch-matched production profile
    --build-target=cefsimple  # pulls in libcef + wrapper without cefclient's extra deps
  )

  reverse_nucleus_cef_patches

  if [[ $no_update -eq 0 ]]; then
    # Force regenerate .gclient so an existing non-PGO checkout adopts
    # checkout_pgo_profiles=true through automate-git instead of a manual edit
    # to generated configuration.
    sync_args=("${automate_common[@]}" --force-config --no-build --no-distrib)
    if [[ -n "$NUCLEUS_CEF_CHECKOUT" ]]; then
      sync_args+=("--checkout=$NUCLEUS_CEF_CHECKOUT")
    fi
    if [[ $force_clean -eq 1 ]]; then
      sync_args+=(--force-clean)
    fi
    echo "-- automate-git.py ${sync_args[*]}"
    python3 "$automate" "${sync_args[@]}"
  fi

  ensure_linux_pgo_profile
  ensure_v8_builtins_pgo_profiles

  # Run CEF's own patch/configuration hook while the Chromium tree contains
  # only upstream changes. Our patches deliberately overlap a few of CEF's
  # patches, so automate-git.py cannot safely run this hook after they land.
  chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  echo "-- generating upstream CEF build configuration"
  (
    cd "$chromium_root/cef"
    python3 tools/gclient_hook.py
  )

  apply_nucleus_cef_patches

  if [[ $prepare_only -eq 1 ]]; then
    echo
    echo "== CEF source prepared =="
    echo "source: $chromium_root"
    exit 0
  fi

  # Regenerate Ninja after applying our BUILD.gn changes, then build directly.
  # A second automate-git.py build pass would rerun CEF's patch hook over our
  # modified sources and report the intentional overlap as an upstream failure.
  release_out="$chromium_root/out/Release_GN_x64"
  echo "-- regenerating project files after project patches"
  (
    cd "$chromium_root"
    "$chromium_root/buildtools/linux64/gn" gen "$release_out"
  )
  echo "-- building CEF release targets"
  PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH" \
    autoninja -j "$NUCLEUS_CEF_JOBS" -C "$release_out" cefsimple chrome_sandbox

  distrib_args=(
    "${automate_common[@]}"
    --no-update
    --no-build
    --force-distrib
    --minimal-distrib-only
  )
  echo "-- automate-git.py ${distrib_args[*]}"
  python3 "$automate" "${distrib_args[@]}"
fi

# ---------------------------------------------------------------------------
# Package: locate the produced minimal distrib, stage it, checksum it.
# ---------------------------------------------------------------------------
distrib_src="$NUCLEUS_CEF_SRC_ROOT/chromium/src/cef/binary_distrib"
produced="$(find "$distrib_src" -maxdepth 1 -type d -name 'cef_binary_*_linux64_minimal' 2>/dev/null | sort | tail -1)"
if [[ -z "$produced" ]]; then
  echo "!! no minimal distribution found under $distrib_src" >&2
  exit 1
fi

version="$(basename "$produced" | sed -E 's/^cef_binary_(.+)_linux64_minimal$/\1/')"
staged="$NUCLEUS_CEF_DIST_ROOT/$version"
prepared="$NUCLEUS_CEF_DIST_ROOT/.${version}.$$.prepared"
current_link_tmp="$NUCLEUS_CEF_DIST_ROOT/.current.$$.tmp"
trap '[[ -z "${prepared:-}" ]] || rm -rf "$prepared"; [[ -z "${current_link_tmp:-}" ]] || rm -f "$current_link_tmp"' EXIT
echo "-- preparing $produced -> $prepared"
rm -rf "$prepared"
mkdir -p "$prepared"
cp -a "$produced/." "$prepared/"

# Keep Chromium's Vulkan loader: ANGLE is built and tested against this copy,
# and Noctalia safely shares it through the process-wide Vulkan SONAME. Remove
# only the SwiftShader implementation and ICD so software rendering cannot be
# selected as a fallback.
rm -f \
  "$prepared/Release/libvk_swiftshader.so" \
  "$prepared/Release/vk_swiftshader_icd.json"

# Colocate the split Resources/ payload next to libcef.so in Release/ — ICU
# (icudtl.dat) initializes before resource_dir settings apply, so it must sit
# beside the library. The consuming shell points its resource paths at Release/.
if [[ -d "$prepared/Resources" ]]; then
  for f in "$prepared"/Resources/*; do
    ln -sfn "../Resources/$(basename "$f")" "$prepared/Release/$(basename "$f")"
  done
fi

echo "-- atomically publishing $prepared -> $staged"
python3 "$script_dir/scripts/atomic-publish-directory.py" "$prepared" "$staged"

tarball="$NUCLEUS_CEF_DIST_ROOT/cef-${version}-linux64-codecs.tar.gz"
echo "-- packaging $tarball"
tar -C "$NUCLEUS_CEF_DIST_ROOT" -czf "$tarball" "$version"
( cd "$NUCLEUS_CEF_DIST_ROOT" && sha256sum "$(basename "$tarball")" > "$tarball.sha256" )

# Publish one stable consumer path without duplicating build metadata. The
# temporary relative symlink and rename make switching versions atomic.
ln -s "$version" "$current_link_tmp"
mv -Tf "$current_link_tmp" "$NUCLEUS_CEF_DIST_ROOT/current"

echo
echo "== CEF build complete =="
echo "version:  $version"
echo "dist:     $staged"
echo "tarball:  $tarball"
echo "sha256:   $(cat "$tarball.sha256")"
echo
echo "Verify codecs by loading the dist in Noctalia and checking"
echo "canPlayType('audio/mp4; codecs=\"mp4a.40.2\"') is non-empty."
