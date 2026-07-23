# Swift Toolchain Official Distribution Parity Plan

## Invariant

A published Nucleus Swift toolchain exposes the same developer tools, compiler
targets, runtimes, and installation layout as the corresponding official
Swift.org toolchain. Nucleus-specific Android support, libc++ configuration,
and other additions extend that surface; they never replace or silently remove
an official product.

The complete product contract is enforced before the `current` toolchain
pointer changes. A partial toolchain is a failed build, not a supported build
profile.

The build system is the product contract. Preset build targets, preset install
targets, post-assembly assertions, and functional smoke tests directly define
the shipped surface. Do not maintain a second product manifest that can drift
from the executable build graph.

## Progress and Decisions

- [x] Audited the Linux and macOS builders against the official distribution
  surface.
- [x] Confirmed upstream Linux builds and installs
  `swift-corelibs-libdispatch` and `swift-corelibs-foundation` as toolchain
  components. The Foundation build incorporates `swift-foundation` and
  `swift-foundation-icu`. Darwin intentionally uses the OS Foundation and
  libdispatch instead.
- [x] Confirmed upstream Swift's LLDB configuration uses checked-in static
  Python bindings, so SWIG is not a host prerequisite. Python development
  headers are required and are declared through `libpython3-dev`.
- [x] Chose the generated presets and mandatory validation code as the single
  executable product contract; no parallel JSON contract is used.
- [x] Removed the SwiftPM C++-interop test-runner patch after confirming the
  current upstream runner applies the unit-test module's complete manifest
  settings. Upstream's regression test covers inherited linker settings, not
  the former Nucleus patch's exact `.interoperabilityMode(.Cxx)` case.
- [x] Audited all 13 remaining source patches against the live `release/6.4.x`
  and `main` branches of `swift`, `swift-driver`, and `swift-build`. Every patch
  still applies to both branches, and the unpatched source still contains each
  behavior the patches correct. No remaining patch is superseded upstream.
  Upstream's existing Linux libc++ support assumes a system-wide libc++ and
  does not replace Nucleus's bundled-default-libc++ include-path fix.
- [x] Removed `swift/0006-android-cxxstdlib-wchar-workaround.patch` after an
  ordered host-then-Android control build proved it was a bootstrap-only
  duplicate. The qualified host compiler from generation
  `2026-07-23T00-15-15Z-1452180` contains `swift/0001`'s Android ClangImporter
  wchar guard. With `0006` temporarily reversed and the aarch64/API 36 graph
  forcibly reconfigured against NDK 30.0.14904198, the generated graph
  contained no explicit workaround flag and rebuilt the Android stdlib,
  dynamic/static Foundation, Swift Testing, and XCTest successfully. Both
  dynamic and static resource trees then compiled fresh `CxxStdlib` consumers.
  The durable control log is
  `~/.cache/nucleus/swift-android-sdks/release-6.4.x/logs/0006-revalidation/build-20260722-191037.log`.
  Strengthening the installed-SDK test to exercise `std.string` exposed a
  separate bundle defect: upstream installs the static `libswiftCxx.a` and
  `libswiftCxxStdlib.a` overlays only in the regular resource tree, while a
  `--static-swift-stdlib` consumer searches only the static resource tree. The
  Linux and macOS assemblers now require and copy both archives into the static
  variant. A standalone bundle built from the no-`0006` graph then passed the
  full dynamic and static SwiftPM consumer gate. That bundle's durable build
  log is
  `~/.cache/nucleus/swift-android-sdks/release-6.4.x/logs/0006-revalidation/build-20260722-191955.log`.
  The installed-SDK gate permanently covers this compiler and packaging
  contract so neither side can regress silently.
