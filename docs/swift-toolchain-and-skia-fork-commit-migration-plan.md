# Swift Toolchain and Skia Fork-Commit Migration

## Invariant

Every Nucleus source change to Swift or Skia lives as an ordinary commit in a
genuine `nucleus-os` fork. The monorepo selects every source tree with a
submodule gitlink. Collider consumes and validates those clean checkouts; it
never selects, downloads, resets, cleans, patches, or materializes them. Build
products never enter a source submodule.

The complete Swift sibling graph lives under `swift-toolchain/source/`. Modified
repositories point at `nucleus-os`; unmodified repositories point at their
canonical upstreams. Skia remains at `core/third-party/skia`. No second lock,
source-generation cache, compatibility path, or format identifier duplicates
the gitlinks.

Linux toolchain and native dependency builds run in purpose-owned, rootless
Podman environments selected by immutable OCI digest. Source mounts are
read-only. Build roots, compiler caches, downloads, staging, and artifacts use
explicit writable mounts outside the source trees. Container execution is a
build boundary, not a source-management boundary.

Status: active

## Phase 1: Capture the Qualified Trees — Complete

Capture the exact upstream commits and final patched trees for Swift, Swift
Driver, Swift Build, SwiftPM, Foundation, and Skia. Attribute each change to the
repository that owns the modified file. Prove every retained change contributes
to the qualified host, Android, or Graphite behavior.

## Phase 2: Establish the Modified Fork Trees — Complete

Place the Swift-family changes in genuine forks of their canonical parents:

1. `nucleus-os/swift`;
2. `nucleus-os/swift-driver`;
3. `nucleus-os/swift-build`;
4. `nucleus-os/swift-package-manager`;
5. `nucleus-os/swift-corelibs-foundation`.

Place the Vulkan render-pass dependency change in the existing genuine
`nucleus-os/skia` fork. Each selected tree exactly reproduces the corresponding
qualified patched tree.

## Phase 3: Make Gitlinks the Complete Swift Source Authority — Complete

Represent every repository required by Swift's sibling checkout model as a
submodule under `swift-toolchain/source/`. Select the five modified repositories
from their `nucleus-os` forks and every unchanged repository from its canonical
upstream. Preserve nested upstream submodules recursively. The root index and
`.gitmodules` become the only source-selection authority.

## Phase 4: Make Collider a Read-Only Swift Source Consumer — Complete

Remove the Swift source lock, source generations, branch and tag selection,
`update-checkout` invocation, patch application, and generated source view.
Collider derives the toolchain source identity from the complete gitlink set,
then validates that every required submodule is initialized at its recorded
gitlink and has a clean worktree.

Run host and Android build-script operations from the fixed sibling checkout.
Pass one persistent external build root beside the candidate generations so a
new generation can reuse prior build products without placing them in source or
making them part of publication. Keep staging, archives, caches, and all host
and cross-build products under declared external writable roots.

## Phase 5: Establish the Hermetic Builder Contract — Complete

Define a small common Linux builder base and separate purpose-owned images:

1. `swift-builder` owns the Linux Swift host toolchain and SwiftAndroid SDK
   build dependencies;
2. `native-builder` owns Linux and Android Skia and other native SDK build
   dependencies;
3. `aosp-builder` remains the isolated AOSP build environment;
4. `chromium-builder` owns Chromium and CEF build dependencies when that source
   migration reaches its container phase.

Select every production image by immutable OCI digest. Tags are diagnostic
labels only. Record each image digest as a task input so an environment change
invalidates exactly the products built by that image. Keep the images separate
even when they share a common base; their dependency closure, cache lifecycle,
and artifact authority remain independent.

All builder invocations enforce the same boundary:

1. run rootless with the invoking user's identity;
2. drop capabilities and enable `no-new-privileges`;
3. mount selected source repositories read-only;
4. mount one declared build root and narrowly scoped cache roots read-write;
5. expose no host home directory, toolchain installation, SSH agent, Wayland
   socket, device, or unrelated workspace path;
