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

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
force_clean=0
package_only=0
skip_deps=0
run_install_build_deps=0
no_update=0

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

reverse_nucleus_cef_patches() {
  local chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  local applied_patch_dir="$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-patches"
  local patch_file
  local patches=("$script_dir"/patches/*.patch)
  local applied_patches=("$applied_patch_dir"/*.patch)
  local patch_index
  if [[ ! -d "$chromium_root/.git" ]]; then
    return
  fi

  # Remove our previous stack before CEF updates its own Chromium patch stack.
  # Several files are intentionally touched by both, so updating upstream first
  # makes CEF mistake our still-applied changes for a failed upstream patch.
  # Keep a generated copy of the exact applied stack so renamed, merged, or
  # deleted project patches can still be reversed on the next run.
  if [[ ! -d "$applied_patch_dir" ]]; then
    applied_patches=("${patches[@]}")
  fi
  for ((patch_index=${#applied_patches[@]} - 1; patch_index >= 0; patch_index--)); do
    patch_file="${applied_patches[$patch_index]}"
    if [[ ! -f "$patch_file" ]]; then
      continue
    fi
    if git -C "$chromium_root" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
      echo "-- refreshing patch: $(basename "$patch_file")"
      git -C "$chromium_root" apply --reverse "$patch_file"
    fi
  done
}

apply_nucleus_cef_patches() {
  local chromium_root="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
  local applied_patch_dir="$NUCLEUS_CEF_SRC_ROOT/.nucleus-applied-patches"
  local generated_api_patch="9999-generated-cef-api-hashes.patch"
  local patch_file
  local patches=("$script_dir"/patches/*.patch)
  if [[ ! -d "$chromium_root/.git" ]]; then
    echo "!! Chromium checkout is missing: $chromium_root" >&2
    exit 1
  fi

  for patch_file in "${patches[@]}"; do
    if [[ ! -f "$patch_file" ]]; then
      continue
    fi
    if git -C "$chromium_root" apply --check "$patch_file"; then
      echo "-- applying patch: $(basename "$patch_file")"
      git -C "$chromium_root" apply "$patch_file"
    else
      echo "!! CEF source patch no longer applies: $patch_file" >&2
      exit 1
    fi
  done

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

  rm -rf "$applied_patch_dir"
  mkdir -p "$applied_patch_dir"
  for patch_file in "${patches[@]}"; do
    cp "$patch_file" "$applied_patch_dir/"
  done
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
    --build-target=cefsimple  # pulls in libcef + wrapper without cefclient's extra deps
  )

  reverse_nucleus_cef_patches

  if [[ $no_update -eq 0 ]]; then
    sync_args=("${automate_common[@]}" --no-build --no-distrib)
    if [[ -n "$NUCLEUS_CEF_CHECKOUT" ]]; then
      sync_args+=("--checkout=$NUCLEUS_CEF_CHECKOUT")
    fi
    if [[ $force_clean -eq 1 ]]; then
      sync_args+=(--force-clean)
    fi
    echo "-- automate-git.py ${sync_args[*]}"
    python3 "$automate" "${sync_args[@]}"
  fi

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
echo "-- staging $produced -> $staged"
rm -rf "$staged"
mkdir -p "$staged"
cp -a "$produced/." "$staged/"

# Keep Chromium's Vulkan loader: ANGLE is built and tested against this copy,
# and Noctalia safely shares it through the process-wide Vulkan SONAME. Remove
# only the SwiftShader implementation and ICD so software rendering cannot be
# selected as a fallback.
rm -f \
  "$staged/Release/libvk_swiftshader.so" \
  "$staged/Release/vk_swiftshader_icd.json"

# Colocate the split Resources/ payload next to libcef.so in Release/ — ICU
# (icudtl.dat) initializes before resource_dir settings apply, so it must sit
# beside the library. The consuming shell points its resource paths at Release/.
if [[ -d "$staged/Resources" ]]; then
  for f in "$staged"/Resources/*; do
    ln -sfn "../Resources/$(basename "$f")" "$staged/Release/$(basename "$f")"
  done
fi

tarball="$NUCLEUS_CEF_DIST_ROOT/cef-${version}-linux64-codecs.tar.gz"
echo "-- packaging $tarball"
tar -C "$NUCLEUS_CEF_DIST_ROOT" -czf "$tarball" "$version"
( cd "$NUCLEUS_CEF_DIST_ROOT" && sha256sum "$(basename "$tarball")" > "$tarball.sha256" )

# Record a machine-readable pointer to the freshest build.
cat > "$NUCLEUS_CEF_DIST_ROOT/latest.json" <<EOF
{
  "version": "$version",
  "branch": "$NUCLEUS_CEF_BRANCH",
  "chromium_version": "$NUCLEUS_CEF_CHROMIUM_VERSION",
  "dist_dir": "$staged",
  "tarball": "$tarball",
  "sha256_file": "$tarball.sha256",
  "gn_defines": "$GN_DEFINES"
}
EOF

cat > "$NUCLEUS_CEF_LOG_DIR/latest-run.env" <<EOF
NUCLEUS_CEF_VERSION=$version
NUCLEUS_CEF_BRANCH=$NUCLEUS_CEF_BRANCH
NUCLEUS_CEF_DIST_DIR=$staged
NUCLEUS_CEF_TARBALL=$tarball
EOF

echo
echo "== CEF build complete =="
echo "version:  $version"
echo "dist:     $staged"
echo "tarball:  $tarball"
echo "sha256:   $(cat "$tarball.sha256")"
echo
echo "Verify codecs by loading the dist in Noctalia and checking"
echo "canPlayType('audio/mp4; codecs=\"mp4a.40.2\"') is non-empty."