- [x] Preserve the exact C++-interop runner behavior as a candidate-toolchain
  `swift test` smoke so the installed SwiftPM and synthesized test executable
  are exercised end to end without carrying an upstream implementation patch.
  The first candidate reached this gate and exposed an error in the smoke
  fixture itself: a public empty struct still has an internal synthesized
  initializer. The fixture now declares its initializer public, and a control
  run with the active toolchain built and executed the synthesized C++-interop
  test runner successfully. The next packaged candidate repeated that test with
  its installed SwiftPM and completed the full functional validation suite.
- [x] Confirmed upstream already implements the candidate-hosted developer
  product stage: it installs the compiler and core libraries before invoking
  the unified SwiftPM product builds with that installed candidate and the
  multiroot data file.
- [x] Confirmed IndexStoreDB is a build dependency of SourceKit-LSP rather than
  a separately installed official library. `libIndexStore` is the installed
  LLVM product; validation follows that upstream boundary.
- [x] Made configuration changes invalidate the Swift CMake directory before
  reconfiguration. CMake's in-place compiler-change recovery discards the
  generated libdispatch and cmark paths and cannot be used for this build.
- [x] Moved orchestrated toolchain and Android build logs out of disposable
  generations into the platform-level log directory. A failed generation can
  now be removed without deleting the diagnostic log or its `latest.log` link.
- [ ] Derive compiler, runtime, and tool artifact identities from their own
  generated preset inputs and patches. Changes confined to validation or one
  product group must not invalidate and rebuild every component.
- [x] Made the existing component identities the sole owner of Linux
  incremental-build invalidation and enabled upstream's `skip-clean-*`
  controls for libdispatch, Foundation, XCTest, llbuild, SwiftPM, and Swift
  Driver. These operational controls are added after hashing the
  artifact-producing preset, so enabling reuse does not invalidate a
  compatible interrupted build.
- [ ] Make Swift Testing and Swift Testing Macros honor the same fingerprint
  invariant instead of unconditionally cleaning their build directories in
  their upstream product implementations. Establish equivalent component
  identities before enabling skip-clean behavior in the macOS builder.
- [ ] Route every C and C++ CMake product through the build-script's supported
  compiler-launcher seam and the persistent Nucleus compiler cache. The
  current LLVM-only `LLVM_CCACHE_BUILD` wiring leaves libdispatch, Foundation,
  LLDB, and developer-tool C/C++ actions outside the cache. Keep Ninja as the
  executor: `autoninja` is only a Chromium launcher, while Siso cannot replace
  the SwiftPM/SwiftBuild product graph and provides no remote-execution benefit
  without a configured REAPI service. Benchmark a Siso experiment only after
  invalidation and cache coverage are correct.
- [ ] Qualify Swift's native CAS compilation cache for the candidate-hosted
  SwiftBuild products, using a stable cache path outside disposable build
  directories with an explicit size policy and hit-rate/correctness gates.
  This targets Swift Format, SourceKit-LSP, DocC, SwiftPM, and other Swift
  frontend work that neither `ccache` nor Siso can cache.
- [ ] Remove redundant product builds from install helpers and use parallel
  gzip for the installable package. The stable-path qualification run spent
  145.83 seconds installing DocC after a 41.09-second DocC build, 60.55 seconds
  installing Swift Driver after a 66.94-second build, 93.73 seconds in
  upstream's single-threaded gzip packaging phase, and another 96.11 seconds
  repackaging the same tree for Nucleus validation.
- [x] Removed credential-shaped environment variables before entering the
  compiler graph because upstream verbose helpers can print their complete
  inherited environment. Redacted the affected durable log from the first
  qualifying run; the exposed external credential still requires rotation.
- [x] Bound the default source-build concurrency to 16 jobs after a 32-job
  compiler build exhausted 64 GiB of RAM and all swap. The explicit jobs
  environment override remains available for dedicated build hosts.
- [x] Track the component identities already prepared by an in-progress build.
  Retrying an interrupted candidate now resumes partial build directories
  instead of deleting them again merely because publication has not completed.