6. disable the network during compilation after declared dependencies and
   images are present;
7. emit artifacts and machine-readable build metadata only through declared
   output mounts.

The container entry point is the single Linux toolchain-build implementation.
On macOS, first-run setup and subsequent native builds compile Collider with
the selected Xcode 27 Swift 6.4 compiler. On Linux, setup uses the active
generated Nucleus toolchain. Collider invokes the identical pinned Linux amd64
container graph from either host. The Xcode compiler never compiles the Linux
toolchain or SwiftAndroid products, so there is no second generation pipeline.

## Phase 6: Move Linux Swift and SwiftAndroid Into `swift-builder` — In Progress

Move the complete Linux host toolchain and Android SDK task operations into the
`swift-builder` boundary. Mount `swift-toolchain/source/` read-only and preserve
Swift's sibling checkout layout verbatim. Mount the candidate generation's
external build workspace, staging area, ccache, download cache, and artifact
destinations separately.

Place the exact Clang, CMake, Ninja, system development libraries, Android NDK,
and packaging tools in the selected image. Do not inherit compilers, headers,
libraries, or package-manager state from the runner. Run build-script with its
explicit external build directory and never invoke `update-checkout` from the
container.

Collider owns task ordering, image identity, mount declarations, logging,
cancellation, artifact validation, and atomic publication. Podman owns process
and filesystem isolation. Neither owns Swift source selection beyond consuming
the root gitlinks.

## Phase 7: Qualify the Container-Built Swift Graph

Qualify the new source boundary in this strict order:

1. validate every top-level and nested Swift submodule;
2. build and test Collider's source-validation and task graph behavior;
3. build the Linux host toolchain in `swift-builder` from an empty writable
   build root;
4. build every supported SwiftAndroid SDK architecture in the same selected
   builder environment;
5. validate the produced host toolchain on the runner outside the container;
6. compile, link, load, and run representative packages through every Android
   SDK outside the build container;
7. validate compiler, SwiftPM, driver, macro-plugin, Foundation, dispatch, and
   Swift Testing behavior covered by the former patches;
8. repeat the container build and prove reuse of declared external build and
   compiler caches;
9. repeat with compilation networking disabled;
10. verify every source submodule remains clean and that no build output was
    written beneath a source mount;
11. validate the macOS-hosted toolchain and SwiftAndroid path natively on a
    macOS runner.

Correct failures in the owning fork or build orchestration. Never restore a
patch, source materializer, or host-native Linux fallback. macOS remains a
separate native qualification because it cannot be represented by the Linux
builder.

## Phase 8: Delete the Swift Patch and Host-Native Linux Architecture

Delete `swift-toolchain/patches/`, the obsolete source lock and materializer,
the old managed-Swift-source operation, patch-oriented tests, and the replaced
host-native Linux command construction. Retain only the `swift-builder` Linux
path, the native macOS path, and behavioral source validation, container
boundary, build ordering, and product validation tests.

## Phase 9: Move Skia Builds Into `native-builder` — Implemented, Awaiting Phase 10 Qualification

Synchronize Skia's exact DEPS graph before entering the offline compilation
boundary. Mount the selected Skia checkout and resolved externals read-only.
Build Linux and Android Graphite/Vulkan artifacts in `native-builder` with
external writable build, compiler-cache, SDK-staging, and artifact mounts.

Keep GPU execution and compositor integration outside the container. Vulkan,
DRM, input, display, and session validation must exercise the runner's real
kernel, devices, drivers, and Wayland environment rather than a privileged
container approximation.

## Phase 10: Qualify Skia From Its Fork and Builder

Build host and Android Graphite/Vulkan artifacts from empty writable roots, then
run the Core bridge and renderer validation on the host. Exercise consecutive
render passes across resource uploads and verify attachment dependencies,
access masks, and layouts. Repeat the container build to prove cache reuse.
Confirm dependency synchronization and builds leave the Skia submodule clean
and produce no files beneath its read-only mount.

## Phase 11: Move React Native Native Dependencies Into `native-builder` — Complete

