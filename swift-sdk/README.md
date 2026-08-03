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

`target-sdk-inputs.json` is the external-artifact manifest for one matching
Swift 6.4 snapshot set. It pins only inputs that gitlinks cannot represent:

- the signed Swift.org macOS package providing native arm64 host tools;
- the official Android artifact bundle;
- exact Ubuntu arm64 and amd64 runtime-build and SDK-link package closures.

The selected Xcode 27 provides the macOS compiler, SDK, and developer tools.
Collider builds the pinned `swift-sdk-generator` with Xcode into an external
cache and runs SDK assembly directly on macOS. A native Linux/arm64 Apple
container uses the official Swift.org Linux/arm64 bootstrap compiler to build
the Linux target products natively for Linux/arm64 and by cross-compilation for
Linux/amd64. Each architecture has an independently
fingerprinted runtime-build Ubuntu sysroot, runtime build root, install root, and
compiler cache. The runtime sysroots contain libc++, never a bootstrap Swift
overlay or libstdc++. SDK-only link packages such as Vulkan, PAM, DRM, GBM,
systemd, input, udev, seat, xkbcommon, XCB, fontconfig, and FreeType are added during assembly and do not
invalidate either Swift runtime build. The runtime installs are the generator's
sole target-Swift inputs; an official Linux runtime tarball is not mixed into
the SDK.

The root gitlinks are the sole source-revision authority. The runtime source
closure is `libxml2`, `llvm-project`, `swift`, `swift-collections`,
`swift-corelibs-foundation`, `swift-corelibs-libdispatch`,
`swift-corelibs-xctest`, `swift-experimental-string-processing`,
`swift-foundation`, `swift-foundation-icu`, `swift-testing`, and
`swift-sdk-generator`. Repositories for compiler tooling, IDE services,
documentation tools, package management, and unrelated platforms are not SDK
build inputs. Collider reads the gitlinks from the root index, requires each
checked-out submodule to be clean and at that commit, and fingerprints those
gitlinks directly. It stores no expected Swift source commit in another file.
Every upstream repository that publishes the snapshot tag is pinned to the
commit named by `target-sdk-inputs.json`'s `snapshot`. A Nucleus fork starts at
that same tagged commit and adds only the required target-runtime patches. Host
tools, target libraries, Testing macros, and `libTesting` therefore share one
Swift snapshot ABI; moving a runtime repository independently is invalid even
when its branch remains named `release/6.4`.

The target build passes `SwiftTesting_MODULE_ABI_NAME_SUFFIX=_toolchain` so its
Testing module has the same `Testing_toolchain` ABI identity as the Testing
module bundled with the host toolchain. This is required even at the same
source revision: host-side macro expansion and Linux-side test execution must
refer to the same protocol metadata identity.

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
two artifact-bundle links through `~/.swiftpm/swift-sdks`. Unchanged external
inputs, Xcode identity, source graph, runtime-builder image, NDK, validation
fixture, and validator reuse the active immutable generation without rebuilding,
downloading, assembling, validating, or publishing it again.
Runtime build products and ccache live outside the source submodules and remain
reusable when a later source-addressed generation needs work. Runtime task identity
depends only on the runtime package subset, so changing an SDK-only package rebuilds
assembly and validation without rebuilding Swift.