- [x] Gave candidate-hosted developer-product builds a real stable
  compiler/install staging directory. The earlier symlink design was
  insufficient because the Swift driver canonicalized the target and recorded
  the private `.assembly.<pid>` path in `-print-target-info` and SwiftBuild
  databases. Developer-tool identity schema 2 performs the one-time migration;
  the completed staged `usr` tree moves into the private assembly before
  validation and atomic publication.
- [ ] Preserve already-applied patched source trees when both the repository
  revision and patch-set identity are unchanged. Resetting every patched file
  to `HEAD` and reapplying identical patches changes mtimes, which relinks the
  compiler and unnecessarily regenerates every downstream embedded runtime.
- [x] Propagate configuration/compiler identity changes through the runtime and
  developer-tool build directories even when CMake reconfiguration is active.
  The previous guard reconfigured CMake products but incorrectly retained an
  older SwiftBuild database for WasmKit. The invalidation schema now prevents
  candidates prepared under those older reuse semantics from being resumed.
- [x] Activated and verified the required 32 GiB swap file, then completed the
  compiler, LLDB, shared and static Foundation, Swift Testing, and SwiftPM
  stages without memory exhaustion.
- [x] Reproduced WasmKit's missing manifest executable independently of its
  build directory and identified the actual cause: the build environment set
  `SWIFT_EXEC` to the `swift` interpreter instead of the `swiftc` compiler
  driver. Interpreter mode returned success without emitting the requested
  manifest binary, so SwiftPM's following spawn reported a misleading ENOENT.
  Linux, macOS, and installed-product validation now set `SWIFT_EXEC` to
  `swiftc`. The newly built SwiftPM binary completes the pinned WasmKit release
  build when given that compiler-driver invariant.
- [x] Diagnosed the first complete candidate's static-executable validation
  failure as a mismatch between the custom Clang default of libc++ and
  upstream Swift's Linux response file for libstdc++. The Nucleus Swift source
  patch now records the complete installed libc++, libc++abi, LLVM libunwind,
  and FoundationXML/zlib closure. A standalone FoundationXML static executable
  links and runs with that exact library set.
- [x] Replaced the unsupported `sourcekit-lsp --version` readiness probe with
  `--help`. This SourceKit-LSP revision exposes functional protocol behavior
  but intentionally has no version option; the full initialize, diagnostics,
  symbols, definition, and shutdown exchange remains the actual validation.
- [x] Replaced the unsupported `docc --version` readiness probe with `--help`.
  This DocC revision reports its command surface but has no version option; a
  real documentation-catalog conversion remains the functional validation.
- [x] Reproduced the retry-only SwiftPM bootstrap failure as a deterministic
  CMake Swift relink defect: an unchanged one-file executable built through the
  old combined incremental compile-and-link rule fails on its second identical
  invocation with `cannotResolveTempPath(main-1.swiftmodule)`. The Swift Driver
  patch now selects CMake's CMP0157 compilation-mode abstraction when available,
  assigns valid underscore module names to its hyphenated executables, and
  preserves incremental object compilation with separate link actions. A clean
  targeted CMake/Ninja build produced both executables, repeated direct relinks
  succeeded, and the second Ninja build was a no-op. The complete candidate
  rebuild then built all three Swift Driver executables through the split graph;
  SwiftPM's install-time second invocation reported no work for the dependency
  and passed the former failure point. The candidate subsequently built and
  installed Swift Format, SourceKit-LSP, DocC, WasmKit, and standalone Swift
  Driver, then passed the packaged compiler, Foundation, static-link, embedded,
  LLDB, and tool-presence probes. Publication stopped only at the invalid
  access-control setup in the C++-interop smoke fixture described above.
