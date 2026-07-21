# Chromium products

This directory owns the shared Chromium substrate for two fixed products:

- codec-enabled CEF for Noctalia's embedded offscreen browser;
- Nucleus Browser, a standalone native-Wayland browser built from Chromium.

Run:

```sh
chromium/build.sh cef
chromium/build.sh browser
chromium/build.sh all
```

`all` performs the source sync, patching, CEF translation, and API-hash work
once, then builds the two independent GN outputs concurrently. It splits
`NUCLEUS_CEF_JOBS` between the two Ninja processes instead of giving each the
full host CPU count. CEF distribution packaging remains attached to the CEF
side and publishes atomically as before.

Both products reuse the pinned CEF/Chromium source checkout, depot_tools,
downloaded dependencies, PGO profiles, Dawn checkout, and a source-normalized
ccache. Matching translation units can therefore be reused across the two GN
outputs without conflating their allocator or process contracts.
They do not share a GN output directory. CEF embeds `libcef.so` into Noctalia
and therefore disables Chromium's allocator shim and BackupRefPtr support.
The browser is a standalone multi-process Chromium product and retains
Chromium's complete PartitionAlloc configuration. Its GN output also sets
`enable_cef=false`; CEF patches remain present in the shared source revision,
but CEF-only runtime behavior and OSR proxy sources are excluded from the
standalone browser.
Both products require Graphite on Dawn's Vulkan backend. Chromium may restart a
failed GPU process within its normal crash budget, but every restart uses that
same renderer. Initialization failure or exhaustion of the crash budget is a
named fatal error; Ganesh, GL, and software compositing are not recovery paths.
The browser output also disables Chromium and ANGLE SwiftShader construction.

Patch ownership is explicit:

- `patches/common/` contains Chromium-wide Graphite, Vulkan, SharedImage,
  device-selection, and media work used by both products;
- `patches/dawn/` contains changes owned by Dawn's nested checkout;
- `patches/browser/` contains the backend-neutral Ozone Wayland presenter,
  its Viz adapter, browser-only on-screen integration, and Linux browser-chrome
  glass rendering;
- `../cef/patches/` contains only CEF OSR and CEF behavior changes.

Every CEF and browser preparation applies all four layers to the same Chromium
source tree. Product ownership controls which targets consume an API; it does
not create different patched source revisions. This lets CEF and the standalone
browser share fixes in Viz, SharedImage, Dawn, Ozone, media, and GPU selection,
and it makes source-level interactions visible before either output is
generated. The generated copies under the shared cache record the exact
last-applied patches so renames and consolidations remain reversible.

The common patch layer contains the strict renderer, device/media,
Graphite/Dawn Ozone SharedImage, and DRM-modifier work consumed by both
products. The browser patch layer contains only the completed presenter
extraction, Viz adapter, on-screen Graphite hookup, Linux browser-chrome glass
rendering, browser UI feature defaults, and their source-level tests. The
focused presenter targets can be rebuilt and run without constructing the full
Chrome binary:

```sh
source chromium/scripts/chromium-env.sh
export PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH"
autoninja -C "$CHROMIUM_BROWSER_OUT" \
  ui/ozone:ozone_unittests \
  components/viz/service:output_presenter_ozone_unittests
"$CHROMIUM_BROWSER_OUT/ozone_unittests" \
  --gtest_filter='*OzonePresenter*' --single-process-tests
"$CHROMIUM_BROWSER_OUT/output_presenter_ozone_unittests" \
  --gtest_filter='OutputPresenterOzoneTest.*' --single-process-tests
```

The small Viz test executable is intentional: it tests the API-neutral
presenter without the full `viz_unittests` suite's GL bootstrap. The production
browser output continues to omit SwiftShader and does not gain a software
runtime fallback for the sake of tests.

All planned coding is complete, but the final cumulative revision is not yet a
supported installed browser. It still needs the single final optimized build,
focused tests, install, validation run, and live acceptance sequence defined in
`docs/nucleus-browser-plan.md`.

After the final browser build, stage its relocatable runtime, Nucleus Browser
launcher and desktop identity, sandbox, Widevine component, and Chromium
resources with:

```sh
chromium/install-browser.sh
chromium/diagnose-browser.sh
```

The installer tests whether an unprivileged user namespace can actually be
created; it does not infer sandbox availability from a sysctl. On systems such
as Ubuntu with AppArmor user-namespace restrictions, it uses `sudo` only to
install Chromium's root-owned mode-4755 helper at
`/usr/local/libexec/nucleus-browser/chrome-sandbox`. The user-owned browser
runtime and profile remain under the selected prefix. The launcher rejects
command-line switches that disable Chromium's process sandboxes.

The external product identity is intentionally narrow: the launcher, desktop
entry/application ID, runtime directory, and independent profile/cache roots
use Nucleus Browser. Chromium's generated icon remains in use until a dedicated
icon exists, and the engine keeps upstream Chromium strings, internal pages,
resources, and `is_chrome_branded=false`.

The launcher adds no renderer-selection flags. Graphite/Dawn/Vulkan and native
Wayland are source/build invariants. It uses the package-owned private NVIDIA
VA-API driver at
`~/.local/lib/nvidia-vaapi-driver/current/lib/dri`. The launcher publishes
that module's path, which is inherited through Chromium's zygote. Before
driver loading and sandbox entry, the GPU child selects it only when Wayland's
compositor-selected DRM node is NVIDIA. Intel and AMD main devices keep normal
system-driver discovery, and the launcher never guesses or hard-codes
`NVD_DRM_DEVICE`. The browser process also retains the file descriptor from
Wayland's same `main_device` feedback for linux-drm-syncobj ioctls; it does not
open an independently guessed node for explicit synchronization.
When that selected node is NVIDIA, the GPU child requires the exact private
`nvidia_drv_video.so` before entering the sandbox. This does not globally
disable Chromium's normal driver checks for other vendors.
