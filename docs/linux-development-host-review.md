# Nucleus: Linux Development Host and Artifact Distribution — Findings and Proposed Direction

**Document type:** investigation findings plus proposed architecture, prepared for expert review.
**Repository:** Nucleus monorepo (Swift 6.4, SwiftPM, single root `Package.swift`; build tool is the separate `collider` package).
**Investigation date:** 2026-08-11.
**Status of contents:** Section 3 is verified against the working tree and on-disk artifacts, with evidence cited. Sections 5–7 are proposed and not implemented. Section 8 lists unresolved questions. Section 9 states what was deliberately not inspected.

A reviewer should treat Section 3 as auditable fact, Sections 5–7 as a proposal to critique, and Sections 8–9 as the places where this analysis is most likely to be wrong.

---

## 1. System context

Nucleus is a monorepo producing a Linux desktop runtime: a Wayland/DRM compositor, a desktop shell, a React Native platform, an embedded Chromium/CEF browser, and a contained Android runtime. It targets Linux on both `arm64` and `x86_64`.

Development and builds are driven by `collider`, a separate Swift package in the same repository. Collider owns dependency planning, container execution, durable run records, content-derived task identity, persistent build workspaces, and artifact staging. It is installed via `./collider-setup.sh` and invoked as `collider` from anywhere inside a clone.

The build model has three relevant properties:

- **Containers are offline.** All dependency resolution, downloading, and source acquisition happens host-side and produces pinned local inputs. Containers execute with the host-only network and DNS disabled, consuming only mounted inputs.
- **Native C/C++ dependencies are staged into a per-target SDK.** `~/.cache/nucleus/nucleus-native-sdk/linux-<arch>/` contains finished libraries, generated public headers, and pkg-config metadata, split into `render` (Skia), `rn` (Hermes, React Native C++), `wayland`, and `android/gfxstream`.
- **Swift target compilation uses a Swift SDK artifactbundle** (`nucleus-swift-6.4-linux.artifactbundle`) carrying both `aarch64-unknown-linux-gnu` and `x86_64-unknown-linux-gnu`.

The current documented invariant is that macOS is the authoritative development and build host, that remote machines are SSH/editor clients only, and that no persistent Linux development machine exists. That invariant is what this document proposes to replace.

---

## 2. Question under investigation

Three questions, in the order they were asked:

1. Does the tooling support Linux as a development host, or only macOS?
2. Are the x86_64 builds that currently run under Rosetta translation genuinely required to work that way, or could they be conventional cross-compiles?
3. Given the answers, what should be done to support development on Linux x86_64 (explicitly **not** arm64 Linux), and what should improve in the current macOS-hosted dual-architecture build?

---

## 3. Verified findings

### 3.1 Collider builds only on macOS/arm64

Linux support exists in Collider, but in a **device/operations role**, not a build role.

**No container backend outside macOS.** `collider/Sources/ColliderCLI/ColliderCommand.swift:77-81` installs `AppleContainerRuntimeBackend()` under `#if os(macOS)` and `nil` otherwise. The `nil` case resolves to `UnsupportedOCIRuntimeBackend` (`collider/engine/Sources/ColliderRuntime/ColliderRuntime.swift:108`), whose every method throws `OCIExecutorFailure.unsupportedRunner`. Since all Linux compilation happens in containers, no build step can execute on a Linux host.

**Doctor fails by construction.** `collider/Sources/ColliderWorkspaceCommands/Doctor.swift`, in `ociExecutor(scope:)`, returns a prerequisite whose probe closure is literally `{ nil }` — i.e. permanently failing — for every runner platform except macOS/arm64. This applies to all four scopes (`runtime`, `swift-sdk`, `android`, `browser`). Additionally, `swiftSDKPrerequisites` requires the macOS-only executables `xcrun` and `pkgutil`.