- [x] Completed and activated Linux generation
  `2026-07-23T00-15-15Z-1452180`. Its packaged host toolchain passed compiler,
  dynamic and static FoundationXML, embedded target, LLDB, Swift Format, DocC,
  WasmKit, C++-interop test-runner, SourceKit-LSP protocol, SwiftPM package, and
  product-surface validation. Its Android artifact bundle passed both dynamic
  and static `aarch64-unknown-linux-android36` consumer builds before the
  combined generation's active pointer changed.
- [x] Restore the official core compiler, debugger, backend, and runtime
  product set.
- [x] Build candidate-hosted developer products in dependency order.
- [x] Enforce product, linkage, functional, and official-capability parity
  before publication.
- [x] Expose and verify the complete workflow through `tools/collider`.
- [ ] Complete fresh Linux and macOS qualification.

## Phase 1: Make the build graph the installed product contract

The generated Linux and macOS presets are the source of truth for component
selection. Every product appears as an explicit build target and install target
in the appropriate host preset. Product source revisions participate directly
in the existing component fingerprints.

The executable contract declares:

- Required command-line products: Swift, Clang, LLDB, the Swift REPL,
  `lldb-dap`, `lldb-server`, `lldb-argdumper`, SourceKit-LSP, Swift Format,
  DocC, and WasmKit.
- Required shared libraries, SourceKit plugins, Swift modules, resource
  directories, and SDK overlays.
- Required dynamic, static, and embedded standard-library products.
- The official LLVM backend set: AArch64, ARM, AVR, BPF, MIPS, PowerPC,
  RISC-V, SystemZ, WebAssembly, and X86.
- Platform-specific Linux and macOS products and installation paths.
- Nucleus additions and every intentional deviation from the matching official
  distribution.

Post-assembly assertions and functional smoke tests enforce the same surface
before packaging and publication. Linux and macOS retain separate platform
configuration but use the same product policy: an official shipped product is
never silently disabled.

## Phase 2: Restore compiler and runtime capability

Update the core upstream build stage before adding higher-level tools:

1. Restore the official LLVM backend set.
2. Build and install LLDB, the Swift REPL, `lldb-dap`, `lldb-server`, and
   `lldb-argdumper`.
3. Build and install the embedded standard library.
4. Build and install static SDK overlays alongside the existing static standard
   library.
5. Preserve Android artifacts as explicit Nucleus additions beside the host
   toolchain.
6. Keep a WASI SDK as a separate supported SDK product. WasmKit remains part
   of the host developer-tool surface regardless of WASI SDK support.

This phase lands with compiler-target enumeration, embedded and static compile
smokes, and an LLDB batch session that compiles, starts, breaks in, and exits a
small Swift executable.

## Phase 3: Establish the candidate-toolchain product stage

Make the build dependency direction explicit:

```text
bootstrap compiler
        -> core candidate toolchain
        -> developer products built with the core candidate
        -> assembled candidate
        -> parity and functional validation
        -> atomic publication
```

The core candidate contains the compiler, LLVM, LLDB, runtimes, package
manager, and libraries needed to build SwiftPM-hosted developer products. The
developer-product stage uses that candidate as its compiler and SDK; it does
not use the bootstrap toolchain.

Build the following products in dependency order:

1. IndexStoreDB as SourceKit-LSP's build dependency.
2. SourceKit-LSP and its SourceKit plugins.
3. Swift Format.
4. DocC.
5. WasmKit.

All products install into the same candidate using the official directory
layout. The candidate remains private until every stage and validation gate
succeeds.

## Phase 4: Restore SourceKit as a required product

Reproduce the previously documented SourceKit failure with current component
revisions and capture the exact command, environment, and diagnostics. Replace
the fragile multiroot construction path with the candidate-toolchain product
stage from phase 3.

Build IndexStoreDB first, then build SourceKit-LSP against it and the core
candidate. Install:

- `sourcekit-lsp`.
- The SourceKit client and server plugins.
- `libIndexStore` from LLVM. IndexStoreDB remains a build dependency, matching
  the official upstream install boundary.
- Supporting runtime resources in their official locations.

