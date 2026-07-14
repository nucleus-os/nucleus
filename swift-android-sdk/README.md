# swift-android-sdk

Build script for the Swift Android SDK against the locally-built
`swift-toolchain`. Produces a Swift SDK artifactbundle (the
`swift sdk install`-able tarball format) targeting
`aarch64-unknown-linux-android` at API level 36 (Android 16,
"Baklava").

API 36 is the highest the current NDK 30 beta1 supports — see
`$ANDROID_NDK_HOME/meta/platforms.json`. Binaries built at API 36
run forward-compatibly on Android 17 (API 37) and beyond, so this
is the practical floor for "Android 17 target" today. Lift to 37
once the NDK publishes API-37 platform stubs (see
[`docs/deferred.md`](docs/deferred.md)).

`x86_64-unknown-linux-android` is supported but opt-in via
`--arch x86_64`; it's only useful for x86 Android emulators. Every
modern physical Android device is aarch64.

## Why this is separate from the host toolchain build

The host toolchain (`~/.cache/nucleus/swift-toolchains/release-6.4.x/`)
is x86_64-linux only. Cross-compiling Swift code to Android requires a
matching Android stdlib + Foundation + dispatch built with the same
compiler version. Bundling that into the toolchain build would
double its wall-clock time and conflate two independent concerns:
"what runs the Swift compiler" vs. "what the Swift compiler emits
when targeting Android".

Both builders live in the Nucleus monorepo, but remain separate components because
the Android SDK is an optional, long-running cross-build artifact rather than a
prerequisite of every host build. See `../swift-toolchain/docs/deferred.md`.

## Bundle layout

Mirrors swift.org's **official 6.3.2 Android bundle**: BYO-NDK. The
artifactbundle ships an empty `ndk-sysroot/` plus a private
`scripts/setup-android-sdk.sh` implementation that the Nucleus installer
invokes automatically. The installed bundle links to the consumer's NDK
sysroot; no NDK sysroot is shipped in the artifact.

