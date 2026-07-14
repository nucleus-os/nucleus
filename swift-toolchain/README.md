# swift-toolchain

Build script for the Swift 6.4.x toolchain with **libc++ baked in** as
the default C++ standard library. Produces a relocatable Linux tarball
suitable for installing into `~/.cache/nucleus/swift-toolchains/` for
local Nucleus development and eventually packaging as a `.deb` for
Nucleus OS.

## Why this is a separate component

Swift's source build assumes a consistent Linux compiler/libc environment.
This component builds directly on the Ubuntu host that matches the actual ship
target (Nucleus OS, Ubuntu-based) and produces an artifact Nucleus consumes. Its source
lives in the monorepo while its long-running build and release lifecycle remains explicit.

The toolchain itself is libc++-flavored end-to-end: Swift's `CxxStdlib`
overlay binds to `std::__1::basic_string`, the build's clang defaults
to `-stdlib=libc++`, and `libswiftCore.so` and friends link libc++
internally.

## Prerequisites

Ubuntu 24.04 LTS or newer. Install the apt packages listed in
[`apt-deps.txt`](apt-deps.txt):

```sh
sudo apt update
sudo apt install $(< apt-deps.txt)
```

A bootstrap `swift-driver` must be available on `PATH` for the early
compiler bootstrap stage. Two options:

* **swiftly** (recommended for development):
  ```sh
  curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
  tar zxf swiftly-$(uname -m).tar.gz
  ./swiftly init --no-modify-profile
  ~/.local/share/swiftly/bin/swiftly install main-snapshot
  ```
* **swift.org tarball** for a recent release (any 6.x development
  snapshot works).

The build script auto-detects whichever `swift-driver` is first on
`PATH` and excludes the install root we're about to overwrite.

When `/opt/nucleus-swift/current/usr` exists, its matching `clang` and
`clang++` are used for the host build so Swift-in-Swift compiler modules and
the native LLVM/Swift libraries share the bootstrap toolchain's libc++ ABI.
Set `NUCLEUS_SWIFT_BOOTSTRAP_ROOT`, or both `NUCLEUS_HOST_CC` and
`NUCLEUS_HOST_CXX`, to select a different coherent bootstrap toolchain.

## Build

```sh
./build.sh
```

That's it. Outputs:

* Toolchain install: `~/.cache/nucleus/swift-toolchains/release-6.4.x/usr/`
* Distributable tarball: `~/.cache/nucleus/swift-toolchains/release-6.4.x/swift-release-6.4.x-linux.tar.gz`
* Build log: `~/.cache/nucleus/swift-toolchains/release-6.4.x/logs/latest.log`

The canonical tarball is published only after its compiler and SwiftPM smoke
tests pass. Failed or interrupted builds discard their candidate and leave the
previous successful tarball unchanged.

Wall-clock on a 32-core machine: roughly 4–6 hours for the first
build. Incremental rebuilds reuse `~/.cache/nucleus/swift-source/`.

### Flags

`./build.sh --dry-run` prints the command line without running it.

`./build.sh --skip-checkout` reuses the existing
`~/.cache/nucleus/swift-source/release-6.4.x/` checkout. Useful when
iterating on the patch set.

`./build.sh --reconfigure` forces CMake reconfigure for all Swift
build-script projects. Use after changing preset CMake cache values
such as `LLVM_TARGETS_TO_BUILD`.

### Environment variables

The script accepts the variables listed in `./build.sh --help`. The
most useful ones:

* `NUCLEUS_SWIFT_BUILD_JOBS` — parallel build jobs. Default: `$(nproc)`.
* `NUCLEUS_SWIFT_SOURCE_INSTALL` — where to install. Default: under
  `~/.cache/nucleus/swift-toolchains/`.
* `NUCLEUS_SWIFT_SOURCE_BOOTSTRAP_DRIVER_BIN` — explicit path to a
  bootstrap swift-driver binary's directory. Auto-detected if unset.
* `NUCLEUS_SWIFT_PATCHES_DIR` — path to the `patches/` tree. Defaults
  to the script's sibling directory.

## macOS (Apple Silicon)

