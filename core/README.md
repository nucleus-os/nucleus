# Core

`core/` owns the portable render/UI implementation and Android application host inside the root SwiftPM package.

Its targets provide shared value types, retained render state, Skia Graphite/Vulkan rendering, text layout, NucleusUI, application/scene vocabulary, and platform host seams. Compositor and React Native targets consume these modules through the root manifest; `core/` is not a standalone Swift package.

The component owns `render` within each per-target native SDK root, such as
`~/.cache/nucleus/nucleus-native-sdk/linux-arm64/render`, and owns generated
native outputs under `core/.skia-build`. Provision and verify it from the
repository root:

```sh
collider bootstrap core
collider build core
collider test core
collider android native
```

Important directories:

- `swift/Sources/` and `swift/Tests/`: portable Swift implementation and tests.
- `render-cxx/`: Skia Graphite and text-layout C++ bridges.
- `platform-android/`: Swift Android host and JNI boundary.
- `packages/`: JavaScript-facing Nucleus application packages.
- `third-party/`: root-owned pinned dependencies used by the render stack.

All targets use Swift C++ interoperability. Public source API is limited to the supported root products; first-party cross-module implementation API uses `package` visibility.
