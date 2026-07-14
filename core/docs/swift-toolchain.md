# Swift Toolchain

Nucleus uses Swift in the compositor build, but the Swift toolchain
itself is not built by the core component. The compositor binary links against
a source-built Swift 6.4 toolchain produced separately by
[`swift-toolchain`](../../swift-toolchain)
and installed under the user cache directory.

## The Toolchain

The development compiler is the source-built Swift 6.4 release-branch
toolchain with **libc++ baked in** as the default C++ standard library:

```text
release/6.4.x
```

The toolchain installs to:

```text
~/.cache/nucleus/swift-toolchains/release-6.4.x/usr
```

Nucleus host tooling prefers `/opt/nucleus-swift/current/usr`, then this
user-cache installation. Set `NUCLEUS_SWIFT_TOOLCHAIN=/path/to/toolchain/usr`
to select a different installed toolchain explicitly.

## Building the Toolchain

The toolchain build lives in a separate repo. See:

```
<monorepo-root>/swift-toolchain/
```

Build it from a plain Ubuntu shell:

```sh
cd <monorepo-root>/swift-toolchain
sudo apt install $(< apt-deps.txt)   # first time only
./build.sh
```

That produces a relocatable toolchain at the install path above plus a
distributable tarball alongside it. Wall-clock is ~4–6 hours for a
clean first build.

For a bootstrap swift-driver the build expects either swiftly's
`main-snapshot-*` toolchain on `PATH` or any working Swift 6.x
`swift-driver`. The repo's README covers the prerequisites.

## Responsibilities

The host operating system provides the JS/TS toolchain, Wayland/DRM headers,
Vulkan, fontconfig, React Native dependencies, and runtime libraries. Swift is
consumed from the externally-built toolchain selected by `tools/host-env.sh`.

SwiftPM owns the Nucleus build (see the **Build System** section of the
repo-root `CLAUDE.md`): `swift build` compiles the Swift/C/C++ package
graph, links the products, and drives cross-compilation through Swift
SDKs. There is no first-party Zig build.

## C++ Interop and the Toolchain's libc++

The interop rules — which modules may enable `.interoperabilityMode(.Cxx)`,
and how a non-cxx module reaches a cxx one through a `@convention(c)` /
protocol seam rather than importing it directly — are owned by the
**Build System** section of the repo-root `CLAUDE.md`. The
toolchain-specific fact that belongs here: this toolchain bakes in libc++
as the default C++ stdlib, so the `CxxStdlib` overlay binds to
`std::__1::basic_string` cleanly — which is what lets C++ types cross the
Swift boundary at all.

## Verify Nucleus Swift Integration

```sh
source tools/host-env.sh
swiftc --version
swift build
swift test -Xswiftc -cxx-interoperability-mode=default
```

`swift build` builds the package graph; `swift test` (with the cxx-interop
flag for the C++-interop test targets) runs the package tests. The first
command should report a Swift 6.4 toolchain from
`~/.cache/nucleus/swift-toolchains/release-6.4.x/usr/bin/swiftc`
unless `NUCLEUS_SWIFT_TOOLCHAIN` overrides it.

## Driver Contract

The source-built Swift 6.4 release-branch toolchain includes and uses
`swift-driver`. The deprecated legacy-driver warning is not expected:

```text
using (deprecated) legacy driver
```

If that warning appears again, treat it as a toolchain packaging
regression: confirm which `swiftc` is selected, confirm the selected
toolchain has `bin/swift-driver`, and fix the toolchain in
`swift-toolchain/build.sh` rather than teaching Nucleus build
steps to depend on the legacy driver.

## Known Historical Snapshot Issues

With the older `swift-DEVELOPMENT-SNAPSHOT-2026-04-28-a` bootstrap
toolchain, typed throws combined with noncopyable transaction wrappers
could trigger a Swift compiler SIL ownership verifier crash in test
code:

```text
Found outside of lifetime use?!
Found ownership error?!
```

The reproducing shape involved a `Transaction: ~Copyable`, an
`inout Transaction` typed-throws closure, and a typed `catch` in
XCTest. This is a compiler/toolchain crash, not a Nucleus runtime
failure. Treat it as historical evidence for the old snapshot, not a
current 6.4 release-branch constraint. When moving transaction tests
forward, retry the original typed-catch shape against the active 6.4
toolchain before preserving the old workaround.

## Updating the Toolchain

The toolchain ref lives in
`<monorepo-root>/swift-toolchain/build.sh` (default:
`release/6.4.x`). To move to a newer Swift release branch, update the
default there and rebuild. Nothing in the Nucleus repo needs to change
for a Swift toolchain bump unless the new toolchain version drops or
renames APIs that Nucleus's Swift code uses.
