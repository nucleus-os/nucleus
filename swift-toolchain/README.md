# Nucleus Swift Platform Recipe

This component owns the Swift 6.4 host-toolchain and Android SDK recipes used
by Collider. The host compiler, Android runtime libraries, Foundation
dependencies, SDK artifact bundle, validation products, and distributable host
archive are one immutable platform generation.

Run the workflow from the repository root:

```sh
tools/collider toolchain rebuild
tools/collider toolchain status
```

Use `--arch aarch64` or `--arch x86_64` to select Android targets. Repeat the
option to build both. `--dry-run`, `--explain`, `--verbose`, and `--json` use
the shared Collider execution controls. `--reconfigure` forces the upstream
host Swift build system to regenerate its projects.

Collider owns source synchronization, patch application, task identity,
locking, logs, staging, validation, packaging, Android SDK wiring, rollback,
and atomic activation. The upstream Swift `update-checkout` and `build-script`
programs remain the leaf executors.

The active generation is under
`~/.cache/nucleus/swift-platforms/<platform>/current`. Collider also publishes
the validated Android artifact bundle through `~/.swiftpm/swift-sdks`.

The recipe inputs are:

- `nucleus-build-presets.ini` for the Linux host product.
- `nucleus-build-presets-macos.ini` for the macOS host product.
- `nucleus-swift-cmake-overrides.cmake` for Linux libc++ and Blocks runtime
  configuration.
- `patches/` for the ordered upstream Swift repository changes.
- `apt-deps.txt` for the Linux host capability set.

`install.sh` is the narrow privileged boundary used by
`tools/collider toolchain install|uninstall`. Do not invoke it directly.