`build-macos.sh` builds the same pinned Swift source ref natively for
macOS, producing a `swift-release-6.4.x-macos-arm64.tar.gz`. It's a
separate script from `build.sh`, not a flag, because the Linux build's
entire reason for existing — baking libc++ in via
`LLVM_ENABLE_RUNTIMES` plus ELF rpath/symlink/`patchelf` plumbing — is
moot on Darwin: macOS already ships libc++ as the system C++ library,
and Swift's build-script has first-class Darwin support. Swift's own
`foundation`/`libdispatch` preset build steps (swift-corelibs, for
Linux/Windows portability) are skipped too — Darwin links the
OS-provided `Foundation.framework` / `libdispatch.dylib` instead. All
patches under `patches/` are applied here too, same as on Linux —
`swift/0002`-`0007` specifically target cross-compiling to Android
*from* this macOS build host (used by the sibling
`swift-android-sdk/` component's `build-macos.sh`, which reuses
this build's workspace); the rest are inert no-ops when only compiling
for Darwin targets. See "Patches" below.

### Prerequisites

**Full Xcode.app**, not just Command Line Tools — the build-script's
configure/test steps need more than CLT provides. Install it from the
App Store or developer.apple.com, then:

```sh
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

Homebrew for the rest:

```sh
brew install cmake ninja ccache
```

### Build

```sh
./build-macos.sh
```

Outputs:

* Toolchain install: `~/.cache/nucleus/swift-toolchains/release-6.4.x-macos/usr/`
* Distributable tarball: `~/.cache/nucleus/swift-toolchains/release-6.4.x-macos/swift-release-6.4.x-macos-arm64.tar.gz`
* Build log: `~/.cache/nucleus/swift-toolchains/release-6.4.x-macos/logs/latest.log`

The macOS tarball uses the same successful-build-only publication contract as
the Linux artifact.

Same `--dry-run` / `--skip-checkout` / `--reconfigure` flags and
`NUCLEUS_SWIFT_SOURCE_*` / `NUCLEUS_SWIFT_BUILD_JOBS` environment
variables as `build.sh` (see `./build-macos.sh --help`). The source
checkout and build tree live under a `-macos`-suffixed workspace,
kept separate from the Linux one so a machine that builds both
platforms never lets one platform's build tree or patches bleed into
the other's.

The macOS build skips `lldb`, `sourcekit-lsp`, and `indexstore-db` by
default, mirroring the Linux build's choices — flip them on in
`nucleus_buildbot_macos,no_test` inside `build-macos.sh` if you need
them locally.

## Patches

[`patches/`](patches) currently contains **eleven** patches across
`swift/`, `swift-driver/`, and `swift-build/`. The build otherwise runs
against upstream `release/6.4.x` unmodified. See
[`patches/README.md`](patches/README.md) for the file format and
authoring guide.

### Active patches

* **`swift/0001-clangimporter-libcxx-cxxstdlib.patch`** — Swift's `CxxStdlib`
  stdlib build on Linux is wired up only for libstdc++; the libc++
  path is gated behind Android/musl-static/macOS configurations. Our
  build uses libc++ on standard Linux (Ubuntu) via
  `CLANG_DEFAULT_CXX_STDLIB=libc++`, so the patch injects libc++'s
  include path into Swift's internal ClangImporter invocations when
  `LangOpts.CXXStdlib == Libcxx`. The same patch also defines libc++'s
  `wchar.h` overload guard for Android importer invocations, avoiding
  duplicate `wmemchr`/wide-string overload shims with NDK 30 while
  leaving the installed NDK untouched. *Filed-upstream-TODO.*

* **`swift/0002`-`0007`** — six patches fixing cross-compiling to
  Android *from a Darwin (macOS) build host*, a combination upstream
  Swift has never really exercised: stray Darwin-only compiler/linker
  flags (`-arch`, `-Wl,-dead_strip`) leaking into Android compiles
  because several CMake guards check `CMAKE_SYSTEM_NAME MATCHES
  Darwin` without also checking the *target* SDK is Apple
  (`0002`/`0003`); Swift-language CMake support silently naming
  cross-compiled shared libraries `.dylib` instead of `.so` (`0003`);
  an empty `LIBDISPATCH_RUNTIME_DIR` breaking libdispatch's install
  step (`0004`); a Darwin-only stdlib test module
  (`StdlibUnittestFoundationExtras`) missing a `TARGET_SDKS`
  restriction and being attempted on Android (`0005`); the same
  libc++ `wchar.h` workaround as `0001`, forwarded via `-Xcc` for the
  `CxxStdlib` stdlib build itself rather than the ClangImporter
  (`0006`); and a genuine bug mapping Swift's own host-target name
  (e.g. `macosx-arm64`) onto the NDK's prebuilt-clang directory tag
  instead of the NDK's own `darwin-x86_64` convention (`0007`). See
  each patch's own header for the full rationale. *Filed-upstream-TODO.*

* **`swift-driver/0001-android-swiftrt-resource-dir-fallback.patch`** —
  Swift's new driver prefers `swiftrt.o` from `-sdk` when an SDK is
  present. Android builds pass the NDK sysroot as `-sdk`, and the NDK
  intentionally does not contain Swift runtime objects. This patch falls
  back to the explicit Swift resource dir for Android when the SDK copy
  is absent, so libdispatch/Foundation can build without patching the
  NDK. *Filed-upstream-TODO.*

* **`swift-build/0001-android-preserve-swift-sdk-toolsets.patch`** —
  Swift Build's Android platform plugin was discarding Swift SDK
  toolsets, which dropped Android artifactbundle options such as
  `-tools-directory`. This preserves toolset paths and forwards
  Swift-driver options so SwiftPM's SwiftBuild path matches the native
  SwiftPM behavior for our BYO-NDK Android SDK. *Filed-upstream-TODO.*

* **`swift-build/0002-dont-static-link-stdlib-into-macro-plugins.patch`** —
  `--static-swift-stdlib` statically linked the Swift stdlib into macro
  plugin products too, which are `dlopen`'d by `swift-plugin-server`
  (already dynamically linked against the runtime); the second embedded
  runtime made plugins fail to vend their macros at load time. Gates on
  `SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES` to always link macro
  plugins dynamically while target products keep honoring the static
  flag. *Filed-upstream-TODO.*

* **`swift-build/0003-android-tools-directory-from-ndk.patch`** — swiftc
  falls back to the host clang as its Android link driver whenever
  `-tools-directory` doesn't resolve to a directory containing a clang,
  dragging host x86_64 `libc++`/`libunwind` onto the aarch64 link. The
  Android Swift SDK only supplied `-tools-directory` indirectly via the
  bundle's `swift-toolset.json` `rootPath`, which is empty until a
  post-install setup step runs. This derives `-tools-directory` directly
  from the NDK the platform plugin already discovered, so correctness no
  longer depends on that setup step. *Filed-upstream-TODO.*

### Candidates for re-adding if upstream regresses

Held in git history rather than carried as files. Three additional
patches were dropped after the migration when they turned out to be
unnecessary on system Ubuntu:

* **Bootstrap early-swiftdriver workaround** — needed only if the
  source-built early driver crashes (true on some main-branch
  development snapshots; not currently true on `release/6.4.x`).

* **SwiftPM bootstrap workers cap** — bounds SwiftPM's self-hosted
  build stage to fewer than ProcessorCount workers. Preference, not
  correctness.

* **Post-install toolchain pinning** — ensures indexstore-db and
  sourcekit-lsp's post-install SwiftPM builds use the just-installed
  source toolchain even when other Swifts (swiftly's bootstrap) are
  on `PATH`. Defensive; only matters with multiple toolchains
  visible.

If the build fails at any of those stages, the relevant patch can be
recovered from the monorepo's Git history.

## Consuming the toolchain

### From Nucleus development

Install the toolchain at `/opt/nucleus-swift/current/usr`, set
`NUCLEUS_SWIFT_TOOLCHAIN` to its `usr` directory, or keep it at the default
`~/.cache/nucleus/swift-toolchains/release-6.4.x/usr` path. The workspace entry
point selects it through `core/tools/host-env.sh`.

### From a tarball

```sh
sudo tar -x -z -f swift-release-6.4.x-linux.tar.gz -C /opt/nucleus-swift
export PATH=/opt/nucleus-swift/usr/bin:$PATH
swift --version
```

### Future: Nucleus OS `.deb`

Wrapping the tarball in a Debian package will land here under
`debian/`. The toolchain layout is already relocatable and uses
`$ORIGIN`-relative rpaths, so the `.deb` is a thin wrapper.

## Layout

```
swift-toolchain/
├── README.md           # this file
├── build.sh            # Ubuntu/Linux build script
├── build-macos.sh      # macOS (Apple Silicon) build script
├── apt-deps.txt        # pinned Ubuntu package list
├── docs/
│   └── deferred.md     # work intentionally not in the current build
└── patches/            # source patches applied during build
    ├── README.md
    ├── swift/
    ├── swift-driver/
    ├── swift-build/
    ├── swiftpm/
    ├── indexstore-db/
    └── sourcekit-lsp/
```

## Deferred work

See [`docs/deferred.md`](docs/deferred.md) for items intentionally
not in the current build: editor LSP tooling, runtime library split,
additional CPU architectures, broader glibc compatibility,
upstreaming the libc++ patch, smoke test extensions, and `.deb`
packaging.

## Verifying libc++ alignment

After the build, the toolchain's `CxxStdlib` overlay should bind to
`std::__1::basic_string` (libc++'s inline namespace) rather than
libstdc++'s `std::__cxx11::basic_string`. Quick check:

```sh
nm --defined-only ~/.cache/nucleus/swift-toolchains/release-6.4.x/usr/lib/swift/linux/libswiftCxxStdlib.a \
  | grep -c "abi:cxx11"
# Expect: 0
```

If the count is non-zero, the toolchain accidentally linked libstdc++
somewhere and the CxxStdlib overlay needs to be rebuilt.