This is the pattern the Swift project owns going forward
([finagolfin's self-contained approach](https://github.com/finagolfin/swift-android-sdk)
is being wound down). Aligning with the official layout means our
bundle is structurally identical to what `swift sdk install` from
swift.org would land — consumers get the same workflow regardless
of which bundle they install.

Bundle contents:

* `info.json`, `swift-android/swift-sdk.json`, `swift-android/swift-toolset.json`
* `swift-android/swift-resources/usr/lib/swift-aarch64/` — dynamic stdlib + Foundation + libdispatch + XCTest + swift-testing
* `swift-android/swift-resources/usr/lib/swift_static-aarch64/` — static counterparts + Foundation C deps (libcurl, openssl, libxml2 …) as static archives
* `swift-android/swift-resources/usr/{include,share,lib/cmake,lib/pkgconfig}` — arch-shared
* `swift-android/scripts/setup-android-sdk.sh` — bundle-internal NDK wiring used by the installer
* `swift-android/ndk-sysroot/` — empty until installation wires the selected NDK

Bundle size: ~300-400 MB compressed.

The self-contained alternative remains a possible future variant —
see [`docs/deferred.md`](docs/deferred.md) "Alternate
self-contained layout".

## Foundation C dependencies (libcurl, openssl, libxml2, …)

Foundation's networking and XML modules link against several C
libraries that Android doesn't ship. We cross-build them from
pinned upstream sources against NDK 30 / API 36; recipes under
[`third-party/deps/recipes/`](third-party/deps/recipes).

Dep graph:
* `libcurl` (FoundationNetworking) → `openssl`, `zlib`, `nghttp2`
* `libxml2` (FoundationXML) → `liblzma`, `libiconv`

Feature set is Apple's swift.org Android bundle baseline plus
HTTP/2 (via nghttp2 — Apple's bundle omits it but most modern HTTP
endpoints negotiate HTTP/2 by default). Excluded: HTTP/3, SCP/SFTP,
IDN, PSL.

Recipes are invoked from `build.sh`'s `build_deps_for_arch` before
`build_one_arch` runs, so Foundation's `find_package(CURL)` /
`find_package(LibXml2)` resolve against the freshly-built `.a`
files. Each recipe is idempotent — re-running `./build.sh` after
a successful deps run skips them via per-recipe sentinel files
under `$STAGING/.deps-built/`.

## libc++ alignment

This SDK is naturally libc++-flavored end-to-end without any patches:
the Android NDK has shipped libc++ exclusively for years, and Swift's
Android stdlib build already binds `CxxStdlib` to libc++. The
`patches/swift/0001-libcxx-linux-cxxstdlib.patch` carried in
`swift-toolchain` only affects the *host* Linux build path; it
does not need a counterpart here.

The smoke test below still asserts `std::__1::` (libc++) symbols in
the produced Android `libswiftCore.so` so a future upstream regression
that silently switches Android to libstdc++ would fail loudly.

## Prerequisites

* `swift-toolchain` built and installed at
  `$NUCLEUS_SWIFT_TOOLCHAIN` (default
  `~/.cache/nucleus/swift-toolchains/release-6.4.x/usr`). This script
  refuses to run if the toolchain is missing; it does not auto-build
  it.
* The Swift source workspace at `$NUCLEUS_SWIFT_SOURCE_WORKSPACE`
  (default `~/.cache/nucleus/swift-source/release-6.4.x`). Reuses the
  checkout that produced the host toolchain — same commits, same
  patches applied.
* Ubuntu 26.04+ (matches `swift-toolchain`'s build host).
* Apt packages from [`apt-deps.txt`](apt-deps.txt) on top of
  `swift-toolchain/apt-deps.txt`:

  ```sh
  sudo apt update
  sudo apt install $(< apt-deps.txt)
  ```

## Build

```sh
../tools/nucleus android sdk build
```

Outputs:

* Per-arch destdirs: `~/.cache/nucleus/swift-android-sdks/release-6.4.x/build/install-<arch>/`
* Artifactbundle: `~/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle.tar.gz`
* SHA-256 sidecar: `…artifactbundle.tar.gz.sha256`
* Build log: `~/.cache/nucleus/swift-android-sdks/release-6.4.x/logs/latest.log`

The NDK is **not** downloaded by default — the script reuses the
AGP-managed NDK 30 already installed via `sdkmanager` at
`~/Android/Sdk/ndk/30.0.14904198/`. See the "NDK selection" section
below.

Wall-clock on a 32-core machine: roughly 2-3 hours for the first
single-arch build. Subsequent runs reuse ccache and finish in
10-20 minutes if only Foundation/dispatch changed. Adding x86_64
roughly doubles the first-build time.

### NDK selection

Default: `~/Android/Sdk/ndk/30.0.14904198/` — the AGP-managed NDK 30
installed via `sdkmanager`. Unified NDK across Swift Android SDK and
AGP/Kotlin native builds.

This is **newer than the Swift Android workgroup's tested baseline
(r27d)**. The combo is not officially supported but expected to work
on `release/6.4.x` — see `docs/deferred.md` for the rationale. If a
build breaks specifically on r30 paths, capture the failure as a
`swift-toolchain/patches/swift/` patch rather than downgrading;
the goal is to keep one NDK on the machine.

Fallback to r27d:

```sh
unset NUCLEUS_ANDROID_NDK_HOME
NUCLEUS_ANDROID_NDK_VERSION=r27d ../tools/nucleus android sdk build
```

This fetches r27d from `dl.google.com` and caches it under
`~/.cache/nucleus/android-ndk/r27d/`.

### Flags

`../tools/nucleus android sdk build --dry-run` prints the command lines without running them.

`../tools/nucleus android sdk build --skip-ndk` skips even the existence check on the
configured NDK path. Use when you've installed the NDK in a
non-standard location and the default heuristics misfire.

`../tools/nucleus android sdk build --arch x86_64` (repeatable) opts in to additional
arches. Default is aarch64 only.

`../tools/nucleus android sdk build --skip-package` runs the cross-builds but stops before
assembling the artifactbundle. Useful when iterating on the build
itself.

### Environment variables

* `NUCLEUS_SWIFT_TOOLCHAIN` — host toolchain root (the dir containing
  `bin/swift`). Default:
  `~/.cache/nucleus/swift-toolchains/release-6.4.x/usr`.
* `NUCLEUS_SWIFT_SOURCE_WORKSPACE` — source workspace produced by
  `swift-toolchain`. Default:
  `~/.cache/nucleus/swift-source/release-6.4.x`.
* `NUCLEUS_ANDROID_NDK_HOME` — explicit NDK path. If unset, the
  script downloads NDK r27d into the cache.
* `NUCLEUS_ANDROID_API_LEVEL` — `--android-api-level` passed to
  `build-script`. Default: `36`. This is the *minimum* runtime Android
  version the produced stdlib targets; output binaries still run on
  Android 17 / API 37 (and onward).
* `NUCLEUS_SWIFT_ANDROID_BUILD_JOBS` — parallel build jobs. Default:
  `$(nproc)`.
* `NUCLEUS_SWIFT_ANDROID_INSTALL` — output root. Default:
  `~/.cache/nucleus/swift-android-sdks/release-6.4.x`.

## macOS (Apple Silicon)

`build-macos.sh` builds this same Swift Android SDK on a Mac, against
the sibling `swift-toolchain/build-macos.sh`'s host toolchain
and source workspace. It's a separate script from `build.sh`, not a
flag, mirroring the pattern in `swift-toolchain`: the
cross-compile-to-Android work itself (NDK clang, `build-script
--android` flags) is host-OS-agnostic, but every path that assumes a
Linux *build host* — the NDK's `linux-x86_64` prebuilt-clang
directory, `~/Android/Sdk`, `nproc`, apt packages, the Debian ccache
PATH-shim — needs a macOS counterpart.

No Android Studio is required or used anywhere in this path — the NDK
is installed standalone via the command-line `sdkmanager`.

### Prerequisites

**`swift-toolchain/build-macos.sh` already built.** This
script refuses to run without it — it reuses that build's host
toolchain (`~/.cache/nucleus/swift-toolchains/release-6.4.x-macos/usr`)
and Swift source workspace
(`~/.cache/nucleus/swift-source/release-6.4.x-macos`) rather than
doing its own checkout, so Xcode.app is already required transitively
(see that repo's README) and does not need separate setup here.

Homebrew, for the tools this script itself uses:

```sh
brew install cmake ccache coreutils curl unzip
```

`coreutils` provides `gsha256sum`; symlink it so `sha256sum` is on
`PATH` (`ln -s "$(brew --prefix coreutils)/libexec/gnubin/gsha256sum"
/opt/homebrew/bin/sha256sum`, or add coreutils' `gnubin` to `PATH`).

**JDK**, for `sdkmanager` (the Android cmdline-tools are Java-based):

```sh
brew install openjdk
```

**Android cmdline-tools**, standalone — no Android Studio. Download
the macOS "Command line tools only" zip from
[developer.android.com/studio#command-tools](https://developer.android.com/studio#command-tools),
then lay it out under the same `~/Library/Android/sdk` path
`build-macos.sh` expects (the zip extracts to a bare `cmdline-tools/`
directory; sdkmanager requires it to be nested one level deeper, under
`latest/`):

```sh
mkdir -p ~/Library/Android/sdk/cmdline-tools
unzip ~/Downloads/commandlinetools-mac-*.zip -d /tmp/android-cmdline-tools
mv /tmp/android-cmdline-tools/cmdline-tools ~/Library/Android/sdk/cmdline-tools/latest
```

**NDK 30**, via `sdkmanager` (matches the AGP-managed version
`build.sh` uses on Linux — see "NDK selection" above; the numeric
30.0.14904198 revision is only distributed through `sdkmanager`, not as
a plain zip):

```sh
export JAVA_HOME="$(brew --prefix openjdk)/libexec/openjdk.jdk/Contents/Home"
yes | ~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager --licenses
~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager --channel=3 "ndk;30.0.14904198"
```

### Build

```sh
./build-macos.sh
```

Outputs (parallel to the Linux build's, under a `-macos`-suffixed
namespace so a machine building both platforms never collides):

* Per-arch destdirs: `~/.cache/nucleus/swift-android-sdks/release-6.4.x-macos/build/install-<arch>/`
* Artifactbundle: `~/.cache/nucleus/swift-android-sdks/release-6.4.x-macos/swift-release-6.4.x-macos_android.artifactbundle.tar.gz`
* SHA-256 sidecar: `…artifactbundle.tar.gz.sha256`
* Build log: `~/.cache/nucleus/swift-android-sdks/release-6.4.x-macos/logs/latest.log`

Same `--dry-run` / `--skip-ndk` / `--skip-package` / `--reconfigure` /
`--arch` flags as `build.sh` (see `./build-macos.sh --help`). The NDK
path defaults to `~/Library/Android/sdk/ndk/30.0.14904198` (override
with `NUCLEUS_ANDROID_NDK_HOME`); `NUCLEUS_SWIFT_TOOLCHAIN` and
`NUCLEUS_SWIFT_SOURCE_WORKSPACE` default to the macOS toolchain
build's own output paths.

Building this on macOS surfaced several bugs in Swift's own build
system that only manifest when *cross-compiling to a non-Apple SDK
from a Darwin build host* (a scenario the upstream Swift project has
never really exercised) — stray Darwin-only compiler/linker flags
leaking into Android compiles, Swift-language CMake support silently
naming shared libraries `.dylib` instead of `.so`, an NDK-toolchain
host-tag mix-up, and the Android `libdispatch` build path missing a
bare `--libdispatch` flag (mirroring the missing bare `--foundation`
flag fixed earlier in this same script). All of the CMake/Python-level
fixes are captured as patches under
`swift-toolchain/patches/swift/0002`-`0007` and applied
automatically by that repo's `build-macos.sh` before this script reuses
its workspace — see that repo's `patches/README.md`.

## Consuming the SDK

### From the local cache

Use the one-step installer — it runs `swift sdk install` **and** wires the
bundle to your local NDK in a single command:

```sh
../tools/nucleus android sdk install
```

NDK selection is shared by build, install, and test. It checks
`NUCLEUS_ANDROID_NDK_HOME`, then `ANDROID_NDK_HOME`, then the standard NDK 30
installation path for the host OS.

This is the recommended path. The two steps must not be split: a bare
`swift sdk install` leaves the bundle NDK-agnostic (empty `ndk-sysroot/` and
`ndk-toolchain/bin/`), which makes the swift driver fall back to the host
clang as the link driver and leak host x86_64 `libc++`/`libunwind` onto
Android links. `install-sdk.sh` always runs `setup-android-sdk.sh` so the SDK
is never left half-installed.

<details>
<summary>Manual equivalent</summary>

```sh
swift sdk install \
  ~/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle.tar.gz \
  --checksum "$(cat ~/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle.tar.gz.sha256)"

export ANDROID_NDK_HOME=~/Android/Sdk/ndk/30.0.14904198
~/.swiftpm/swift-sdks/swift-release-6.4.x_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
```
</details>

Verify:

```sh
swift sdk list   # should show swift-release-6.4.x_android
```

### End-to-end consumer check

After building the sibling `swift-toolchain` with its Swift
Build Android Swift SDK patch, run:

```sh
../tools/nucleus android sdk test
```

The script leaves the installed SDK untouched, creates a temporary executable package that
imports `Foundation` and `FoundationNetworking`, builds it with
`--swift-sdk aarch64-unknown-linux-android36 --static-swift-stdlib`, and
verifies the output is an AArch64 ELF.

### Cross-compiling a project

```sh
swift build --swift-sdk aarch64-unknown-linux-android36 --static-swift-stdlib
adb push .build/aarch64-unknown-linux-android36/debug/hello /data/local/tmp/
adb shell /data/local/tmp/hello
```

`libc++_shared.so` from the NDK must be pushed alongside the binary
(Swift dynamically links the NDK's C++ runtime):

```sh
adb push "$NUCLEUS_ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /data/local/tmp/
```

## Patches

This component carries no patches. The Android build path in Swift upstream
is already libc++-flavored and does not need the `CxxStdlib` adjustment
carried by `swift-toolchain`. Consumer builds with Swift 6.4's
default `swiftbuild` build system do rely on the sibling toolchain's
Swift Build patch that preserves Android Swift SDK toolsets and maps
their `rootPath` to `-tools-directory`.

Any Swift *source* patch needed for the Android build (host or target)
lives in `swift-toolchain/patches/` — both repos build from the
same `release/6.4.x` source workspace, so there is no separate patch
state here.

## Layout

```
swift-android-sdk/
├── README.md           # this file
├── build.sh            # main build + package script
├── apt-deps.txt        # additional apt packages (on top of toolchain's)
├── scripts/            # installed bundle setup + local e2e consumer test
└── docs/
    └── deferred.md     # work intentionally not in the current build
```

## Verifying libc++ alignment

After the build, the Android stdlib should still bind to libc++:

```sh
SDK=~/.cache/nucleus/swift-android-sdks/release-6.4.x/build/install-aarch64
nm --defined-only --dynamic "$SDK/usr/lib/swift/android/libswiftCore.so" \
  | grep -c "std::__1::"
# Expect: > 0

nm --defined-only --dynamic "$SDK/usr/lib/swift/android/libswiftCore.so" \
  | grep -c "std::__cxx11::"
# Expect: 0
```

## Deferred work

See [`docs/deferred.md`](docs/deferred.md).