Build Hermes, fmt, double-conversion, glog, Folly, JSI, ReactCommon, and Yoga
with the same pinned rootless `native-builder` used by Skia. Mount the complete
React Native checkout and first-party CMake project read-only. Keep `.rn-build`
and the shared native compiler cache as the only writable mounts. Resolve ICU,
libc++, Clang, CMake, Ninja, and archive tools from the builder image rather
than the runner.

Store downloaded Boost generations beneath `.rn-build`, never beneath
`third-party/`. Keep JavaScript dependency installation and code generation in
their existing purpose-owned tasks, then consume their generated output through
the read-only source and writable build boundary. Keep SwiftPM compilation,
native SDK publication, linking, and runtime tests on the host so the produced
archives are qualified against the actual Swift toolchain and runner ABI.

Rebuild every native dependency from empty `.rn-build` subdirectories, publish
the RN SDK, compile the Swift C++ facade and host archive, and run the React
Native package tests. Repeat the build offline and prove task and compiler-cache
reuse. Confirm no containerized build writes into `third-party/`.

Qualification rebuilt Hermes, fmt, double-conversion, glog, Folly, JSI,
ReactCommon, ReactCxxPlatform, and Yoga in the offline container, linked the
host Swift C++ facade against the resulting libc++ archives, published the SDK,
and passed the React Native package tests. A repeated dry-run reports the RN
codegen, native archives, host archive, SDK publication, and final build clean.
Transient Node launcher symlinks resolve to the canonical executable for task
identity, so a new shell no longer invalidates codegen or its 50 dependent C++
objects. Obsolete Boost generations and generated type snapshots no longer
reside beneath `third-party/`.

## Phase 12: Delete the Generic First-Party Patch Pipeline

Delete the former Skia patch, every unused first-party patch file, and the
generic patch task model, hashing, execution, diagnostics, and tests. Remaining
patch files may only be dependency-manager inputs or upstream-owned fixtures;
Collider never applies them to first-party source trees.

## Phase 13: Verify the Unified Final State

Run the final acceptance sequence:

1. initialize the complete checkout recursively from the root gitlinks;
2. validate the Swift source graph and its fork ownership;
3. resolve every builder image to its declared immutable OCI digest;
4. run all Collider tests, including mount-policy and offline-build behavior;
5. rebuild the Linux host toolchain and supported Android SDKs in
   `swift-builder`;
6. validate all resulting toolchain and SDK products on the host;
7. repeat the toolchain build and prove external build-product reuse;
8. build host and Android Skia in `native-builder`;
9. run Skia GPU and compositor integration validation on the host;
10. build React Native native dependencies in `native-builder` and validate the
    Swift C++ facade, host archive, and package tests on the host;
11. repeat the React Native build and prove offline build-product reuse;
12. verify every selected submodule is clean and remotely resolvable;
13. verify build outputs exist only in declared writable roots;
14. verify no Nucleus task discovers or applies a first-party source patch;
15. verify no Linux build path falls back to undeclared runner compilers,
    libraries, packages, or host-native command execution.

## Final State

The monorepo owns orchestration, exact gitlink selection, build configuration,
artifact validation, and publication. Swift-family and Skia forks own all
downstream source changes. Collider is a clean-tree consumer with no Swift or
Skia source-management pipeline. Linux Swift, SwiftAndroid, Skia, React Native
native dependencies, and reusable native SDK compilation use pinned rootless
builders; host execution validates
their products against the real runner environment.

AOSP remains outside this submodule model because Repo is its native source
graph authority. Modified AOSP projects use exact `nucleus-os` fork revisions
in the manifest; unchanged projects retain canonical upstream remotes. Chromium
and CEF likewise retain their exact DEPS/gclient graph. AOSP, Chromium, and CEF
use their own purpose-owned builder images rather than sharing the Swift or
native builder. macOS toolchain work and hardware-dependent Vulkan, DRM, input,
compositor, and end-to-end runtime validation remain native runner jobs.
