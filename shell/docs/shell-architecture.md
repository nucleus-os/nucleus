# Nucleus Shell Architecture

## Invariant

`nucleus-shell` is an out-of-process native Swift Wayland shell. Product code
imports public `NucleusUI`; the runtime owns Wayland roles, platform services,
input translation, scene publication, Vulkan presentation, and lifecycle. The
shell contains no React Native or JavaScript execution path.

## Ownership graph

```text
NucleusShellProduct
  Swift views + typed state + typed user actions
                  │
                  ▼
             NucleusUI
                  │
                  ▼
NucleusShellRuntime.NativeSurfaceRegistry
  WindowScene + surface geometry + input association
                  │
                  ▼
NucleusShellRender
  Skia Graphite + Vulkan Wayland WSI
                  │
                  ▼
             Wayland compositor
```

`ShellProductController` retains product state across output hotplug and creates
one `ShellBarProduct` view tree per output. `ForeignToplevelManager` and Linux
services project protocol-specific state into product-owned Swift values.
Product actions return as typed commands; no serialization bridge sits inside
the process.

`NativeSurfaceRegistry` is the single lifecycle owner behind layer-shell and
session-lock roles. It associates a Wayland surface with a NucleusUI `Window`,
registers input, maintains logical/pixel geometry and scale, owns the render
presenter identifier, and removes all of them in reverse order.

`WindowScenePublicationContext` supplies the authoritative semantic and visual
contexts. The reactor publishes that scene on explicit state or animation
demand, then `ShellRenderEngine` renders each configured WSI presenter. Clock,
input-repeat, tooltip, service, authentication, and presentation deadlines are
folded into the reactor wait plan; idle operation does not redraw periodically.

The lock screen uses the same native scene and surface registry as the bar. PAM
runs in `NucleusShellPamHelper`, keeping arbitrary PAM modules outside the
Wayland/Vulkan shell process.
