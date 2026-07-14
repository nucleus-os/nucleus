# Build-out plan

Step-by-step plan for finishing the Swift Android SDK build pipeline.
Designed to be picked up by a fresh agent session and executed
autonomously up to the point of physical-device verification.

The current repo state already has:

* Scaffold (`README.md`, `apt-deps.txt`, `docs/deferred.md`)
* `build.sh` with phase 1 rounded out (`build_one_arch` calls
  `swift/utils/build-script --android` with the proper cross-compile
  flags), and phase 2 wired in (`build_deps_for_arch` runs
  `third-party/deps/fetch-and-build.sh` ahead of the Swift cross-build).
* `third-party/deps/` with verified-sha256 tarball pins for 7 C
  libraries and per-library cross-compile recipes.
* finagolfin's swift-android-sdk pipeline — the original reference for
  this work. No longer vendored here; consult it upstream at
  github.com/finagolfin/swift-android-sdk when something fails.
* Reference bundle extracted under
  `~/.cache/nucleus/swift-android-sdks/.reference/` (the official
  swift.org 6.3.2 Android `.artifactbundle.tar.gz`). Used to validate
  the layout produced in phase 3.

## Decision log (locked, do not relitigate)

| Decision | Value |
|---|---|
| Host toolchain | `~/.cache/nucleus/swift-toolchains/release-6.4.x/usr` (libc++-flavored) |
| Swift source workspace | `~/.cache/nucleus/swift-source/release-6.4.x` |
| NDK | `~/Android/Sdk/ndk/30.0.14904198` (AGP-managed, beta1) |
| Min API | `36` (Android 16 "Baklava"; binaries run forward on Android 17) |
| Default arch | `aarch64` only (Pixel 7 Pro target) |
| Bundle layout | BYO-NDK, mirroring swift.org official 6.3.2 |
| C dep strategy | Cross-build from source (option β); recipes in `third-party/deps/recipes/` |
| HTTP/2 | Enabled (nghttp2 in dep graph) |
| HTTP/3, SCP/SFTP, IDN, PSL | Excluded |

## Common gotchas

* **Do not** rerun `swift-toolchain/build.sh` — the host
  toolchain is built once and reused. This repo only consumes it.
* **Do not** `rm -rf $destdir` between phase 2's deps build and phase
  3's Swift build — the deps are pre-staged into `$destdir/usr/`
  before `build-script` runs and `build_one_arch()` deliberately does
  not clean.
* If you need to nuke a single dep's cache, delete its sentinel file at
  `$STAGING/.deps-built/<recipe>` rather than wiping the whole staging
  tree.
* Iteration loop expectation: each phase below may take 1–3 fix cycles
  before passing. Capture cmake/build-script errors verbatim before
  hypothesizing fixes — don't guess.

---

# Phase 1 — First deps cross-build

**Goal**: every recipe under `third-party/deps/recipes/` builds
successfully and lands its outputs in
`~/.cache/nucleus/swift-android-sdks/release-6.4.x/build/install-aarch64/usr/`.

## Command

```sh
cd <monorepo-root>/swift-android-sdk
./build.sh --arch aarch64 --skip-package 2>&1 | tee /tmp/phase1.log
```

The `--skip-package` flag stops the run after `smoke_test` so phase 2's
Swift cross-build doesn't run yet. The dep build is the only thing
exercised here despite the shared command.

Expected wall-clock for the deps portion alone: ~10–15 minutes on a
32-core machine.

## Verification

After a successful run:

```sh
staging=~/.cache/nucleus/swift-android-sdks/release-6.4.x/build/install-aarch64
ls "$staging/usr/lib"/lib{z,lzma,iconv,ssl,crypto,nghttp2,curl,xml2}*.a
ls "$staging/usr/include/curl/curl.h" "$staging/usr/include/openssl/ssl.h" \
   "$staging/usr/include/libxml/tree.h" "$staging/usr/include/nghttp2/nghttp2.h"
ls "$staging/.deps-built"  # all 7 sentinels present
```

All listed paths should exist. If a recipe didn't run, its sentinel will
be missing.

## Failure modes and fixes

The recipes have not been run end-to-end; expect some friction.

