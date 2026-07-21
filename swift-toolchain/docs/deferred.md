# Deferred work

Items intentionally left out of the current `release-6.4.x` toolchain
build. Each has a defined trigger and known shape.

## Editor LSP and indexer (sourcekit-lsp, indexstore-db)

Disabled via `sourcekit-lsp=0` and `indexstore-db=0` in the build
preset. Their build phase invokes `swift-frontend -interpret` on
`swift-foundation/Package.swift` via SwiftPM's `--multiroot-data-file`
SwiftBuild integration. That JIT path crashes in release/6.4.x:

```
JIT session error: Symbols not found: [ ... PackageDescription ... ]
Failed to materialize symbols: { ... }
Stack dump:
3. While running user code "/.../swift-foundation/Package.swift"
```

Followed by a secondary crash in `swift-backtrace`'s DWARF reader.
Reproduces with `env -i`, so it's not caused by anything we set;
appears to be an LLVM ORC JIT regression specific to that
`Package.swift`.

Nothing in nucleus's build depends on either product, so the
gap is editor-side only.

**Revisit shape:** spin up a `nucleus-swift-tools` repo that builds
the LSP products as standalone SwiftPM packages against the installed
toolchain. `swift build` uses llbuild (not SwiftBuild), bypassing the
JIT path entirely.

```
~/Developer/nucleus-swift-tools/
├── build.sh                     # ~100 lines
├── third-party/
│   ├── sourcekit-lsp/          # submodule
│   └── indexstore-db/          # submodule
```

The build.sh invokes `swift build -c release` against
`$NUCLEUS_SWIFT_TOOLCHAIN/usr/bin/swift`, then copies the resulting
binaries/libs into `<toolchain>/usr/bin/` and
`<toolchain>/usr/lib/swift/host/`. Initial commit pins are the same
commits release/6.4.x checked out at the time this toolchain was
built (`sourcekit-lsp` at 8464cf21, `indexstore-db` at 59ca7820).

**Revisit trigger:** when editor LSP becomes a friction point during
nucleus development, or before Nucleus OS ships a developer-facing
release.

## Additional CPU architectures

Toolchain currently builds for `x86_64-unknown-linux-gnu` only.

**ARM64 (aarch64):** one config change. Change
`--stdlib-deployment-targets=linux-x86_64` to `linux-aarch64` (or
both) in the build invocation, run `./build.sh` on an aarch64 host.
The build script needs no other changes. Output is a separate
artifact: `swift-release-6.4.x-linux-aarch64.tar.gz`.

Required for:
* Apple Silicon Macs running Linux VMs
* AWS Graviton compute
* Raspberry Pi / Ampere Altra

**32-bit x86 / armv7:** modern Swift doesn't support these. Not on
the roadmap.

**POWER / RISC-V:** niche. Defer until/unless demand emerges; Swift's
own support for these is patchy.

**Revisit trigger:** when shipping Nucleus OS to a non-x86_64 device
class.

## Broader glibc compatibility

Built against Ubuntu 26.04 LTS's glibc 2.43. `libswiftCore.so` and
friends require `GLIBC_2.43`, so the binaries run on:

* Ubuntu 26.04+ (Nucleus OS base)
* Fedora 42+
* Arch (rolling, current)

They do **not** run on Ubuntu 24.04 LTS, Debian 12/13, RHEL 9/10,
older Fedora, or anything with glibc < 2.43.

**Revisit shape:** add a CI workflow that runs `./build.sh` inside a
container based on the oldest distro we want to support — typically
the oldest still-supported Ubuntu LTS. The resulting binary runs on
that distro and everything newer.

Build script needs no changes; the build *host* changes.

Apple's swift.org Linux releases use this pattern, currently building
on Ubuntu 20.04 (glibc 2.31) for broadest compatibility.

**Revisit trigger:** when distributing the toolchain to non-Nucleus-OS
users.

## Upstreaming `swift/0001-clangimporter-libcxx-cxxstdlib.patch`