**Host tasks are pinned to macOS.** 30 non-test sites specify `executionPlatform: .macOSARM64Native`, across `CoreColliderRecipe`, `SwiftTargetSDKColliderRecipe`, `ChromiumColliderRecipe`, `ColliderSwiftPM/SwiftPMLowering.swift`, and `AndroidRuntimeColliderRecipe`. `ExecutionPlatform.linuxARM64Native` has **zero** production uses. `ExecutionPlatform.linuxX86_64Native` has exactly one, and it is device-side: `ChromiumColliderRecipe/BrowserInstallationAction.swift:72`.

**What Linux does get.** `ColliderLinuxOperations` (~1,216 lines) provides `install session`, `install android-addon`, `run`, profile capture, and `android-runtime`, gated by `#if os(Linux)` in `collider/Sources/ColliderCLI/CommandGroups.swift`. `HostCatalogAugmentation+Linux.swift` exposes the shell runtime-publication component. This is "receive a built runtime generation, run it, profile it."

### 3.2 Stale scaffolding that claims Linux support

Three artifacts assert a Linux path that does not function:

- `tools/host-env.sh:57-58` resolves a Linux host toolchain from `${XDG_CACHE_HOME}/nucleus/swift-platforms/<id>-linux-amd64/current/toolchain/usr`. **Nothing in the repository writes that path**; those two lines are its only occurrences. The identifier is hardcoded to `-linux-amd64`, and unlike the macOS branch, the Linux branch performs no Swift 6.4 version assertion. The concept also contradicts the stated rule that Nucleus never builds a host toolchain.
- `collider-setup.sh` bootstraps Linux by running `"$bin" swift-sdk rebuild`. No root `swift-sdk` subcommand exists — `WorkspaceCommandSet.rootPrefix` is `Doctor, Bootstrap, Build, Test, Check, Generate`. The functioning spelling is `collider build swift-sdk --rebuild`.
- `.github/workflows/ci.yml:35,53` targets `[self-hosted, Linux, X64, nucleus]` and runs `collider doctor` followed by `collider test all`. Given 3.1 this cannot pass. Its owning plan, `docs/github-actions-self-hosted-runner-plan.md`, carries `Status: deferred` and states the workflow violates its own invariant.

### 3.3 Foreign-architecture execution: four of five native components are already pure cross-compiles

The policy that requests Intel binary translation is set by a blanket per-architecture rule, not by measured need — `collider/Sources/NativeBuilderColliderRecipe/NativeBuilderModels.swift:39-41`:

```swift
package var intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy {
    architecture == .x86_64 ? .required : .disabled
}
```

Each x86_64 native-SDK component was checked against its actual generated build graph on disk:

| Component | Build system | Non-compiler commands in graph | Executes foreign-arch binary |
|---|---|---|---|
| Skia | GN/Ninja | `../src/bin/gn` only — and GN is an **arm64** binary (`gn-linux-arm64.zip`, `CoreColliderRecipe.swift:235`) | No |
| Wayland | Meson | all five generators are `/native-wayland/bin/wayland-scanner`, the **arm64** scanner mounted specifically for this (`WaylandColliderRecipe.swift:759-768`) | No |
| gfxstream / Mesa (guest) | Meson | all generators are `/usr/bin/python3` scripts | No |
| RN C++ (double-conversion, fmt, glog, reactnative) | CMake | none | No |
| **Hermes** | CMake | **runs the just-built x86_64 `bin/hermesc`** | **Yes** |

Compiler configuration is conventional cross-compilation throughout: `--target=x86_64-unknown-linux-gnu --sysroot=…` against the container's native arm64 clang; GN receives `target_cpu="x64"`; CMake receives `CMAKE_SYSTEM_NAME`, `CMAKE_SYSTEM_PROCESSOR`, `CMAKE_{C,CXX,ASM}_COMPILER_TARGET`, and `CMAKE_SYSROOT` (`ReactNativeColliderRecipe.swift:986-993`); Meson receives real cross files (`swift-wayland/build-support/linux-x86_64.ini`, `android-runtime/build-support/linux-x86_64.ini`) with **no `exe_wrapper`** — which is itself evidence the authors did not intend to execute target binaries.

