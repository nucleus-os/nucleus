# Nucleus Swift Target SDKs

This component owns immutable Swift host-tool and target-SDK generation on the
M2 Ultra. It uses official compilers for both execution architectures and never
builds a compiler, LLVM, or Linux host tools. It does build the Nucleus Swift
Linux/amd64 runtime and SDK overlays from the pinned source graph because those
target libraries contain Nucleus APIs and must use libc++ uniformly.

`target-sdk.lock.json` pins one matching Swift 6.4 snapshot set:

- the signed Swift.org macOS package providing native arm64 host tools;
- the official Android artifact bundle;
- the exact Ubuntu amd64 package closure used as the glibc sysroot.

The selected Xcode 27 provides the macOS SDK and developer tools. Collider
builds the pinned `swift-sdk-generator` with Xcode into an external cache and
runs SDK assembly directly on macOS. A native Linux/arm64 Apple container uses the
official Swift.org Linux/arm64 compiler to cross-build only the Nucleus Swift
runtime, Dispatch, Foundation, XCTest, and Swift Testing for Linux/amd64. Its
package-only Ubuntu sysroot contains libc++, never a bootstrap Swift overlay or
libstdc++. The runtime install is the generator's sole target-Swift input; an
official Linux runtime tarball is not mixed into the SDK.

Collider wires the official Android SDK to the pinned macOS NDK and cross-links
behavioral consumers for Linux amd64, Android arm64, and Android amd64.
Validation inspects every ELF SDK artifact for forbidden `libstdc++` and
`GLIBCXX` dependencies, requires the Linux and Android consumers to link
`libc++`, and never executes target binaries on the Mac.

Run from any directory in the clone:

```sh
collider toolchain rebuild
collider toolchain status
```

The active generation lives under
`$XDG_CACHE_HOME/nucleus/swift-target-sdks/current`. Collider publishes the
two artifact-bundle links through `~/.swiftpm/swift-sdks`. An unchanged lock,
Xcode identity, source graph, runtime-builder image, generator source, NDK,
validation fixture, and validator reuse the active immutable generation without
rebuilding, downloading, assembling, validating, or publishing it again.
Runtime build products and ccache live outside the source submodules and remain
reusable when a later source-addressed generation needs work.