Validate a real editor protocol exchange against a small Swift package:

1. Initialize the server.
2. Open the workspace.
3. Wait for indexing to settle.
4. Request diagnostics and document symbols.
5. Resolve a definition across package targets.
6. Shut the server down cleanly.

Delete the permanent SourceKit and IndexStoreDB exclusions and retire the
obsolete deferral. A SourceKit failure fails the complete toolchain build.

## Phase 5: Restore the remaining shipped developer tools

Build Swift Format, DocC, and WasmKit through the candidate-toolchain product
stage. Their source revisions, build arguments, dependency revisions, and
candidate compiler identity participate in the toolchain fingerprint.

Add functional validation for each product:

- Swift Format formats a source file, verifies it, and reports the expected
  toolchain version.
- DocC converts a minimal documented Swift package and emits a valid archive.
- WasmKit validates and executes a minimal WebAssembly module.
- Every installed executable starts without resolving libraries from a build,
  bootstrap, or temporary directory.

## Phase 6: Enforce official-distribution parity

Add mandatory validation that compares the assembled candidate with the
products selected by the build graph and a captured capability report from the
corresponding official Swift.org toolchain.

Validate capabilities and installation shape rather than byte-for-byte output:

- Required executables, libraries, plugins, modules, resources, and SDK
  overlays exist.
- Executables report the candidate version and use the candidate resource
  directory.
- Dynamic linkage, interpreter paths, RPATHs, and plugin discovery stay within
  the installed toolchain and host system contract.
- Static and embedded compilation succeeds.
- The LLVM target list matches the declared official set.
- LLDB, SourceKit-LSP, Swift Format, DocC, and WasmKit pass their functional
  smokes.
- No installed file refers to bootstrap, checkout, cache-candidate, or temporary
  build paths.
- Nucleus additions are reported separately from official parity requirements.

Any missing or mismatched requirement prevents atomic publication.

## Phase 7: Unify Linux and macOS preset policy

Generate both host presets from the product contract. Remove explicit
disablement for shipped products and remove the policy that makes macOS mirror
Linux omissions.

There is one production toolchain product. Do not introduce minimal, full,
legacy, or feature-flagged variants. Incremental builds remain component-aware,
but every successfully published candidate has the complete installed surface.

Keep validation workload separate from installed product selection:

- Unit and focused integration tests run with their owning components.
- Toolchain functional and parity tests run before publication.
- Long, stress, benchmark, and upstream CI-only suites remain outside the
  ordinary production build.
- An exhaustive qualification entry point runs the extended upstream suites
  without changing which products are installed.

## Phase 8: Integrate the contract into `tools/collider`

Expose the complete workflow through the existing top-level command:

- `tools/collider doctor` verifies sources, submodules, host prerequisites,
  component revisions, and product-manifest consistency.
- `tools/collider build` constructs, assembles, validates, and atomically
  publishes the complete toolchain as part of the staged bootstrap graph.
- `tools/collider test` runs the functional toolchain and Nucleus integration
  gates.
- A parity report lists required, found, mismatched, missing, and
  Nucleus-specific capabilities for the current candidate or installed
  toolchain.

Build and cache diagnostics name the owning product and its exact invalidation
inputs. No component may be skipped merely because an older candidate lacks its
artifacts.

## Completion Gate

The plan is complete when a fresh Linux candidate and a fresh macOS candidate:

1. Satisfy every build-selected product assertion and functional smoke.
2. Match the official distribution capability snapshot.
3. Provide LLDB and the Swift REPL.
4. Complete the SourceKit-LSP editor protocol test.
5. Pass Swift Format, DocC, and WasmKit functional tests.
6. Compile with dynamic, static, and embedded Swift runtimes.
7. Advertise the official LLVM backend set.
8. Build and test Nucleus through `tools/collider`.
9. Publish atomically with no bootstrap or temporary-path references.