The Wayland arrangement is the strongest signal: an arm64 `wayland-scanner` is explicitly mounted at `/native-wayland` for the x86_64 build, and `Doctor.swift` lists `wayland/bin/wayland-scanner` under the arm64 native-SDK root only. The host-tool problem was already solved correctly there.

### 3.4 The single genuine case: Hermes `InternalBytecode`

`react-native/.rn-build/linux-x86_64/hermes/build.ninja:7612` declares:

```
build lib/InternalJavaScript/InternalBytecode.hbc: CUSTOM_COMMAND bin/hermesc lib/InternalJavaScript/InternalBytecode.js || bin/hermesc …
```

The just-built **x86_64** `hermesc` compiles `InternalBytecode.js` to `.hbc`, which `xxd.py` converts to `.inc`, which is compiled into `hermesInternalBytecode_obj`. The corresponding `.ninja_log` entries confirm this executed rather than being a dormant rule.

**An upstream fix already exists in the vendored tree.** `react-native/third-party/hermes/CMakeLists.txt:284` declares `IMPORT_HOST_COMPILERS`, consumed at `lib/InternalJavaScript/CMakeLists.txt:6-13`, which substitutes `imported-hermesc` for the target-built binary. It is documented at `react-native/third-party/hermes/doc/CrossCompilation.md:14,28` and used by React Native's own `utils/build-apple-framework-rn.sh:124`.

**The required input is already produced and discarded.** Both Hermes builds emit `ImportHostCompilers.cmake` (`react-native/.rn-build/hermes/` and `react-native/.rn-build/linux-x86_64/hermes/`), exporting `imported-hermesc` and `imported-shermes` with `IMPORTED_LOCATION_RELEASE "/build/hermes/bin/hermesc"`. Nothing consumes either file.

Two implementation notes: the export declares `imported-shermes` as well, but the recipe's ninja target list is `["hermesvmlean", "jsi", "hermesc"]`, so `shermes` is not built — it is only *used* when `HERMESVM_INTERNAL_JAVASCRIPT_NATIVE=ON` (currently OFF), but the imported target would point at a nonexistent path. And `IMPORTED_LOCATION_RELEASE` is a container path, so a host-arch Hermes build needs mounting at a path distinct from the target build directory.

### 3.5 The dominant translation cost is the Swift amd64 lane, not C++

`collider/Sources/ColliderWorkspaceCommands/ComponentRegistry.swift:782-783`:

```swift
swiftExecutable: .path(
    architecture == .arm64
        ? FilePath("/opt/swift/usr/bin/swift")
        : FilePath("/opt/swift-x86_64/usr/bin/swift"))
```

The entire amd64 Swift product build runs an **x86_64 swiftc under Rosetta inside an arm64 container**. The builder image ships two complete Swift toolchains for this purpose (`collider/images/native-builder/Dependencies.Containerfile:61` and `:79`). The stated rationale, at line 76:

> SwiftPM builds macro and plugin executables for the compiler's host architecture. Give the translated amd64 lane a matching official compiler so its host tools and target SDK share one architecture.

By contrast, the C++ x86_64 builds invoke `/opt/swift/usr/bin/clang++`, which is the **arm64** toolchain (the Containerfile asserts `aarch64-unknown-linux-gnu` at line 73), cross-compiling at native speed.

**This is the critical portability finding.** The "matching translated compiler" technique is viable only because Rosetta is fast. Its mirror image on an x86_64 Linux host would require a qemu-translated **arm64** swiftc for the arm64 lane, which is not viable. Making the Swift cross-compile genuinely cross is therefore a precondition for a Linux host, not merely an optimization.

### 3.6 Related policy defects

