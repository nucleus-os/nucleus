# Deferred work

Items intentionally left out of the current Swift Android SDK build.
Each has a defined trigger and known shape.

## Additional Android ABIs

Currently building `aarch64-unknown-linux-android` and
`x86_64-unknown-linux-android` only.

**armv7-a (`armv7-unknown-linux-androideabi`):** still used by some
low-end Android devices. Build cost is one more
`build-script --android-arch=armv7` invocation plus an extra
toolset.json entry in the artifactbundle.

**riscv64-linux-android:** Android 16+ added official RISC-V support
but the device population is effectively zero. Defer until Nucleus
targets a RISC-V Android device.

**Revisit trigger:** a Nucleus deployment target list that includes a
device class outside aarch64 / x86_64. The build script's `--arch`
flag already gates per-arch builds; adding a new arch is a one-line
loop addition plus an artifactbundle entry.

## NDK version drift from upstream

Defaults to NDK **30.0.14904198** (the AGP-managed NDK installed via
`sdkmanager`), so a single NDK serves both this Swift Android SDK
build and our AGP/Kotlin native work. This is **newer than the
upstream Swift Android workgroup's tested baseline (r27d)**.

The expected divergence cost is small:
* Android has used libc++ exclusively since NDK r18, and r30 still
  uses libc++ with the `std::__1::` inline namespace — our libc++
  alignment goal is unaffected.
* The sysroot layout (`toolchains/llvm/prebuilt/linux-x86_64/sysroot/
  usr/{include,lib}/`) has been stable across r25+.
* Build-script flags don't hard-code an NDK version.

What might break:
* Build-script paths that assumed a specific sysroot sub-layout (last
  reshuffled in r23 → r25 by Google; could happen again).
* Late link errors if Google moved CRT objects under
  `sysroot/usr/lib/<triple>/<api>/`.

Any breakage gets captured as a `swift-toolchain/patches/swift/`
patch rather than downgrading. The goal is to keep one NDK on the machine.

**Revisit trigger:** the patch set in `swift-toolchain/patches/swift/`
to make r30 work exceeds ~3 small patches, OR the Swift Android workgroup
publishes against a newer baseline that lets us delete those
patches. Fallback to r27d remains a single env-var override (see
README "NDK selection").

## Lift API floor to 37 (Android 17 native)

Default is `--android-api-level=36` (Android 16, "Baklava"). NDK 30
beta1 caps platform stubs at API 36 — `meta/platforms.json` reports
`"max": 36` and `sysroot/usr/lib/aarch64-linux-android/` stops at the
`36/` subdir. Binaries built at API 36 run forward-compatibly on
Android 17 (API 37), so this is the practical floor today for an
"Android 17 target" SDK.

**Revisit shape:** when NDK 30 final (or NDK 31) ships, verify
`platforms.json` "max" jumps to 37, then change one line in
`build.sh` (`api_level` default) and the swift-sdk.json triple
enumeration in `assemble_bundle`. No source-level changes needed —
the Swift stdlib doesn't reference any API-37-specific bionic
symbols.

**Revisit trigger:** `sdkmanager --channel=3 --list | grep "ndk;30"`
shows a non-beta build, and that build's `meta/platforms.json`
"max" is 37 (or higher).

## Lower API level support (minSdk < 36)

Out of scope by deliberate choice — Nucleus targets Android 17 as
the floor. Adding support for earlier Android releases (28, 24, 21)
involves three things:

1. **Termux bionic backports**: re-add `libandroid-spawn` (for API
   < 28) and `libandroid-execinfo` (for API < 33) to the Termux deb
   list pulled at build time.
2. **`swift-android.patch`** from finagolfin's swift-android-sdk
   (github.com/finagolfin/swift-android-sdk): carries the swift-testing
   link-deps change for `libandroid-execinfo`. Currently dropped because
   we don't need it at API ≥ 33.
3. **`execinfo.h` perl tweak** (`s/33/<api>/`) on the NDK header to
   gate backtrace visibility for the chosen floor.

