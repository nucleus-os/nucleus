# Debugging DRM-Mode Color Issues

When DRM-mode colors look "washed out" or different from expected, **check for external gamma-control clients first** before suspecting a rendering bug.

## Why

`wlsunset` and `gammastep` speak `wlr-gamma-control-unstable-v1` and program a `GAMMA_LUT` directly on the CRTC. The LUT persists across VT switches and across compositor restarts on the same session.

The 2026-04-13/14 "washed out colors in DRM mode" investigation traced what looked like a Skia/Graphite color-space bug to a stale `GAMMA_LUT` from `wlsunset`. With `wlsunset` killed, DRM and reference colors matched identically.

## Debugging steps

1. `pkill wlsunset gammastep` first, retest. If colors are correct now, you've found it.
2. Only chase rendering theories if the issue persists with no gamma clients running.

## Color-space facts to keep in mind

- Skia Graphite **does** apply software sRGB OETF in fragment shaders when `SkColorSpace` is sRGB. This is correct behavior, not a bug.
- Hardware sRGB via `VK_FORMAT_B8G8R8A8_SRGB` works but changes the blending model — shaders authored in sRGB-blending space look different under linear blending. Don't switch silently.

## Server-side gamma control

`wlr-gamma-control-unstable-v1` is implemented server-side in
`src/compositor/wayland/gamma_control.zig`. The debugging guidance above still
applies when an external gamma client is running against a different
compositor at the same time on the same outputs (rare in practice).
