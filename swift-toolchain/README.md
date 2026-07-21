# swift-toolchain

Build script for the Swift 6.4.x toolchain with **libc++ baked in** as
the default C++ standard library. Produces a relocatable Linux tarball
suitable for the user-level Swift platform generations managed by Nucleus.

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
../tools/nucleus toolchain rebuild
```

That's it. Outputs:

* Active toolchain: `~/.cache/nucleus/swift-platforms/release-6.4.x/current/toolchain/usr/`
* Active Android SDK: `~/.cache/nucleus/swift-platforms/release-6.4.x/current/android/`
* Immutable generations: `~/.cache/nucleus/swift-platforms/release-6.4.x/generations/`

The canonical tarball is published only after its compiler and SwiftPM smoke
tests pass. Failed or interrupted builds discard their candidate and leave the
previous successful tarball unchanged.

The build never installs into that previous `usr/` tree. It assembles a fresh
candidate under the install root, verifies and packages that candidate, then
publishes both the tree and tarball. This prevents removed or disabled upstream
components from surviving in a later artifact as stale files.

The source build remains one upstream dependency graph, in this strict order:

1. LLVM, Clang, Swift, libc++, compiler-rt, and the Swift standard library.
2. Linux platform runtimes: libdispatch, Foundation, XCTest, and Swift Testing.
3. Developer tools: llbuild, SwiftPM, the final Swift driver, and macros.
4. Artifact assembly, package smoke tests, and publication.

Each successful artifact records fingerprints for those first three component
groups in `usr/share/nucleus/component-fingerprints.env`. The fingerprints bind
source revisions, the patch set, the host compiler, and the generated build
configuration. Build directories remain reusable when the identity is
unchanged. A changed compiler identity invalidates the Swift-built Linux
runtime and tool stages; a narrower tool-only change retains the compiler and
runtime stages. A changed CMake configuration automatically requests the full
reconfiguration that those untracked cache inputs require. The log reports
every identity transition and invalidation explicitly.

Phase events and measured durations are written to
`logs/latest-phases.tsv` and summarized when the build exits. This is the source
of truth for optimization work; the figures below are only orientation.

The first build compiles the complete graph. Incremental rebuilds reuse
`~/.cache/nucleus/swift-source/`; consult the recorded phase durations for the
actual cost of the current source and configuration.

### Flags

`../tools/nucleus toolchain rebuild --dry-run` prints every stage without running it.

`../tools/nucleus toolchain rebuild --reconfigure` forces CMake reconfigure for all Swift
build-script projects. Use after changing preset CMake cache values
such as `LLVM_TARGETS_TO_BUILD`.

Ordinary builds do not inherit upstream's `buildbot_linux` reconfiguration
flag. CMake and Ninja retain their incremental state unless this option is
passed explicitly or the last successful component manifest proves that the
generated CMake configuration changed.

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
../tools/nucleus toolchain rebuild
```

Outputs:

* Active pair: `~/.cache/nucleus/swift-platforms/release-6.4.x-macos/current/`
* Toolchain: `current/toolchain/usr/`
* Android SDK and build outputs: `current/android/`

The macOS tarball uses the same successful-build-only publication contract as
the Linux artifact.

Same `--dry-run` / `--reconfigure` flags and
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

[`patches/`](patches) currently contains **fourteen** patches across
`swift/`, `swift-driver/`, `swift-build/`, and `swiftpm/`. The build otherwise runs
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

* **`swift/0008-linux-futex-mutex-tsan.patch`** — annotates the Linux
  `Synchronization.Mutex` futex implementation with libswiftCore's
  ThreadSanitizer acquire/release hook pointers. The synchronization is correct
  without the hooks, but TSan cannot infer a happens-before edge from Swift
  atomics plus direct futex syscalls and otherwise reports false access races
  for correctly locked state. Runtime-populated nullable hooks preserve
  ordinary, non-TSan toolchain links without allowing the non-TSan stdlib build
  to fold the annotations out of `@_alwaysEmitIntoClient` bodies.
  *Filed-upstream-TODO.*

* **`swift/0009-preserve-generated-libcxx-headers.patch`** — preserves
  LLVM's generated libc++ header directory on incremental invocations. Upstream
  otherwise attempts to replace it with a system-header symlink on every run;
  deleting it first only worked because the old preset accidentally forced a
  complete CMake reconfigure. The patch makes the non-reconfigured path retain
  the libc++ configuration that the toolchain actually ships.

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

* **`swiftpm/0001-swift-build-propagate-cxx-interop-to-test-runners.patch`** —
  carries a test module's C++ interoperability mode into Swift Build's
  synthesized test runner, matching the native build planner and allowing the
  runner to import C++-interop test modules.

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

The workspace entry point selects the active paired generation through
`core/tools/host-env.sh`. Everything lives in the user's cache. No `/opt`
installation or elevated privileges are required.

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
nm --defined-only ~/.cache/nucleus/swift-platforms/release-6.4.x/current/toolchain/usr/lib/swift/linux/libswiftCxxStdlib.a \
  | grep -c "abi:cxx11"
# Expect: 0
```

If the count is non-zero, the toolchain accidentally linked libstdc++
somewhere and the CxxStdlib overlay needs to be rebuilt.