- **The policy pins container architecture.** `collider/engine/Sources/ColliderRuntime/OCIExecutor.swift:28-32` requires `executionPlatform == .linuxARM64OCI` whenever translation is `.required`. The flag does not merely *permit* translation; it *mandates an arm64 container*. On an x86_64 Linux host, the Skia/Wayland/gfxstream/RN x86_64 builds — which are pure cross-compiles that would run natively — would be pinned to an arm64 container and therefore require arm64 emulation. The blanket flag manufactures the problem it appears to solve.
- **An override exists but is unused.** `ComponentRegistry.swift:684` computes `resolvedTranslation = translation ?? target.intelBinaryTranslationPolicy`. The `translation:` parameter of `linuxSwiftPMInvocation` has **zero callers**, so Swift *builds* inherit `.required` even though only Swift *tests* execute target binaries.
- **Per-task discrimination is already an established pattern.** `ChromiumProductAction.swift:178` uses `.required` for `containerExecution` while `:212` uses `.disabled` for `sourceMaterializationExecution`; `CoreColliderRecipe.swift:1119` uses `.disabled` for `extract-gn`.
- **`SwiftTargetSDKColliderRecipe` contains zero translation sites** — the amd64 Swift SDK is already a genuine cross-compile.

### 3.7 Third-party host toolchains: genuinely x86_64-only

Three workloads require foreign-architecture execution for reasons outside first-party control. All three were verified against the actual artifacts, not against configuration strings.

**Android NDK.** The pinned input is `android-ndk-r30-beta2-linux.zip` (`collider/images/native-builder/native-builder-inputs.json`, sha256 `3827b0ac…`). Listing the archive shows exactly one host toolchain: `toolchains/llvm/prebuilt/linux-x86_64/`. There is no `linux-aarch64`. Google's public position on the NDK mailing list is that ARM Linux host support is "not a thing on our roadmap." This is why `buildSkiaAndroid` (`CoreColliderRecipe.swift:392`) requires translation despite targeting Android **arm64** — the constraint is the host toolchain, not the target.

Notably, the macOS NDK toolchain *is* native: `darwin-x86_64/bin/clang` is a Mach-O universal binary containing both `x86_64` and `arm64` slices. Google ships arm64 for macOS hosts and not for Linux.

**AOSP.** The pinned manifest ships no arm64 Linux host prebuilts:

| Prebuilt | Host variants present |
|---|---|
| `prebuilts/clang/host` | `darwin-x86`, `linux-x86` |
| `prebuilts/build-tools` | `darwin-x86`, `linux_musl-x86` |
| `prebuilts/jdk/jdk21` | `darwin-arm64`, `darwin-x86`, `linux-x86`, `windows-x86` |
| `prebuilts/go` | `linux-x86` |

`prebuilts/clang/host/linux-x86/clang-stable/bin/clang-format` is ELF x86-64. Soong itself has partial plumbing — `build/soong/android/config.go:1079-1085` maps `GOARCH=arm64` to `"linux-arm64"`, and `build/soong/android/arch.go:323` declares `LinuxMusl` with `Arm64` support — but `arch.go:321` restricts the glibc `Linux` host OS to `X86, X86_64`, and no backing prebuilts exist.

**Chromium / CEF.** `third_party/llvm-build/Release+Asserts/bin/clang` and `third_party/llvm-build/Linux_x64/bin/clang` are both ELF x86-64, as are `buildtools/linux64/gn`, `third_party/ninja/ninja`, and the bundled node. `tools/clang/scripts/update.py:362` offers host choices `('linux', 'mac', 'mac-arm64', 'win')` — a `mac-arm64` package exists; a `linux-arm64` package does not. `ChromiumColliderRecipe.swift:815` hard-validates `sourceLock.buildHostPlatform == "linux-x86_64"`, and the GN argument set pins `clang_base_path="//third_party/llvm-build/Linux_x64"`.

**Consequence.** All three of the permanently-translated workloads are **x86_64-host** tools. On an x86_64 Linux host they run natively. On an arm64 Linux host they would require qemu-user or FEX, with no vendor path to resolution. This is the decisive argument for supporting x86_64 Linux and not arm64 Linux.

### 3.8 No prebuilt-artifact consumption exists

