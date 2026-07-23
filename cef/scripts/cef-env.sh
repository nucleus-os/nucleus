#!/usr/bin/env bash
# Shared fixed product configuration and cache-layout helpers for the CEF and
# Chromium stages. Version, compiler, and GN contracts are not environment
# profiles; only filesystem roots follow the user's XDG cache location.

# ---------------------------------------------------------------------------
# Pinned version. CEF adopted Chromium's branch numbering, so the CEF release
# branch == the Chromium branch (the third component of the Chromium version).
# Chromium 151.0.7922.19  ->  CEF branch 7922, which pins
# chromium_checkout refs/tags/151.0.7922.19. Bump both together on upgrade;
# ---------------------------------------------------------------------------
export NUCLEUS_CEF_BRANCH="7922"
# Exact CEF version to check out. A release branch can advance to a newer
# Chromium patch version without changing its branch number, so production
# builds must pin the CEF commit that matches NUCLEUS_CEF_CHROMIUM_VERSION.
export NUCLEUS_CEF_CHECKOUT="6c664b86a4ef3be5c95b1290068f5e5d52b72db3"
export NUCLEUS_CEF_CHROMIUM_VERSION="151.0.7922.19"
export NUCLEUS_CHROMIUM_CHECKOUT="8f914546f6536ee67a34edb3607f946616f55994"
# depot_tools participates in checkout, GN, Siso, CIPD, and packaging behavior.
# Treat it as a toolchain input instead of cloning whichever revision happens
# to be at branch head on build day.
export NUCLEUS_DEPOT_TOOLS_REVISION="35892a9e24190cc5f3a511d3954319c93445926c"

# The whole point of building from source: official CEF ships without patented
# codecs. These GN args add H.264/AAC (ffmpeg_branding=Chrome) which Apple
# Music web streams under Widevine. Widevine EME itself (external CDM loading)
# is already enabled in default CEF builds.
# CEF release builds consume Chromium's pinned compiler/toolchain but can still
# surface warnings from generated third-party bindings. Keep those warnings in
# the log without turning them into source-build failures.
# Production CEF is an official optimized build. CEF's Linux official
# configuration already avoids PartitionAlloc-as-malloc for client
# compatibility; keep the allocator shim and BackupRefPtr support explicitly
# disabled as well so the embedding process retains system malloc as its sole
# process allocator.
# Noctalia runs only on Wayland and owns the actual wl_surface used for
# presentation. Build Chromium's Ozone Wayland backend without the unused X11
# window-system backend or fallback.
export NUCLEUS_CEF_GN_DEFINES_BASE="proprietary_codecs=true ffmpeg_branding=Chrome use_dbus=true is_official_build=true symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper=\"\" use_allocator_shim=false enable_backup_ref_ptr_support=false enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false ozone_platform=wayland ozone_platform_wayland=true ozone_platform_x11=false"

# ---------------------------------------------------------------------------
# Cache / output layout (mirrors ~/.cache/nucleus/swift-* components).
# ---------------------------------------------------------------------------
_cache="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/cef"
export NUCLEUS_CEF_CACHE_ROOT="${NUCLEUS_CEF_CACHE_ROOT:-$_cache}"
# depot_tools clone (git, gclient, gn, autoninja).
export NUCLEUS_CEF_DEPOT_TOOLS="${NUCLEUS_CEF_DEPOT_TOOLS:-$NUCLEUS_CEF_CACHE_ROOT/depot_tools}"
# Prepared source generations are content-addressed and never refreshed in
# place. The orchestrator sets NUCLEUS_CHROMIUM_SOURCE_ID before sourcing this
# file for commands that consume a generation.
export NUCLEUS_CHROMIUM_SOURCE_GENERATIONS="${NUCLEUS_CHROMIUM_SOURCE_GENERATIONS:-$NUCLEUS_CEF_CACHE_ROOT/source-generations}"
export NUCLEUS_CHROMIUM_SOURCE_CURRENT="${NUCLEUS_CHROMIUM_SOURCE_CURRENT:-$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS/current}"
if [[ -n "${NUCLEUS_CHROMIUM_SOURCE_ID:-}" ]]; then
  export NUCLEUS_CEF_SRC_ROOT="${NUCLEUS_CEF_SRC_ROOT:-$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS/$NUCLEUS_CHROMIUM_SOURCE_ID}"
elif [[ -L "$NUCLEUS_CHROMIUM_SOURCE_CURRENT" ]]; then
  export NUCLEUS_CEF_SRC_ROOT="${NUCLEUS_CEF_SRC_ROOT:-$(realpath -- "$NUCLEUS_CHROMIUM_SOURCE_CURRENT")}"
else
  export NUCLEUS_CEF_SRC_ROOT="${NUCLEUS_CEF_SRC_ROOT:-$NUCLEUS_CHROMIUM_SOURCE_GENERATIONS/unprepared}"
fi
# Extracted, ready-to-consume distribution + the checksummed artifact.
export NUCLEUS_CEF_DIST_ROOT="${NUCLEUS_CEF_DIST_ROOT:-$NUCLEUS_CEF_CACHE_ROOT/dist}"
export NUCLEUS_BROWSER_DIST_ROOT="${NUCLEUS_BROWSER_DIST_ROOT:-$NUCLEUS_CEF_CACHE_ROOT/browser-dist}"
export NUCLEUS_CEF_LOG_DIR="${NUCLEUS_CEF_LOG_DIR:-$NUCLEUS_CEF_CACHE_ROOT/logs}"

_nucleus_cpu_count="$(nproc)"
if [[ "$_nucleus_cpu_count" -gt 16 ]]; then
  _nucleus_cpu_count=16
fi
export NUCLEUS_CHROMIUM_JOBS="$_nucleus_cpu_count"
unset _nucleus_cpu_count

nucleus_cef_automate_url() {
  echo "https://raw.githubusercontent.com/chromiumembedded/cef/${NUCLEUS_CEF_CHECKOUT}/tools/automate/automate-git.py"
}

nucleus_cef_require_tool() {
  # $1 = binary, $2 = apt package hint
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing host tool: $1 (try: sudo apt install $2)" >&2
    return 1
  fi
}
