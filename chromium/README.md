# Chromium products

This directory owns the shared Chromium substrate for two fixed products:

- codec-enabled CEF for Noctalia's embedded offscreen browser;
- Nucleus Browser, a standalone native-Wayland Chromium browser.

Run:

```sh
chromium/build.sh cef
chromium/build.sh browser
chromium/build.sh all
```

Both products reuse the pinned CEF/Chromium source checkout, depot_tools,
downloaded dependencies, PGO profiles, Dawn checkout, and compiler cache.
They do not share a GN output directory. CEF embeds `libcef.so` into Noctalia
and therefore disables Chromium's allocator shim and BackupRefPtr support.
Nucleus Browser is a standalone multi-process Chromium product and retains
Chromium's complete PartitionAlloc configuration.
The browser output disables Chromium and ANGLE SwiftShader construction; native
Vulkan capability is a startup requirement, not a software-rendering fallback.

Patch ownership is explicit:

- `patches/common/` contains Chromium-wide Graphite, Vulkan, SharedImage,
  device-selection, and media work used by both products;
- `patches/dawn/` contains changes owned by Dawn's nested checkout;
- `patches/browser/` contains the backend-neutral Ozone Wayland presenter,
  its Viz adapter, and browser-only on-screen integration;
- `../cef/patches/` contains only CEF OSR and CEF behavior changes.

The browser layer is applied only by `chromium/build.sh browser`. Every CEF
preparation first reverses that layer, so browser development cannot silently
change the proven CEF output. The generated copies under the shared cache
record the exact last-applied patches so renames and consolidations remain
reversible.

The current browser patch layer preserves the completed presenter extraction
and initial Viz/Graphite hookup from the development checkout. The focused
presenter targets can be rebuilt and run without constructing the full Chrome
binary:

```sh
source chromium/scripts/chromium-env.sh
export PATH="$NUCLEUS_CEF_DEPOT_TOOLS:$PATH"
autoninja -C "$NUCLEUS_BROWSER_OUT" \
  ui/ozone:ozone_unittests \
  components/viz/service:output_presenter_ozone_unittests
"$NUCLEUS_BROWSER_OUT/ozone_unittests" \
  --gtest_filter='*OzonePresenter*' --single-process-tests
"$NUCLEUS_BROWSER_OUT/output_presenter_ozone_unittests" \
  --gtest_filter='OutputPresenterOzoneTest.*' --single-process-tests
```

The small Viz test executable is intentional: it tests the API-neutral
presenter without the full `viz_unittests` suite's GL bootstrap. The production
browser output continues to omit SwiftShader and does not gain a software
runtime fallback for the sake of tests.

This remains source work ready for the next implementation phase, not yet a
supported installed browser. The architecture and remaining acceptance order
are defined in `docs/nucleus-browser-plan.md`.
