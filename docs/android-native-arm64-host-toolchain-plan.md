# Android Native arm64 Host Toolchain Plan

Status: active

## Invariant

The Android build executes natively on the builder's architecture. Every host
tool the AOSP graph runs — the build executor, Soong, the C/C++ toolchain, the
JDK, the Rust toolchain, and the auxiliary build tools — is an arm64 Linux
binary, and no part of an Android build depends on binary translation.

A host toolchain is native when Soong resolves it through `linux-arm64`
prebuilts, not when a translated x86_64 binary happens to produce correct
output. Translation is a correctness and reliability boundary, not a
performance detail: two Go host tools have already died under it, `soong_zip`
on a SIGSEGV and Siso on a SIGTRAP that cancelled twenty-six in-flight actions
and failed a product build outright, neither with a cause in the tree.

## Current State

Soong already selects arm64 host prebuilts. `prebuiltOS()` in
`build/soong/android/config.go` and `ui/build/config.go` returns `linux-arm64`
when `runtime.GOARCH` is `arm64`, and the heavyweight toolchain paths are
parameterized on it rather than hard-coded: clang resolves as
`${ClangBase}/${HostPrebuiltTag}/${ClangVersion}`, and the JDK as
`filepath.Join("prebuilts/jdk/jdk21", config.HostPrebuiltTag())`. Reaching a
native host requires no Soong change.

`prebuilts/build-tools` already ships `linux-arm64`: thirty-four native
binaries and a complete eighty-entry `path/linux-arm64` shim, including
`ninja`, `n2`, `ckati`, `make`, `aidl`, `bison`, `flex`, `openssl`, the Python
launchers, `toybox`, and `zipalign`.

Nothing uses any of it. `soong_ui` is an x86_64 Go binary running under
Rosetta, so `runtime.GOARCH` reads `amd64`, `prebuiltOS()` returns `linux-x86`,
and every prebuilt path resolves to the translated tree. The selection is
global: the moment `soong_ui` runs native, every prebuilt path flips to
`linux-arm64` at once. There is no mixed mode.

Four prebuilts have no arm64 Linux variant, and each is required by that flip.
`prebuilts/clang/host/linux-x86` has no arm64 counterpart project, which is the
entire C/C++ toolchain. `prebuilts/jdk/jdk21` ships `darwin-arm64` but not
`linux-arm64`, which is javac, metalava, and d8/r8. `prebuilts/go/linux-x86`
has no arm64 counterpart, and Soong itself is Go. `prebuilts/rust-toolchain`
has no arm64 counterpart. Eight of forty build tools are also absent from the
arm64 tree, among them `soong_zip`, `merge_zips`, `zip2zip`, and `bpfmt`.

## Phase 1: Stop Running the Build Executor Under Translation

The compile action selects plain ninja through `SOONG_NINJA=ninja`. Siso is a
Go program and the least reliable element of the translated toolchain; ninja is
C++ and carries no Go runtime for the translation layer to mistranslate.
Upstream already makes this exact substitution where Siso is unreliable, in
`ui/build/config.go`, for macOS CI builders.

The same change carries the measurement that scopes every phase after it. A
separate analysis task mounts the AOSP output workspace read-only, reads
`.ninja_log`, classifies each output as host or target by its variant and path,
and reports the wall-clock split. That task is declared beside the compile
rather than inside it, so the compile's identity does not depend on the
measurement.

This phase changes the compile task's environment, which changes its identity
and invalidates both products' compiles. It therefore lands with a change that
already invalidates them rather than on its own.

Gate: both products compile with ninja as the executor, and the analysis task
reports the host-versus-target wall-clock split for each.

## Phase 2: Supply the Go and JDK Host Toolchains

`prebuilts/go/linux-arm64` and `prebuilts/jdk/jdk21/linux-arm64` enter the
source graph as pinned inputs acquired host-side, in the same shape the Repo
manifest already uses for their x86_64 counterparts. Both are near-stock
upstream distributions, and the JDK layout is already proven by the
`darwin-arm64` tree AOSP ships.

The eight missing build tools follow from Go directly: they are Go programs
built from AOSP source, so an arm64 Go produces them without further supply.

Gate: an arm64 Go builds `soong_ui`, `soong_build`, and the eight absent build
tools from the pinned source, and an arm64 `java` runs from the pinned JDK
inside the builder image.

## Phase 3: Supply the Rust Host Toolchain

`prebuilts/rust-toolchain/linux-arm64` enters the source graph. AOSP patches
its Rust distribution, so this phase carries those patches onto an arm64 host
build rather than adopting a stock toolchain.

Gate: the pinned arm64 Rust toolchain compiles the Rust modules the product
graph reaches, from the builder image.

## Phase 4: Supply the Clang Host Toolchain

`prebuilts/clang/host/linux-arm64` is produced rather than acquired.
`clang-r584948b` is an Android-patched LLVM, and no upstream arm64 Linux host
build of it exists, so `toolchain/llvm_android` builds it for an arm64 host as
a pinned Collider artifact with its own workspace, cache, and provenance. The
repository already builds a cross LLVM for the Swift target SDK, and this
follows that structure.

Gate: the produced toolchain compiles both the arm64 and the x86_64 Android
targets from an arm64 host, and its provenance names the LLVM revision and the
host architecture it was built for.

## Phase 5: Flip the Host and Prove Both Products

`soong_ui` runs as a native arm64 binary, so `prebuiltOS()` resolves
`linux-arm64` for every prebuilt at once. The compile action drops the x86_64
executable requirements it declares today, and the builder no longer enables
Rosetta for AOSP execution.

Gate: `nucleus_arm64` and `nucleus_x86_64` compile, sign, assemble, validate,
and publish with no translated process in any AOSP container, and each
generation carries the same identity and raw image set as the translated build
it replaces.

## Risk Surface

The substantive unknown is Phase 4, and within it the x86_64 target. An arm64
host compiling arm64 targets is ordinary. An arm64 host cross-compiling AOSP's
x86_64 target is far less trodden, and the repository supports both products
equally, so a clang that cannot produce `nucleus_x86_64` does not satisfy the
invariant. That question is answerable only by building the toolchain, which
makes Phase 4 the phase to scope by its own evidence rather than by the phases
around it.

The measurement in Phase 1 is what justifies Phases 2 through 5. If the
host-versus-target split shows translated host work is a small fraction of
wall-clock time, the reliability argument still stands on its own, but the
performance argument does not, and the supply phases should be scoped against
reliability alone.