Every download in the tree is a build **input** — `gn-linux-arm64.zip`, `android-sdk.tar.gz`, the two Swift toolchains, the NDK, node, bun, cmake. Nothing downloads a finished product. `InstallBrowser` / `BrowserInstallationAction` installs a locally-built `distributionRoot`; it does not fetch one.

A contributor with a fresh clone and no access to a pre-warmed cache would therefore have to build from source: the Swift target SDK (stdlib, Foundation, XCTest, Swift Testing, two architectures), the complete native SDK (Skia, Mesa/gfxstream, Wayland, Hermes, React Native C++), Chromium plus CEF, and AOSP. The last two are prohibitive.

The builder image is additionally arm64-only and asserts it: `Dependencies.Containerfile:17` runs `test "$(dpkg --print-architecture)" = arm64`, and the pinned inputs are `swift-arm64`, `cmake-arm64`, `node-arm64`, `bun-arm64`. Its multiarch layer adds **amd64** as the foreign architecture, with a hand-written libgudev/libc++ co-installation workaround (lines 5–48) that would need inverting for an amd64 image.

---

## 4. Corrections made during the investigation

Recorded so a reviewer does not re-derive superseded conclusions:

1. An initial claim that fixing translation would remove Rosetta from "the entire linux/x86_64 native SDK build" was **wrong**. The C++ cross-compiles already use the native arm64 clang (3.3, 3.5). The actual Rosetta costs are the Hermes `InternalBytecode` step and the whole Swift amd64 lane.
2. An initial claim that "neither Linux architecture is a free win" was **wrong for x86_64**. Because all three permanently-translated workloads are x86_64-host tools (3.7), an x86_64 Linux host needs *less* emulation than the current macOS host, not more.
3. AOSP and Chromium/CEF were initially asserted to be unavoidable from two configuration lines each. They were subsequently verified against binaries and prebuilt inventories (3.7). The conclusion held, but the original basis was insufficient.

---

## 5. Agreed target architecture

Roles are separated by function, and no machine holds an authoritative checkout.

- **macOS (Apple Silicon) — CI executor and artifact publisher.** Runs GitHub Actions-triggered builds. Publishes builder images, Swift SDK bundles, per-target native SDKs, CEF/Chromium distributions, and AOSP generations. Owns both test architectures: arm64 natively and amd64 under Rosetta. It is *not* a source-of-truth host, and contributors do not need access to it.
- **Linux x86_64 — self-sufficient contributor development host.** A contributor clones, provisions, builds the first-party graph, and runs linux-x86_64 tests entirely locally. Heavy prerequisites they are not modifying are materialized from published artifacts rather than rebuilt. They cannot run arm64 target tests; that is CI's responsibility.
- **arm64 Linux development hosts are out of scope**, on the evidence in 3.7.
- **Every clone is equal.** The concept of an authoritative development checkout is removed.

A property worth noting: the contributor's x86_64 Linux machine is *better* at Chromium/CEF and AOSP than the macOS CI host, because those are natively x86_64 there and permanently translated on macOS. Rebuilding them stays available and opt-in.

### 5.1 Three consumer classes

Distribution has three audiences, not two. Conflating them is the main design risk.

| Consumer | Wants | Keyed by | Materialized by |
|---|---|---|---|
| End user | Runtime product on their system | Release version | apt / dnf / pacman |
| Contributor | Heavy build prerequisites they are not modifying | Content identity | Collider, into `~/.cache/nucleus` |
| Third-party app developer | The six public Swift products plus native SDK to link against | SDK version | SwiftPM, possibly without Collider |

The existing `docs/linux-package-distribution-and-update-plan.md` (`Status: active`) owns the first exclusively. Its invariant is that Collider never mutates installed product and that package managers are the only authorities that do. The second and third consumers invert every other axis — different actor, key, lifecycle, and payload — and belong in a separate plan that reuses that plan's key hierarchy and channel model rather than extending its scope.

### 5.2 Resolution is identity-driven, not flag-driven

