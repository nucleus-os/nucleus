# Swift Toolchain

The active Swift compiler and Android SDK are one Collider-owned immutable
platform generation. Component builds consume that generation; they do not
build, install, or mutate toolchain state themselves.

Use:

```sh
collider doctor toolchain
collider toolchain rebuild
collider toolchain status
```

The build uses the component recipe in `swift-toolchain/`, invokes only the
upstream Swift checkout and build programs as leaf executors, validates host
tools and Android consumers, then atomically activates both artifacts.

System installation crosses the privilege boundary only through:

```sh
collider toolchain install
collider toolchain uninstall
```

Ordinary repository work uses the user-level active generation selected by
Collider and `tools/host-env.sh`.
