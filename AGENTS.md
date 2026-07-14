# Nucleus Agent Guide

Nucleus is a monorepo built with Swift 6.4 through SwiftPM.

## Default Engineering Posture

- Prefer the ideal long-term architecture over compatibility shims, dual preserved pipelines, feature-flagged old paths, or deprecated wrappers.
- Delete replaced APIs directly and fix all callers in the same change. If dead code falls out, remove it.
- Hard-require modern Vulkan/kernel/toolchain features when they fit. For Vulkan, append required extensions where the renderer declares its instance/device requirements; failing device creation is correct when requirements are missing.
- Match macOS patterns for compositor work and iOS patterns for RN library work, then account for Linux/Wayland/io_uring/Vulkan constraints.
- Do not provide wall-clock estimates. Scope work by files, structural moves, dependencies, and risk surface.

## Workflow Directives

- The user may edit concurrently. Never revert changes without explicit permission, even if they break builds.
- When asked to commit or push, do it on the current branch (including `main`). Create a new branch only when the user explicitly asks for one; do not branch off `main` by default.
- Compile/test verification runs directly on the host after sourcing `tools/host-env.sh`.
- Do not write tests that inspect source-code shape or declaration presence/absence, such as `@hasDecl` assertions for APIs that should not exist. Test behavior and runtime contracts instead.
- Avoid full cache wipes (`rm -rf .build`) except as a last resort after source/build causes are ruled out, or if disk space is full.
- Do not launch the compositor/app, start manual interactive sessions, or run long-lived foreground processes without explicit user request.
- A goal may be marked complete when implementation and every agent-runnable verification gate are complete and the only remaining step is the user's own validation or interactive run. State that handoff explicitly; user-owned validation does not keep the goal open.
- React 19 and React Compiler are enabled. Do not use `useMemo`, `useCallback`, etc.
- Do not patch the vendored React Native tree. Public RN compatibility is required; pnpm patches against dependencies are allowed.
- When writing plans, use strict sequential phase order. Do not describe phases as parallel.
- Plans must avoid git/PR/commit/branch/release mechanics. Use technical ordering language like "lands with", "happens alongside", and "as part of phase N".
- Plan voice is direct and unambiguous. Write the ideal solution without hedging between options.
- When writing a new doc or plan under `docs/`, just write it. Do not read other docs or study formatting conventions first; use the structure these directives already specify (state invariant first, strict sequential phases, direct voice) and a `kebab-case.md` filename.
- When debugging, inspect newest relevant logs/profiles/screenshots first, add diagnostics before speculative fixes, and do not attempt more than one speculative fix without log-based evidence.
- Do not stop mid-task to check in when the work is within capability. Ask only for genuine design forks, destructive actions, or blockers requiring user input.

## Build System

- Single opinionated build: all integrations compile, no profiles or feature flags.
- The build is a monorepo of SwiftPM packages: `core/` owns the portable render/UI core and Android host, `react-native/` owns the RN platform and native stack, `compositor/compositor-core` and `compositor/compositor` own the Wayland/DRM library and executable, and `shell/` owns the out-of-process desktop shell. First-party package dependencies are relative paths. Third-party source remains in root-managed submodules. The `@_spi(NucleusCompositor)` group is the single privileged seam into the render core. Use the top-level `tools/nucleus` command for complete-checkout doctor/bootstrap/build/test operations.
- First-party C/C++ shims consumed by Swift are SwiftPM C targets plus module maps. C++ libraries (Skia Graphite, ReactCommon/Hermes/folly) are reached via C++ interop (`.interoperabilityMode(.Cxx)`). A non-cxx module must not `import` a cxx one directly — that drags the cxx module's C++ clang module graph into the importer. Instead the cxx side installs `@convention(c)` (or Swift) closures into a struct at bring-up, or conforms to a protocol seam the non-cxx side owns (e.g. `RenderUploadSink`, `CompositorShellPolicy`); the boundary carries only opaque handles and scalars. Genuine Swift→C entry points (the JNI/on-device and headless-test harnesses) use `@c` / `@c @implementation`, which type-check C-compatibility and emit the C declaration — the older free-standing `@_cdecl`/`@_silgen_name` seam was retired with the Zig loop.
- The native C++ stack is provisioned once into `~/.cache/nucleus/nucleus-native-sdk`, split into `render` (owned by `core/`) and `rn` (owned by `react-native/`). Generated and native build outputs stay under their owning package (`core/.skia-build`, `react-native/.rn-build`, and `react-native/.cxx-build`). The top-level staged bootstrap owns the complete dependency order and artifact fingerprints.
- The Swift toolchain source is the `swift-toolchain/` monorepo component (Swift 6.4). A full toolchain rebuild is only needed when a change affects the Swift compiler or installed toolchain shape (its patches, build preset, or LLVM/link configuration); run `swift-toolchain/build.sh`. Toolchain patches take effect on the next rebuild.

### Prerequisites

A fresh clone is provisioned by `tools/nucleus bootstrap` (see the render-SDK provisioning
above); it runs the steps below and builds. Run individually only when iterating.

Skia third-party deps synced once, plus Dawn's vendored codegen (regenerate after a Skia
bump):

```sh
third-party/sync-deps.sh                    # submodules + skia git-sync-deps + dawn patches
swift package generate-dawn --allow-writing-to-package-directory
```

The React Native FBReactNativeSpec codegen (`generate-rn-spec`) and the RN native builds
live in **`react-native/`**, not `core/`.

## Submodules

Submodules are detached HEADs. If one needs first-party patches, fork it under `maddythewisp` (Codeberg/GitHub), repoint the submodule at the fork, and push over SSH: `git push origin HEAD:refs/heads/<branch>`.

The monorepo root is the source-control and release boundary. First-party package directories are not submodules.