* **openssl ./Configure rejects flags** — most likely culprit. Check
  whether `no-asan`/`no-ubsan` exist in the chosen OpenSSL version's
  Configure (varies by release). Adjust the flag list in
  `recipes/openssl.sh`.

* **libiconv autotools cross-compile errors** — needs `ac_cv_*` cache
  variables when configure tries to run target binaries. Symptom is a
  "cannot run test program" message. Fix: add `--build=$(./config.guess)`
  to the configure invocation, or set the specific `ac_cv_*` it asks for.

* **xz autotools `--disable-rpath` not recognized** — recent xz versions
  use a different flag name. Check `./configure --help | grep rpath`.

* **cmake-based recipes can't find Android toolchain file** — verify
  `$NDK_HOME/build/cmake/android.toolchain.cmake` exists. If the NDK
  layout changed, update `CMAKE_TOOLCHAIN_FILE` in `env.sh`.

* **find_package(CURL) etc. inside a recipe** — that means a recipe
  references *another* dep but `CMAKE_FIND_ROOT_PATH` isn't pointing at
  `$STAGING/usr` correctly. Both are already passed; check ordering of
  recipes in `fetch-and-build.sh`'s `recipes=()` array.

* **sha256 mismatch on first fetch** — the pinned version released a
  new tarball with the same name (re-upload, retroactive re-sign, etc.).
  Re-download, compute the actual hash with `sha256sum`, update the
  matching `*_SHA256` in `versions.env`. Don't blindly trust the new
  hash — confirm against the upstream project's signed announcement.

When a recipe fails, fix it, delete its sentinel
(`rm "$staging/.deps-built/<recipe>"`), and rerun the same command.
Successful recipes are skipped via their sentinels.

## Definition of done

All 7 sentinel files present, the verification `ls` block succeeds,
and `phase1.log` shows no errors after the deps section.

---

# Phase 2 — First Swift cross-build

**Goal**: `swift/utils/build-script --android` runs to completion and
installs the Swift stdlib + Foundation + libdispatch + XCTest +
swift-testing into the same `$staging/usr/` that phase 1 populated.

## Command

```sh
cd <monorepo-root>/swift-android-sdk
./build.sh --arch aarch64 --skip-package 2>&1 | tee /tmp/phase2.log
```

(Same command; the deps short-circuit via sentinels, so this run
exercises only the Swift cross-build plus the smoke test.)

Expected wall-clock: 2–3 hours on a 32-core machine. ccache is reused
from the swift-toolchain build at `$CCACHE_DIR`, so subsequent
iterations are faster.

## Verification

```sh
staging=~/.cache/nucleus/swift-android-sdks/release-6.4.x/build/install-aarch64

# Core stdlib
ls "$staging/usr/lib/swift/android/libswiftCore.so"
ls "$staging/usr/lib/swift_static/android/libswiftCore.a"

# Foundation + deps
ls "$staging/usr/lib/swift/android/libFoundation.so"
ls "$staging/usr/lib/swift/android/libFoundationNetworking.so"
ls "$staging/usr/lib/swift/android/libFoundationXML.so"
ls "$staging/usr/lib/swift/android/libdispatch.so"

# Module interfaces for cross-compile consumers
ls "$staging/usr/lib/swift/android/Foundation.swiftmodule"
ls "$staging/usr/lib/swift/android/Swift.swiftmodule"
```

The smoke test built into `build.sh` will also have run automatically;
its check is "libc++ symbols present, no `__cxx11` symbols" in
`libswiftCore.so`. Verify in the log that `==> smoke test` printed
`libc++ symbols > 0` and `libstdc++ symbols = 0` for aarch64.

## Failure modes and fixes

* **Foundation cmake: "Could not find CURL"** — phase 1's curl outputs
  exist but cmake isn't seeing them. Check
  `$staging/usr/lib/pkgconfig/libcurl.pc` exists and points at the
  *correct* relative prefix. If not, edit phase 1's `libcurl.sh` to
  pass `--prefix=$STAGING/usr` (it should already).

* **build-script error about missing `--cross-compile-deps-path`
  contents** — the staging dir is missing something Foundation
  expects. Compare `$staging/usr/include/` against
  `~/.cache/nucleus/swift-android-sdks/.reference/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/swift-resources/usr/include/`
  — if a header dir is missing, the relevant recipe didn't run or
  failed to install headers.

