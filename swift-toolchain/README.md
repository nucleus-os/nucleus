# Nucleus Swift Platform Recipe

This component owns the Swift 6.4 host-toolchain and Android SDK recipes used
by Collider. The host compiler, Android runtime libraries, Foundation
dependencies, SDK artifact bundle, validation products, and distributable host
archive are one immutable platform generation.

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

On Linux, Collider builds the host toolchain, SwiftAndroid runtimes, and their
native dependencies through `build-container/`. The resulting Podman image is
selected by its content-addressed image ID; compilation has no network, mounts
`source/` read-only, and writes only to external build, cache, candidate, and
artifact roots. The same upstream `build-script` entry point runs on macOS
natively. Collider owns task identity, ordering, locking, logs, staging,
validation, packaging, Android SDK wiring, rollback, and atomic activation.

The active generation is under
`~/.cache/nucleus/swift-platforms/<platform>/current`. Collider also publishes
the validated Android artifact bundle through `~/.swiftpm/swift-sdks`.

The recipe inputs are:

- `nucleus-build-presets.ini` for the Linux host product.
- `nucleus-build-presets-macos.ini` for the macOS host product.
- `nucleus-swift-cmake-overrides.cmake` for Linux libc++ and Blocks runtime
  configuration.
- `build-container/` for the pinned Linux build environment and its single
  entry point.
- `source/` for the complete root-owned Swift sibling submodule graph.

`collider toolchain install|uninstall` re-executes the current Collider binary
through `sudo` for the narrowly validated system mutation. No standalone
privileged installation script or second publication implementation exists.
