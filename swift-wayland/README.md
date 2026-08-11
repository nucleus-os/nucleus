# swift-wayland

Root-package **Wayland protocol bindings**, generated from the vendored protocol XML by
`SwiftWaylandGen` and `wayland-scanner`. Runtime targets import the module for their role;
they do not run protocol generation themselves.

Generated dispatch isolation, handler binding, and resource ownership are
defined by [Swift Wayland Architecture](ARCHITECTURE.md).

Unlike [`swift-vulkan`](../swift-vulkan) (a fixed API generated
once and shipped), Wayland is a *menu* of protocols consumed in one of two modes. This package
ships **both modes pre-built over the full vendored protocol set**, so protocol selection is a
runtime decision (which globals a consumer advertises / binds), not a compile-time one.

## Modules

| product | for | contents |
|---|---|---|
| **`WaylandServerC`** | compositors | server-side event senders + request-handler vtables, façading `<wayland-server.h>` |
| **`WaylandClientC`** | clients | client-side proxy inlines, façading `<wayland-client.h>` |
| **`WaylandProtocolsC`** | both | the `wl_interface` marshalling (mode-independent) — linked alongside either mode module |

A compositor depends on `WaylandServerC` + `WaylandProtocolsC` and `import WaylandServerC`; a
client depends on `WaylandClientC` + `WaylandProtocolsC` and `import WaylandClientC`. The modules
are systemLibraries façading libwayland's own headers, so a consumer needs libwayland at
build/link time but nothing else.

## Protocol set

The full vendored set (62 protocols): core `wayland.xml`, upstream `wayland-protocols` @ v1.48+2
(stable + staging + unstable), and curated kde/wlr extras (`wlr-layer-shell`, `kde-blur`,
`kde-kwin-appmenu`, …). Deprecated/duplicate versions whose stable successors are present
(`tablet-unstable-v2`, `xdg-shell-unstable-v5`, `linux-dmabuf-unstable-v1`, the duplicate
`presentation-time`) are excluded to avoid duplicate `wl_interface` symbols.

The generated modules are committed. Regenerate after a protocol bump:

```sh
collider generate wayland
```

`SwiftWaylandGen` is a repository generator target.

## Consumers

- A Wayland compositor imports `WaylandServerC`.
- A Wayland client imports `WaylandClientC`.