The Swift Android workgroup's tested floor is 24; below that is
unsupported upstream.

**Revisit trigger:** the project shipped on Nucleus picks up a
deployment target that needs to support pre-Android-17 devices.

## Artifactbundle metadata polish

The current `info.json` and per-target `toolset.json` files emitted
by `build.sh` are functional but minimal — just enough for
`swift sdk install` to register the SDK and for `swift build
--swift-sdk` to find the cross-toolchain. Niceties not present:

* Human-readable `description` strings in `info.json` per-variant.
* `extraCCFlags` / `extraSwiftCompilerFlags` tuning for Nucleus's
  specific patterns (`-gline-tables-only`, etc.).
* Signature metadata for `swift sdk install`'s upcoming
  signature-verification mode.

**Revisit trigger:** the artifactbundle ships outside Nucleus
developer machines (CI image, teammate distribution, Nucleus OS
package).

## Self-build Foundation C deps (option β)

Current strategy harvests pre-cross-built `.a` files for libcurl,
openssl, libxml2, libnghttp2, libnghttp3, libssh2, zlib, liblzma,
and libiconv from the official swift.org 6.3.2 Android bundle —
same provenance Apple ships, zero new build infrastructure on our
end. Bionic ABI is stable across NDK versions so the harvested
artifacts (built against NDK r27d / API 24) link cleanly with our
NDK 30 / API 36 Swift stdlib.

Future migration: cross-build these C libraries from source
against NDK 30 / API 36 ourselves.

**Why migrate:**
* Hermetic builds — every byte in the bundle traceable to source in
  this repo.
* Independent CVE response — bump curl/openssl on our schedule,
  not Apple's.
* Match API floor — harvested libs target API 24; self-built can
  target 36 and use newer bionic conveniences (`getrandom`, newer
  `posix_spawn` family, …).
* Single source of toolchain truth — every artifact built with our
  NDK 30 clang against the same sysroot.

**Why not migrate today:**
* ~800-1200 lines of cross-build scaffolding across 9 libraries
  with a non-trivial dep graph (libcurl alone pulls 5 others).
* +30-60 min wall-clock per first build.
* Ongoing maintenance to bump pinned versions and chase upstream
  build-system changes.

**Revisit shape:**

```
swift-android-sdk/
├── third-party/
│   ├── deps/                       # NEW
│   │   ├── fetch-and-build.sh      # orchestrator: dep-graph order
│   │   ├── versions.env            # pinned tags + sha256 per lib
│   │   ├── recipes/
│   │   │   ├── zlib.sh
│   │   │   ├── liblzma.sh
│   │   │   ├── libiconv.sh
│   │   │   ├── openssl.sh          # depends on zlib
│   │   │   ├── libnghttp3.sh
│   │   │   ├── libnghttp2.sh       # depends on openssl
│   │   │   ├── libssh2.sh          # depends on openssl, zlib
│   │   │   ├── libcurl.sh          # depends on openssl, zlib, nghttp{2,3}, ssh2
│   │   │   └── libxml2.sh          # depends on liblzma, libiconv
│   │   └── cache/                  # gitignored: downloaded tarballs
│   └── swift-android-sdk/          # the existing finagolfin reference (read-only)
```

Each recipe is a small bash script: download pinned tarball,
verify sha256, configure with `--host=aarch64-linux-android` /
`CC=$NDK/.../aarch64-linux-android36-clang` / `--prefix=$staging`,
make, make install. Output: a fully populated
`$build_root/staging-aarch64/usr/{lib,include}/` that mirrors the
harvest layout exactly — `build.sh`'s `build_one_arch` flow stays
unchanged downstream.

**Revisit trigger:** an upstream CVE in libcurl or openssl that we
can't wait for the next swift.org Android bundle to fix, OR
Nucleus OS packaging requires hermetic source-traceable artifacts.

## Alternate self-contained layout

Current bundles are BYO-NDK (swift.org official layout): they ship
an empty `ndk-sysroot/` and rely on the consumer running
`setup-android-sdk.sh` post-install with `ANDROID_NDK_HOME` set.

