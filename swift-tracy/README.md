# swift-tracy

Swift bindings for the [Tracy](https://github.com/wolfpld/tracy) frame profiler. A thin C++ shim
compiles the Tracy client and exposes an ergonomic Swift `Trace` API over C++ interop. Tracy is
pinned as a source submodule, so nothing depends on a system installation.

```swift
import Tracy

Trace.setThreadName("render")
Trace.zone("frame") {
    // … work …
    Trace.plot("fps", 60.0)
}
```

## Off by default

The whole Tracy client is **inert unless `TRACY_ENABLE` is defined** — both C++ TUs compile to
nothing and the Swift API is a set of safe no-ops, so release builds pay nothing. Turn it on for a
build:

```sh
swift build -Xcc -DTRACY_ENABLE
```

The `-Xcc` flag reaches this package's C++ target through the build graph, so a consumer enables
profiling the same way whether the bindings are in-tree or consumed as a dependency.
The complete Nucleus runtime build, launch, capture, and export workflow is:

```sh
tools/nucleus run --tracy --seconds 20
```

## Layout

- **`Sources/TracyBridge`** — the C++ shim: `TraceBridge.cpp` (the `swift_tracy::TraceBridge`
  façade over the Tracy C API) + `TracyClientShim.cpp` (`#include "TracyClient.cpp"` from the pinned
  tree). The client is co-located with the bridge because SwiftBuild drops a standalone C++ archive
  from the cxx-interop link — the `___tracy_*` symbols must share the archive the Swift side links.
- **`Sources/Tracy`** — the Swift `Trace` API (zones, plots, messages, thread names).
- **`third-party/tracy`** — the upstream Tracy submodule, pinned to the commit expected by the
  `tracy-capture` receiver.
