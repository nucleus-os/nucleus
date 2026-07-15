#!/usr/bin/env bash
# Shared configuration + helpers for the CEF native build component.
# Sourced by build.sh. Everything here is overridable via environment so the
# build slots into the same ~/.cache/nucleus provisioning model the render/rn
# SDKs and the Swift toolchain/Android SDK builders use.

# ---------------------------------------------------------------------------
# Pinned version. CEF adopted Chromium's branch numbering, so the CEF release
# branch == the Chromium branch (the third component of the Chromium version).
# Chromium 151.0.7922.19  ->  CEF branch 7922, which pins
# chromium_checkout refs/tags/151.0.7922.19. Bump both together on upgrade;
# keep in sync with config/build-contract.json and the consuming shells.
# ---------------------------------------------------------------------------
export NUCLEUS_CEF_BRANCH="${NUCLEUS_CEF_BRANCH:-7922}"
# Exact CEF version to check out. Empty => most recent on the branch (still the
# same Chromium tag). Set this only when pinning a specific CEF patch release.
export NUCLEUS_CEF_CHECKOUT="${NUCLEUS_CEF_CHECKOUT:-}"
export NUCLEUS_CEF_CHROMIUM_VERSION="${NUCLEUS_CEF_CHROMIUM_VERSION:-151.0.7922.19}"

# The whole point of building from source: official CEF ships without patented
# codecs. These GN args add H.264/AAC (ffmpeg_branding=Chrome) which Apple
# Music web streams under Widevine. Widevine EME itself (external CDM loading)
# is already enabled in default CEF builds.
# CEF release builds consume Chromium's pinned compiler/toolchain but can still
# surface warnings from generated third-party bindings. Keep those warnings in
# the log without turning them into source-build failures.
export NUCLEUS_CEF_GN_DEFINES_BASE="proprietary_codecs=true ffmpeg_branding=Chrome use_dbus=true treat_warnings_as_errors=false"
# Appended verbatim — e.g. is_official_build=true (slower, needs PGO) for a
# perf-optimized redistribution build.
export NUCLEUS_CEF_GN_EXTRA="${NUCLEUS_CEF_GN_EXTRA:-}"

# ---------------------------------------------------------------------------
# Cache / output layout (mirrors ~/.cache/nucleus/swift-* components).
# ---------------------------------------------------------------------------
_cache="${XDG_CACHE_HOME:-$HOME/.cache}/nucleus/cef"
export NUCLEUS_CEF_CACHE_ROOT="${NUCLEUS_CEF_CACHE_ROOT:-$_cache}"
# depot_tools clone (git, gclient, gn, autoninja).
export NUCLEUS_CEF_DEPOT_TOOLS="${NUCLEUS_CEF_DEPOT_TOOLS:-$NUCLEUS_CEF_CACHE_ROOT/depot_tools}"
# automate-git.py download dir: holds chromium/src (+ out_<branch>) and cef/.
export NUCLEUS_CEF_SRC_ROOT="${NUCLEUS_CEF_SRC_ROOT:-$NUCLEUS_CEF_CACHE_ROOT/src/$NUCLEUS_CEF_BRANCH}"
# Extracted, ready-to-consume distribution + the checksummed artifact.
export NUCLEUS_CEF_DIST_ROOT="${NUCLEUS_CEF_DIST_ROOT:-$NUCLEUS_CEF_CACHE_ROOT/dist}"
export NUCLEUS_CEF_LOG_DIR="${NUCLEUS_CEF_LOG_DIR:-$NUCLEUS_CEF_CACHE_ROOT/logs}"

export NUCLEUS_CEF_JOBS="${NUCLEUS_CEF_JOBS:-$(nproc)}"

# ccache — shared with the rest of the workspace's native builds.
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"

nucleus_cef_automate_url() {
  echo "https://raw.githubusercontent.com/chromiumembedded/cef/refs/heads/${NUCLEUS_CEF_BRANCH}/tools/automate/automate-git.py"
}

nucleus_cef_require_tool() {
  # $1 = binary, $2 = apt package hint
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing host tool: $1 (try: sudo apt install $2)" >&2
    return 1
  fi
}