* **swift-corelibs-foundation source needs an Android patch** — capture
  the patch from the failure (or cherry-pick the relevant hunks from
  finagolfin's `swift-android.patch` at
  github.com/finagolfin/swift-android-sdk), and save it under
  `swift-toolchain/patches/swift-corelibs-foundation/<NNNN>-<name>.patch`.
  That repo owns the Swift source patch set and applies it to the shared
  `release/6.4.x` workspace via its `apply_patches()` — this repo builds
  from the same workspace, so there is no separate patch step here.

* **Linker errors about NDK API 36 symbols** — NDK 30 beta1's API 36
  stubs may have bugs. Bump the build to API 35 temporarily by setting
  `NUCLEUS_ANDROID_API_LEVEL=35` and retry; if it works, file a NDK
  ticket and document the workaround in `docs/deferred.md`.

* **swift-testing build fails** — it's the newest component and may
  expect API ≥ 33 features. Likely fine at API 36, but if not, drop
  `--swift-testing --install-swift-testing` from the build-script
  invocation in `build.sh` and add it to `docs/deferred.md`.

## Definition of done

* All `.so` files in the verification list exist.
* `phase2.log` ends with `==> smoke test` reporting expected libc++
  symbol counts.
* The build-script invocation exited 0.

---

# Phase 3 — Implement `assemble_bundle`

**Goal**: produce a valid Swift SDK artifactbundle at
`~/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle.tar.gz`.

`assemble_bundle` is currently a TODO stub in `build.sh`. Replace it
with a real implementation that mirrors the swift.org official 6.3.2
bundle layout.

## Reference

Extract a known-good layout to copy from:

```sh
ls ~/.cache/nucleus/swift-android-sdks/.reference/swift-6.3.2-RELEASE_android.artifactbundle/
# info.json   sbom.spdx.json   swift-android/
```

Files to mirror exactly (with our naming substituted):

* `info.json` — top-level artifact manifest
* `swift-android/swift-sdk.json` — target triple enumeration
* `swift-android/swift-toolset.json` — extra C/Swift/linker flags
* `swift-android/scripts/setup-android-sdk.sh` — vendored from reference
* `swift-android/swift-resources/usr/lib/swift-aarch64/`
* `swift-android/swift-resources/usr/lib/swift_static-aarch64/`
* `swift-android/swift-resources/usr/{include,share,lib/cmake,lib/pkgconfig}`
* `swift-android/swift-resources/usr/lib/swift/` (empty dir for the
  clang symlink the setup script later creates)
* `swift-android/ndk-sysroot/` (empty)

Inspect the reference files via `cat` / `tree` rather than guessing.

## Implementation outline

In `build.sh`, replace `assemble_bundle` with:

```
1. rm -rf $bundle_root; mkdir -p $bundle_root/swift-android/{scripts,swift-resources/usr/lib,ndk-sysroot}
2. Write $bundle_root/info.json via heredoc (templated by source_id).
3. Copy scripts/setup-android-sdk.sh — see "vendoring" below.
4. Write swift-android/swift-toolset.json via heredoc, INCLUDING the
   -z max-page-size=16384 linker flag (16K page-size devices).
5. Write swift-android/swift-sdk.json via heredoc, enumerating triples
   aarch64-unknown-linux-androidN for N in $api_level..36 (plus
   x86_64-unknown-linux-androidN if x86_64 was built).
6. For each arch in $selected_arches:
   a. rsync $build_root/install-$arch/usr/lib/swift/        → bundle/.../lib/swift-$arch/
   b. rsync $build_root/install-$arch/usr/lib/swift_static/ → bundle/.../lib/swift_static-$arch/
7. From the first arch's install, rsync arch-shared dirs into bundle:
   a. usr/include/swift   → bundle/.../include/swift
   b. usr/share/swift     → bundle/.../share/swift
   c. usr/lib/cmake       → bundle/.../lib/cmake
   d. usr/lib/pkgconfig   → bundle/.../lib/pkgconfig
8. mkdir bundle/.../lib/swift  (empty; setup script drops clang symlink here)
9. tar -czf $bundle_tar -C $install_root $(basename $bundle_root)
10. sha256sum $bundle_tar | awk '{print $1}' > $bundle_sha
```

