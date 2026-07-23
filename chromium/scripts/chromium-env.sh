#!/usr/bin/env bash

chromium_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chromium_root="$(cd "$chromium_script_dir/.." && pwd)"
workspace_root="$(cd "$chromium_root/.." && pwd)"

# The CEF component remains the checkout provisioner because automate-git.py
# owns the pinned CEF/Chromium pairing. Both products consume this one source
# generation, pinned depot_tools checkout, and PGO payload.
source "$workspace_root/cef/scripts/cef-env.sh"

export NUCLEUS_CHROMIUM_SRC_ROOT="$NUCLEUS_CEF_SRC_ROOT/chromium/src"
export CHROMIUM_BROWSER_OUT="${CHROMIUM_BROWSER_OUT:-$NUCLEUS_CHROMIUM_SRC_ROOT/out/NucleusBrowser_GN_x64}"

# The standalone Chromium process intentionally retains
# Chromium's allocator shim, PartitionAlloc malloc integration, and
# BackupRefPtr support. CEF's embedding-specific allocator overrides stay in
# its independent GN output.
export CHROMIUM_BROWSER_GN_DEFINES_BASE='proprietary_codecs=true ffmpeg_branding="Chrome" is_chrome_branded=false enable_cef=false use_dbus=true enable_widevine=true is_official_build=true is_component_build=false symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper="" use_allocator_shim=true use_partition_alloc_as_malloc=true enable_backup_ref_ptr_support=true enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false clang_use_chrome_plugins=false ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false use_sysroot=false target_cpu="x64"'
