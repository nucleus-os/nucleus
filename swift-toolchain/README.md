# Nucleus Swift Platform Recipe

This component owns the generated Linux amd64 Swift 6.4 toolchain and Android
SDK recipes used by Collider. The Linux compiler, Android runtime libraries,
Foundation dependencies, SDK artifact bundle, builder validation products, and
distributable Linux archive are one immutable platform generation. Native
macOS builds use the Swift toolchain supplied by the selected Xcode 27.

Run the workflow from the repository root:

```sh
collider toolchain rebuild
collider toolchain status
```

Use `--arch aarch64` or `--arch x86_64` to select Android targets. Repeat the
option to build both. `--dry-run`, `--explain`, `--verbose`, and `--json` use
the shared Collider execution controls. Collider regenerates upstream build
configuration before reusing compiled products.

The complete Swift sibling source graph is pinned by root gitlinks under
`source/`. Collider validates that every top-level and nested submodule is
initialized at its recorded commit and clean. It never selects, fetches,
resets, cleans, patches, or materializes Swift source.

Collider builds the Linux host toolchain, SwiftAndroid runtimes, their native
dependencies, and builder-time smoke tests through `build-container/` on every
orchestration host. The digest-selected image runs as `linux/amd64` through
Apple `container` on macOS ARM64 and Podman on Linux x86_64. Compilation has no
network, mounts `source/` read-only, and writes only to external build, cache,
candidate, and artifact roots. Collider owns task identity, ordering, locking,
logs, staging, validation, packaging, Android SDK wiring, rollback, and atomic
activation. Native Linux x86_64 qualification is a separate downstream gate.

The active generation is under
`~/.cache/nucleus/swift-platforms/<source>-linux-amd64/current`. Collider also
publishes the validated Android artifact bundle through
`~/.swiftpm/swift-sdks`.

The recipe inputs are:

- `nucleus-build-presets.ini` for the Linux host product.
- `nucleus-swift-cmake-overrides.cmake` for Linux libc++ and Blocks runtime
  configuration.
- `build-container/` for the pinned Linux build environment and its single
  entry point.
- `source/` for the complete root-owned Swift sibling submodule graph.

`collider toolchain install|uninstall` re-executes the current Collider binary
through `sudo` for the narrowly validated system mutation. No standalone
privileged installation script or second publication implementation exists.