For each heavy component: if local source resolves to the published identity, download the artifact; if the source is modified, build it. Collider already computes exactly this key through content-derived task identity, so no `--use-prebuilt-chromium` style profile is required — which matters, because the repository's stated posture forbids build profiles and feature flags.

This produces tiering as a side effect rather than as configuration. Compositor/shell work pulls the `render` and `wayland` native SDK plus the Swift SDK. React Native library work pulls `rn`. Touching Chromium is what causes Chromium to build.

---

## 6. Proposed sequence

Strict sequential order. Phases 2–4 are independently valuable to the current macOS host even if the Linux work never proceeds.

**Phase 0 — Redefine roles in documentation.** `docs/macos-remote-development-plan.md` is superseded; its invariant is the direct opposite of Section 5. The `CLAUDE.md` statements that the authoritative checkout lives on macOS and that no persistent Linux development machine may exist are removed. `docs/github-actions-self-hosted-runner-plan.md` moves from `deferred` to `active`.

**Phase 1 — Published-artifact resolution.** CI publication plus identity-matched consumption for the artifact set in 3.8, including the cross-machine identity audit in 8.2. This is what makes a contributor Linux host possible at all, so it precedes Linux enablement.

**Phase 2 — Make the amd64 Swift lane a genuine cross-compile.** Use the arm64 `/opt/swift` with the existing `nucleus-swift-6.4-linux` Swift SDK targeting `x86_64-unknown-linux-gnu`, letting SwiftPM build macros and plugins for the host. Removes `swift-amd64.tar.gz` from the image inputs, `/opt/swift-x86_64` from the image, and `.required` from the Swift lane. Highest-risk phase; see 8.1.

**Phase 3 — Fix Hermes via `IMPORT_HOST_COMPILERS`.** Add a host-architecture Hermes stage producing `hermesc` and `shermes`, mount it at a path distinct from the target build directory, and pass `-DIMPORT_HOST_COMPILERS=<host build>/ImportHostCompilers.cmake` to the cross configure. Removes the last genuine foreign-architecture execution from the native-SDK graph.

**Phase 4 — Per-task translation declaration.** Delete the blanket rule at `NativeBuilderModels.swift:39-41`. Each OCI action declares whether it executes foreign-architecture binaries. Wire the unused `translation:` parameter so Swift builds are `.disabled` and test lanes `.required`. Rework `OCIExecutor.swift:28-32` from `guard == .linuxARM64OCI` into a runner-capability check, and rename the concept away from "Intel binary translation" — the predicate is architectural, not vendor-specific. After this phase the surviving `.required` sites are Chromium ×3, AOSP, Skia/Android (NDK), and cross-architecture test lanes.

**Phase 5 — Derive container platform from the host.** `.linuxARM64OCI` is currently a constant across `SwiftTargetSDKColliderRecipe:654,774`, `ComponentRegistry:708,792`, and `WaylandColliderRecipe:774`; the 30 `.macOSARM64Native` host-task sites are likewise constant. Both derive from `RunnerPlatform.current`. `ExecutionPlatform.linuxAMD64OCI` already exists.

**Phase 6 — amd64 native-builder image.** Per-architecture input entries and inversion of the multiarch workaround. Published as an artifact contributors pull, since an apt-snapshot closure is not reproducible on an arbitrary distribution. Phase 2 shrinks this by eliminating the second Swift toolchain.

**Phase 7 — Linux OCI backend.** Implement `OCIRuntimeBackend` (12 methods, one existing implementation to mirror) over rootless podman, which matches the policy contract cleanly: `--network=none`, drop-all capabilities, no-new-privileges, process-count limits. See 8.3 for the persistent-workspace difficulty.

