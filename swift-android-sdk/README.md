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

## Separate build stages, one published generation

The host toolchain is host-native. Cross-compiling Swift code to Android requires a
matching Android stdlib + Foundation + dispatch built with the same
compiler version. Bundling those commands into one upstream build graph would
conflate two independent concerns:
"what runs the Swift compiler" vs. "what the Swift compiler emits
when targeting Android".

Both recipes remain separate internally, but Nucleus never publishes them
independently. The top-level workflow builds both into an inactive generation,
wires and tests the Android SDK with that generation's compiler, then atomically
switches one `current` symlink.

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
files. Each recipe is idempotent across `tools/nucleus toolchain rebuild` runs after
a successful deps run skips them via per-recipe sentinel files
under `$STAGING/.deps-built/`.

## libc++ alignment

This SDK is naturally libc++-flavored end-to-end: the Android NDK has shipped
libc++ exclusively for years, and Swift's Android stdlib build binds
`CxxStdlib` to libc++. The host compiler carries
`swift-toolchain/patches/swift/0001-clangimporter-libcxx-cxxstdlib.patch`, which
supplies the NDK 30 `wchar.h` importer guard for every Android target. The
ordered platform build always qualifies that compiler before using it to build
the Android stdlib, so the former source-level bootstrap duplicate is not
needed.

The smoke test below still asserts `std::__1::` (libc++) symbols in
the produced Android `libswiftCore.so` so a future upstream regression
that silently switches Android to libstdc++ would fail loudly.

## Prerequisites

* A Swift 6.4 bootstrap compiler on `PATH` for the first generation. Later
  rebuilds use the active user-level Nucleus toolchain.
* Ubuntu 26.04+ (matches `swift-toolchain`'s build host).
* Apt packages from [`apt-deps.txt`](apt-deps.txt) on top of
  `swift-toolchain/apt-deps.txt`:

  ```sh
  sudo apt update
  sudo apt install $(< apt-deps.txt)
  ```

## Build

```sh
../tools/nucleus toolchain rebuild
```

It rebuilds the host Swift toolchain, rebuilds the Android SDK with fresh CMake
state, wires the staged artifactbundle to the configured NDK, and builds dynamic
and static consumers before activation. A failure leaves the previous paired
generation active.

Use `--dry-run` to print the complete workflow. `--reconfigure` also forces the
host toolchain to reconfigure, `--skip-ndk` requires the configured NDK, and repeatable
`--arch aarch64|x86_64` selects the SDK architectures to build and verify.

Outputs:

* Active pair: `~/.cache/nucleus/swift-platforms/release-6.4.x/current/`
* Toolchain: `current/toolchain/usr/`
* Android artifactbundle and build outputs: `current/android/`

The NDK is **not** downloaded by default — the script reuses the
AGP-managed NDK 30 already installed via `sdkmanager` at
`~/Android/Sdk/ndk/30.0.14904198/`. See the "NDK selection" section
below.

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
NUCLEUS_ANDROID_NDK_VERSION=r27d ../tools/nucleus toolchain rebuild
```

This fetches r27d from `dl.google.com` and caches it under
`~/.cache/nucleus/android-ndk/r27d/`.

### Flags

`../tools/nucleus toolchain rebuild --dry-run` prints the command lines without running them.

`../tools/nucleus toolchain rebuild --skip-ndk` requires the configured NDK and skips download.

`../tools/nucleus toolchain rebuild --arch x86_64` (repeatable) opts in to additional
arches. Default is aarch64 only.

### Environment variables

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
The workflow owns both install roots inside one inactive platform generation.
They are intentionally not user-selectable independently, and their paths stay
stable when the generation is activated so generated metadata remains valid.

## macOS (Apple Silicon)

The same top-level workflow builds this Swift Android SDK on a Mac against
the staged macOS host toolchain and source workspace. Its internal recipe
remains separate from `build.sh` because the
cross-compile-to-Android work itself (NDK clang, `build-script
--android` flags) is host-OS-agnostic, but every path that assumes a
Linux *build host* — the NDK's `linux-x86_64` prebuilt-clang
directory, `~/Android/Sdk`, `nproc`, apt packages, the Debian ccache
PATH-shim — needs a macOS counterpart.

No Android Studio is required or used anywhere in this path — the NDK
is installed standalone via the command-line `sdkmanager`.

### Prerequisites

The workflow builds the matching macOS host toolchain first and reuses its
Swift source workspace. Xcode.app is required as described in the toolchain
README.

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
../tools/nucleus toolchain rebuild
```

Outputs use the paired macOS namespace:

* Active pair: `~/.cache/nucleus/swift-platforms/release-6.4.x-macos/current/`
* Toolchain: `current/toolchain/usr/`
* Android artifactbundle and build outputs: `current/android/`

The `--dry-run`, `--skip-ndk`, `--reconfigure`, and `--arch` flags match
the Linux workflow. The NDK
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

`tools/nucleus toolchain rebuild` creates the SwiftPM discovery symlink under
`~/.swiftpm/swift-sdks/`. It points through the paired generation's `current`
symlink, so activating the compiler and Android SDK is one atomic operation.
No system directory or elevated privilege is involved.

Verify:

```sh
swift sdk list   # should show swift-release-6.4.x_android
```

The rebuild workflow performs the dynamic and static end-to-end consumer checks
against the inactive generation before it can become current.

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
├── scripts/            # staged bundle setup + local e2e consumer test
└── docs/
    └── deferred.md     # work intentionally not in the current build
```

## Verifying libc++ alignment

After the build, the Android stdlib should still bind to libc++:

```sh
SDK=~/.cache/nucleus/swift-platforms/release-6.4.x/current/android/build/install-aarch64
nm --defined-only --dynamic "$SDK/usr/lib/swift/android/libswiftCore.so" \
  | grep -c "std::__1::"
# Expect: > 0

nm --defined-only --dynamic "$SDK/usr/lib/swift/android/libswiftCore.so" \
  | grep -c "std::__cxx11::"
# Expect: 0
```

## Deferred work

See [`docs/deferred.md`](docs/deferred.md).