The alternative — finagolfin's self-contained pattern — snapshots
a curated NDK sysroot subset directly into the bundle. Pro:
single-step install, no `ANDROID_NDK_HOME` requirement, no risk
of build-time vs consume-time NDK skew. Con: bundle grows from
~300 MB to ~1 GB.

**Revisit shape:** add a `BUNDLE_LAYOUT=self-contained` flag to
`build.sh` that:
1. Adds an NDK sysroot snapshot step before `assemble_bundle`.
2. Generates a `swift-sdk.json` with `sdkRootPath` pointing at the
   in-bundle sysroot subset.
3. Omits `scripts/setup-android-sdk.sh` (not needed).
4. Inlines the `libc++-stdlib.h` workaround patch against the
   snapshotted sysroot (the BYO-NDK path doesn't need this because
   the consumer's NDK headers are referenced read-only via symlinks).

Both layouts can coexist; the choice is a flag at build time.

**Revisit trigger:** the bundle gets distributed in environments
where requiring a separately-installed NDK is friction (Nucleus OS
ship image, isolated CI runners, …).

## Hermetic NDK fetch

`build.sh` currently downloads the NDK zip from `dl.google.com` at
first run and caches under `~/.cache/nucleus/android-ndk/r27d/`.
This is fine for developer machines but unsuitable for hermetic CI
or air-gapped Nucleus OS builds.

**Revisit shape:** mirror the NDK zip into the Nucleus artifact store
(or vendor it into a Git LFS object) and point
`NUCLEUS_ANDROID_NDK_URL` at the mirror.

**Revisit trigger:** introducing CI for this repo, or shipping a
`.deb` that builds the SDK from source in the package post-install.

## Foundation/dispatch split

Currently the build invokes upstream `swift/utils/build-script
--android`, which builds Foundation and libdispatch as part of the
SDK. If/when `nucleus-swift-runtime` (see the toolchain's
`docs/deferred.md`) splits Foundation/dispatch into a sibling repo
for the *host* build, the Android SDK should mirror that split so
the same source-of-truth produces both host and Android Foundation.

**Revisit shape:** once `nucleus-swift-runtime` exists, drive its
build with `--target aarch64-unknown-linux-android28` (and x86_64)
against the just-built bare Swift Android stdlib, then assemble the
artifactbundle from both stages.

**Revisit trigger:** `nucleus-swift-runtime` repo exists and ships
the host runtime as a `.deb`.

## Smoke test extensions

Current smoke test (run by `build.sh` after packaging):

1. Verify the artifactbundle tar extracts cleanly.
2. `swift sdk install` against the local artifactbundle.
3. `swift package init --type executable` + `swift build --swift-sdk
   aarch64-unknown-linux-android28`.
4. `nm` check: produced `libswiftCore.so` binds to `std::__1::`
   (libc++) and has zero `std::__cxx11::` references.

Not yet covered:

* Actually running the produced binary in an emulator (`adb push`
  + `adb shell` against a headless `emulator -no-window`). The CI
  shape for this is well-trodden (Android Studio's gradle-managed
  device pattern) but adds 10+ minutes per build for emulator boot.
* C++ interop: a smoke test that imports `CxxStdlib` and roundtrips
  a `std.string`, mirroring `swift-toolchain`'s host smoke
  test extension plan.

**Revisit trigger:** before relying on this SDK for production
nucleus Android builds.

## `.deb` packaging

Output is a Swift SDK artifactbundle today; not wrapped as a Debian
package. The artifactbundle is already a single relocatable tarball,
so wrapping it is a thin layer following the same pattern
`swift-toolchain` plans for its toolchain `.deb`.

**Revisit shape:** add a `debian/` directory whose `postinst`
invokes `swift sdk install` against the bundled artifactbundle.
Eventual Nucleus OS package: `swift-android-sdk`, depends on
`swift-toolchain`.

**Revisit trigger:** Nucleus OS ships a first-party package
repository.