**Phase 8 — Host contract and role separation.** Linux cases in `Doctor.ociExecutor`; removal of `xcrun`/`pkgutil` from `swiftSDKPrerequisites`; a Linux peer to `MacOSBuilderContract`/`MacOSBuilderDoctor` so `nucleusWorkspaceEnvironment` populates `NUCLEUS_BUILD_ROOT`, `XDG_CACHE_HOME`, `NUCLEUS_NATIVE_SDK_ROOT`, and `ANDROID_SDK_ROOT`; a non-Darwin path in `tools/host-platform-env.sh`, which currently early-returns and leaves `JAVA_HOME`/`ANDROID_HOME` unset; deletion of the dead `swift-platforms` branch in `tools/host-env.sh` in favour of an official Swift.org 6.4 Linux toolchain with the version assertion the macOS branch already performs; and the `collider-setup.sh` command-spelling fix.

Also in this phase: `defaultHostCatalogAugmentation()` currently returns `.linux(...)` on `#if os(Linux)` unconditionally. With Linux acting as both builder and device, the discriminator must become **role**, not operating system, or every Linux build will drag in the shell runtime-publication component.

**Phase 9 — Invert the Swift SDK build direction.** Today arm64 builds natively and amd64 cross-compiles; an x86_64 host wants the reverse. See 8.5.

**Phase 10 — Restrict arm64 test lanes to CI.** Do not add qemu-user to the Linux host; it reintroduces the emulation dependency this sequence removes, in the one place where correctness matters most.

---

## 7. Documentation consequences

- **`docs/macos-remote-development-plan.md`** (`Status: active`) — superseded in full by the Phase 0 role model.
- **`docs/linux-package-distribution-and-update-plan.md`** (`Status: active`) — scope unchanged, two sections stale. Its "Product and Tool Boundaries" opens with "The macOS development host owns source orchestration and Linux artifact production," which no longer holds. Its Phase 2 introduces `collider dev-deploy linux-runtime` to transfer a generation from macOS to a Linux target and calls it "the intended inner-loop command"; under the new model a Linux contributor builds and runs locally, so `dev-deploy` demotes to a CI/demonstration convenience. Its Phase 7 (deleting `collider install session|browser|android-addon`) is unaffected, and its gate — that the macOS and Linux command trees share the invariant — becomes easier once Phase 8 role separation lands. Its Phase 3 ("Make the Browser a Package Input") gains a second consumer in contributor distribution.
- **New plan** — owns developer-facing artifact distribution for both contributors and third-party SDK consumers, reusing the package plan's offline-root/signing-subkey hierarchy and stable/beta/nightly channel model.
- **`docs/github-actions-self-hosted-runner-plan.md`** (`Status: deferred`) — becomes active and central; its "M2 Ultra runner identities" concept is now the centerpiece.
- **`docs/README.md`** — execution order changes: the macOS remote-development entry disappears and its interleaving with the package plan is rewritten.

### 7.1 A deliberate exception to the anti-versioning rule

The repository's stated posture forbids version identifiers on internal contracts whose producers and consumers ship from the same build. The third-party SDK is the explicit carve-out that rule allows: a documented boundary where independently developed applications compile against a published interface. The new plan should introduce an SDK version identifier **and state why**, or a later reader will delete it as a violation.

Relatedly, the six supported external Swift products (`Nucleus`, `NucleusDesktop`, `NucleusReactRuntime`, `NucleusFoundation`, `NucleusSessionProtocol`, `NucleusAndroidRuntimeCore`) do not build without `NUCLEUS_NATIVE_SDK_ROOT`. An application developer's SDK version and the runtime package version they execute against must therefore correspond — a contract spanning both plans and belonging in both.

---

## 8. Open questions

These are the load-bearing uncertainties. A reviewer's attention is most valuable here.

**8.1 Does SwiftPM 6.4 correctly build macros and build-tool plugins for the host when cross-compiling with a Swift SDK?** The `Dependencies.Containerfile:76` comment implies the team previously concluded it does not, and worked around it by running a translated matching compiler. If the limitation persists, Phase 2 is blocked on an upstream Swift defect and the entire Linux direction is jeopardised, because the workaround does not port. **Resolution:** attempt an amd64 build with the arm64 compiler plus the existing Swift SDK; success criterion is that macro and plugin executables are produced for the host architecture and amd64 products link. This should be run before committing to the sequence.

