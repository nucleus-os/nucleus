# Nucleus Swift Target SDKs

This component owns immutable Nucleus Swift SDK generation on the M2 Ultra. It
uses Xcode 27 for macOS execution and SDK assembly, and a matching official
Swift.org Linux/arm64 compiler inside the native Apple container as the
bootstrap compiler for Linux target libraries. It never builds a Swift
compiler, Swift driver, LLVM, Clang, SwiftPM, SourceKit-LSP, DocC, or another
host toolchain.

It does build the Linux target-side Swift standard library and overlays,
Dispatch, Foundation, XCTest, and Swift Testing from pinned source. Those
libraries are built natively for arm64 and cross-built for amd64 because every
Nucleus target must use libc++ uniformly. This is a target-runtime build, not a
Swift toolchain build.

`target-sdk.lock.json` pins one matching Swift 6.4 snapshot set:

- the signed Swift.org macOS package providing native arm64 host tools;
- the official Android artifact bundle;
- exact Ubuntu arm64 and amd64 package closures used as isolated glibc sysroots.

The selected Xcode 27 provides the macOS compiler, SDK, and developer tools.
Collider builds the pinned `swift-sdk-generator` with Xcode into an external
cache and runs SDK assembly directly on macOS. A native Linux/arm64 Apple
container uses the official Swift.org Linux/arm64 bootstrap compiler to build
the Linux target products natively for Linux/arm64 and by cross-compilation for
Linux/amd64. Each architecture has an independently
fingerprinted package-only Ubuntu sysroot, runtime build root, install root, and
compiler cache. Both sysroots contain libc++, never a bootstrap Swift overlay or
libstdc++. The runtime installs are the generator's sole target-Swift inputs; an
official Linux runtime tarball is not mixed into the SDK.

The runtime source closure is `libxml2`, `llvm-project`, `swift`, `swift-collections`,
`swift-corelibs-foundation`, `swift-corelibs-libdispatch`,
`swift-corelibs-xctest`, `swift-experimental-string-processing`,
`swift-foundation`, `swift-foundation-icu`, `swift-testing`, and
`swift-sdk-generator`. Repositories for compiler tooling, IDE services,
documentation tools, package management, and unrelated platforms are not SDK
build inputs.

Upstream `build-script` requires `llvm-project` while configuring the amd64
cross host, but the pipeline gives that product an empty build target list and
uses the builder image's LLVM and Clang. Swift Testing is built explicitly with
CMake after each architecture's Foundation build because upstream
`build-script` skips it for this Linux cross-product configuration. The runtime
task and validator require both its module interface and dynamic library.

Collider emits one `nucleus-swift-6.4-linux` SDK with arm64 and amd64 target
triples, wires the official Android SDK to the pinned macOS NDK, and cross-links
behavioral consumers for Linux arm64, Linux amd64, Android arm64, and Android amd64.
Validation inspects every ELF SDK artifact for forbidden `libstdc++` and
`GLIBCXX` dependencies, requires the Linux and Android consumers to link
`libc++`, and never executes target binaries on the Mac.

Run from any directory in the clone:

```sh
collider swift-sdk rebuild
collider swift-sdk status
```

The active generation lives under
`$XDG_CACHE_HOME/nucleus/swift-target-sdks/current`. Collider publishes the
two artifact-bundle links through `~/.swiftpm/swift-sdks`. An unchanged lock,
Xcode identity, source graph, runtime-builder image, generator source, NDK,
validation fixture, and validator reuse the active immutable generation without
rebuilding, downloading, assembling, validating, or publishing it again.
Runtime build products and ccache live outside the source submodules and remain
reusable when a later source-addressed generation needs work.