The Swift patch in `patches/swift/0001-clangimporter-libcxx-cxxstdlib.patch`
is a candidate for filing as a swiftlang/swift PR. Currently swift's
`CxxStdlib` Linux build is hardcoded for libstdc++; the patch makes
it work with libc++ when `CLANG_DEFAULT_CXX_STDLIB=libc++` is set on
the toolchain. It also adds an Android ClangImporter guard for NDK 30
libc++'s textual `wchar.h` overload shims.

**Revisit shape:**
* Open a swiftlang/swift PR against `main` and `release/6.4.x`.
* Add tests that exercise the libc++ Linux path and Android `CxxStdlib`
  import path so the gates do not regress.
* Once upstreamed, drop the local patch.

The patch logic is small (~48 lines added in `ClangImporter.cpp`)
and targeted enough to plausibly land. The maintainer review will
likely ask for the libc++ paths to come from clang's driver via a
proper API instead of computed-from-resource-dir, and may prefer a
more targeted Android condition for the `wchar.h` guard; refactor as needed.

**Revisit trigger:** stable release of the toolchain on Nucleus OS,
plus a tested CI matrix proving the libc++ path. Filing too early
risks the patch being rejected for lack of supporting tests.

## Upstreaming `swift-driver/0001-android-swiftrt-resource-dir-fallback.patch`

The Swift driver patch in
`patches/swift-driver/0001-android-swiftrt-resource-dir-fallback.patch`
is a candidate for a swiftlang/swift-driver PR. It keeps Android cross
builds from requiring Swift runtime objects inside the NDK sysroot:
when `-sdk` points at the Android NDK and the SDK `swiftrt.o` is absent,
the driver falls back to the explicit Swift resource dir.

**Revisit shape:**
* Add a driver test for an Android target with both `-sdk` and
  `-resource-dir`, where only the resource dir contains `swiftrt.o`.
* Confirm the SDK-first behavior remains unchanged for non-Android
  targets and for Android SDKs that do contain Swift runtime objects.
* Once upstreamed, drop the local patch.

**Revisit trigger:** after the Android SDK build is stable enough that
the driver behavior can be validated in CI.

## Smoke test coverage

Current smoke test:
1. Extract tarball
2. `swift --version`
3. `swiftc /tmp/main.swift -o /tmp/main` (no imports)
4. `swift package init --type executable` + `swift build`

That verifies the binary runs and SwiftPM works against the extracted
toolchain. It does **not** verify the actual reason this toolchain
exists: libc++-flavored CxxStdlib.

**Revisit shape:** extend the smoke test to:

```swift
import CxxStdlib
import Foundation
let s = std.string("libc++ roundtrip")
precondition(String(s) == "libc++ roundtrip")
```

Plus a check via `nm` that the installed CxxStdlib library binds to
`std::__1::` (libc++'s inline namespace) and contains zero
`std::__cxx11::` references (libstdc++'s).

```sh
nm --defined-only "$toolchain/usr/lib/swift_static/linux/libswiftCxxStdlib.a" \
  | grep -c "std::__1::basic_string"   # > 0
nm --defined-only "$toolchain/usr/lib/swift_static/linux/libswiftCxxStdlib.a" \
  | grep -c "abi:cxx11"                # == 0
```

If either fails, the toolchain accidentally fell back to libstdc++
and the alignment work was for nothing. Smoke test should catch that.

**Revisit trigger:** before relying on this toolchain for production
nucleus builds, or before shipping a `.deb`.

## Nucleus OS `.deb` packaging

Toolchain produces a relocatable tarball today; not yet wrapped as a
Debian package.

**Revisit shape:** add `debian/` directory with `control`, `rules`,
`changelog`, `copyright`. The toolchain layout is already
relocatable and uses `$ORIGIN`-relative rpaths plus `<CFGDIR>`-relative
clang config, so the package is structurally a thin wrapper around
the existing tarball.

Eventual packages on Nucleus OS:
* `swift-toolchain` — compiler + stdlib + CxxStdlib + Foundation + libdispatch + xctest
* `nucleus-swift-tools` (if/when the LSP split happens) — sourcekit-lsp + indexstore-db
* `nucleus-swift-runtime` (if/when the runtime split happens) — Foundation/libdispatch as standalone packages

**Revisit trigger:** Nucleus OS ships a first-party package
repository.