**8.2 Are Collider action identities stable across machines?** Several identity encoders fold absolute `FilePath` values into the digest (for example `BuildTracyReceiversAction.Identity`). `CanonicalDigestEncoder` carries an `identityPathMap`, so normalisation exists as a concept, but its coverage was not audited. If identities embed machine-specific paths, every contributor cache lookup misses and Phase 1 fails silently rather than loudly.

**8.3 What satisfies the persistent-workspace contract on Linux?** `OCIPersistentWorkspaceState` carries `capacityBytes` and `allocatedBytes`, and declarations specify `filesystem: .ext4` with `journal: .writeback64MiB`. These are block-volume-shaped and map naturally onto Apple's container implementation. On Linux the candidates are loopback ext4 images or XFS project quotas; neither was evaluated. This is the largest unknown inside Phase 7.

**8.4 Do contributors need containers at all?** On x86_64 Linux the build target matches the host, so native execution is theoretically possible and `ExecutionBackend.native` already exists. Containers are nonetheless recommended, because the pinned Ubuntu apt-snapshot closure and the declared glibc 2.38 minimum ABI are load-bearing — a native build against a contributor's system libraries would likely fail the SONAME ownership validation on newer distributions. This reasoning was not empirically tested.

**8.5 Does the Swift SDK build support the inverted direction?** Upstream `build-script` supports building either architecture natively, but `swift-sdk/nucleus-target-runtime-presets.ini` and `SwiftTargetSDKColliderRecipe` assume arm64-native with amd64 cross-compiled. The effort to invert was not assessed.

**8.6 Should contributor prebuilts and third-party SDK distribution be one plan or two?** They are proposed as one because the artifact set is identical today. If third-party API-stability scope grows — public API documentation, deprecation policy, source-compatibility guarantees — they should split. A reviewer may reasonably judge that they should start separate.

---

## 9. Coverage limits

What was **not** inspected, stated so the findings are not over-read:

- **Chromium and AOSP build internals.** Both were established as x86_64-host-only from their bundled toolchains and prebuilt inventories (3.7). Their internal build graphs were not enumerated for additional foreign-architecture execution, because the host toolchain constraint already forces translation regardless.
- **The gfxstream host build.** Only `android-runtime/.gfxstream-build/linux-x86_64/guest/build.ninja` was examined. If a separate host-side gfxstream component exists, it was not checked.
- **Skia `graphite` and `android-arm64` build configurations.** Only `core/.skia-build/linux-x86_64` was examined for the cross-compilation question.
- **Qualification, release-gate, and integration-test recipes.** `QualificationColliderRecipe`, `ReleaseGateColliderRecipe`, and `integration-tests` were not examined for host-platform or translation assumptions.
- **Runtime behaviour.** No build, test, or Collider command was executed during this investigation. All findings derive from source, generated build graphs, `.ninja_log` records, and on-disk artifacts.
- **The 30 `.macOSARM64Native` sites** were counted, not individually reviewed for host-specific logic beyond the platform constant.

---

## 10. Summary for a reviewer

The two findings that carry the argument:

1. **Only one component in the first-party native-SDK graph genuinely requires foreign-architecture execution** (Hermes `InternalBytecode`), and the upstream fix is present in the vendored tree and already emits its required input. The blanket per-architecture translation flag is the cause of the appearance otherwise, and it additionally pins container architecture in a way that would actively block an x86_64 Linux host.

2. **All three permanently-translated workloads are x86_64-host tools** (Chromium/CEF, AOSP, Android NDK), verified against binaries and prebuilt inventories. This makes x86_64 Linux strictly better than the current macOS host for the heaviest builds, and makes arm64 Linux permanently unattractive.

The largest piece of work is not the Linux container backend. It is **published-artifact distribution** (3.8, Phase 1), without which a contributor cannot bootstrap at all — and the highest-risk unknown is **8.1**, which should be settled experimentally before the sequence is committed to.