Use bash arrays / heredocs throughout to match the existing style.

## Vendoring `setup-android-sdk.sh`

Copy the script from the reference bundle into our repo:

```sh
mkdir -p <monorepo-root>/swift-android-sdk/scripts
cp ~/.cache/nucleus/swift-android-sdks/.reference/swift-6.3.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh \
   <monorepo-root>/swift-android-sdk/scripts/setup-android-sdk.sh
chmod +x <monorepo-root>/swift-android-sdk/scripts/setup-android-sdk.sh
```

Then `assemble_bundle` copies it into the bundle at
`$bundle_root/swift-android/scripts/setup-android-sdk.sh`.

The script is ~50 lines of bash, MIT-licensed (Apple). It needs no
local modifications — it works against NDK 27+ (our NDK 30 is fine).

## JSON content templates

`info.json`:

```json
{
  "schemaVersion": "1.0",
  "artifacts": {
    "swift-release-6.4.x_android": {
      "variants": [{"path": "swift-android"}],
      "version": "0.1",
      "type": "swiftSDK"
    }
  }
}
```

`swift-toolset.json` (taken from the reference, verbatim):

```json
{
  "cCompiler": { "extraCLIOptions": ["-fPIC"] },
  "swiftCompiler": { "extraCLIOptions": ["-Xclang-linker", "-fuse-ld=lld"] },
  "linker": { "extraCLIOptions": ["-z", "max-page-size=16384"] },
  "schemaVersion": "1.0"
}
```

`swift-sdk.json` — emit one block per `(arch, api)` pair via a bash
loop. Each block:

```json
"aarch64-unknown-linux-android36": {
  "sdkRootPath": "ndk-sysroot",
  "swiftResourcesPath": "swift-resources/usr/lib/swift-aarch64",
  "swiftStaticResourcesPath": "swift-resources/usr/lib/swift_static-aarch64",
  "toolsetPaths": ["swift-toolset.json"]
}
```

Enumerate API levels `36..36` for now (Android 17 floor); the loop
mechanism is in place so bumping to additional API levels is a
one-line change.

## Verification

```sh
bundle=~/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle.tar.gz
ls -lh "$bundle" "$bundle.sha256"

# Smoke-extract and inspect
tmp=$(mktemp -d)
tar -xzf "$bundle" -C "$tmp"
tree -L 4 "$tmp" | head -40

# Validate JSON parses
python3 -c "import json; json.load(open('$tmp/swift-release-6.4.x_android.artifactbundle/info.json'))"
python3 -c "import json; json.load(open('$tmp/swift-release-6.4.x_android.artifactbundle/swift-android/swift-sdk.json'))"
python3 -c "import json; json.load(open('$tmp/swift-release-6.4.x_android.artifactbundle/swift-android/swift-toolset.json'))"
rm -rf "$tmp"
```

The extracted tree should match the reference bundle's structure
(modulo names; ours uses `swift-release-6.4.x_android` instead of
`swift-6.3.2-RELEASE_android`).

## Definition of done

* `.tar.gz` and `.sha256` files exist under `$install_root`.
* All three JSONs parse.
* Tree structure mirrors the reference.
* `assemble_bundle`'s exit code is 0.

---

# Phase 4 — `swift sdk install` round-trip

**Goal**: confirm `swift sdk install` accepts our bundle and recognizes
the cross-compile target.

## Command

```sh
toolchain=~/.cache/nucleus/swift-toolchains/release-6.4.x/usr
bundle=~/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle.tar.gz

# Use our locally-built host toolchain
export PATH="$toolchain/bin:$PATH"

# Remove any prior install (idempotency)
swift sdk remove swift-release-6.4.x_android 2>/dev/null || true

swift sdk install "$bundle" --checksum "$(cat ${bundle}.sha256)"
swift sdk list
```

Then run the consumer-side NDK sysroot setup that ships in the bundle:

```sh
export ANDROID_NDK_HOME=~/Android/Sdk/ndk/30.0.14904198
~/.swiftpm/swift-sdks/swift-release-6.4.x_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
```

## Verification

```sh
swift sdk list
# Expected line: aarch64-unknown-linux-android36 (and any other API
# levels enumerated in swift-sdk.json)
```

## Failure modes and fixes

* **`swift sdk install` rejects bundle structure** — JSON schema
  mismatch. Compare `swift-sdk.json` field-by-field against the
  reference's. The schemaVersion must be `"4.0"`. All paths must be
  relative.

* **`setup-android-sdk.sh` errors with NDK version too old** — check
  the script's version-check logic; the AGP-managed NDK at
  `~/Android/Sdk/ndk/30.0.14904198` should pass the `>= 27` floor.
  If the script reads `$NDK/source.properties` and our beta NDK has
  an unusual format, the regex parsing may fail. Patch the script.

* **`swift sdk list` shows nothing after install** — install path may
  be `~/.config/swiftpm/swift-sdks/` instead of `~/.swiftpm/swift-sdks/`
  depending on swift version. Find with
  `find ~ -name 'swift-release-6.4.x_android.artifactbundle' 2>/dev/null`
  and adjust the setup-android-sdk.sh invocation accordingly.

## Definition of done

`swift sdk list` prints at least
`aarch64-unknown-linux-android36`.

---

# Phase 5 — Hello-world cross-compile

**Goal**: produce an aarch64 Android ELF binary using our SDK.

## Command

```sh
mkdir -p /tmp/swift-android-hello && cd /tmp/swift-android-hello
swift package init --type executable --name hello

swift build \
  --swift-sdk aarch64-unknown-linux-android36 \
  --static-swift-stdlib \
  2>&1 | tee /tmp/phase5.log
```

## Verification

```sh
out=.build/aarch64-unknown-linux-android36/debug/hello
file "$out"
# Expected: ELF 64-bit LSB executable, ARM aarch64, ...
```

The binary should be ~5–10 MB with `--static-swift-stdlib` (statically
links Swift's stdlib + Foundation; libc++_shared.so is still dynamic).

## Failure modes and fixes

* **Linker errors about missing C library symbols** — our cross-built
  curl/openssl/etc. didn't get statically merged into
  `libFoundationNetworking.so` during phase 2. Re-check whether the
  build-script run produced linking against `$staging/usr/lib/libcurl.a`
  vs the system's curl. Pass an explicit `-DCURL_LIBRARY=$staging/usr/lib/libcurl.a`
  in the `--foundation-cmake-options` flag in `build.sh`.

* **Missing `Android` overlay module** — Foundation may want to
  `import Android` for some Bionic shims. Check
  `$staging/usr/lib/swift/android/Android.swiftmodule` exists. If not,
  the swift stdlib build is missing the `--swift-install-components`
  entry that produces it.

* **swiftpm complains about toolset.json format** — version-mismatch
  between swiftpm and swift-toolset.json's `schemaVersion`. The
  reference uses `"1.0"`; if our `swift` (6.4.x) wants `"2.0"`,
  update the heredoc.

## Definition of done

* `file` output confirms `ELF 64-bit LSB executable, ARM aarch64`.
* Binary built at the expected path.

---

# Phase 6 — Stop point: ready for physical device

At this point all programmatic verification is done. The next step —
pushing the binary to the Pixel 7 Pro and running it via `adb shell` —
requires the device to be connected and USB debugging enabled, which
is a manual task for the user.

Commands the user will run (do NOT execute these in an autonomous
session; document them and stop):

```sh
adb devices                                    # confirm device visible
adb push /tmp/swift-android-hello/.build/aarch64-unknown-linux-android36/debug/hello /data/local/tmp/
adb push "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so /data/local/tmp/
adb shell /data/local/tmp/hello
# Expected: Hello, world!
```

A subsequent run will validate `import FoundationNetworking` + a real
URLSession round-trip. That's also manual since it requires the device
to have network access.

---

# Reporting back

When phases 1–5 are complete, summarize:

* Which phases passed first try vs. needed iteration.
* What patches (if any) ended up in `swift-toolchain/patches/`.
* Total wall-clock for the deps build, the Swift cross-build, and the
  bundle assembly.
* Final bundle size (`ls -lh $bundle_tar`).
* Anything surprising that future runs should know about — add it to
  `docs/deferred.md` if it warrants a follow-up, or to this `PLAN.md`
  if it's a permanent procedure note.

Then commit + push the changes.
