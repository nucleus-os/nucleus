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

## Phase 1: Define the installed product contract

Add one machine-readable product manifest under `swift-toolchain/`. It is the
source of truth for preset generation, component fingerprinting, installation,
smoke tests, and packaging.

The manifest declares:

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

Remove duplicated product-selection decisions from build-script argument
construction. Linux and macOS presets consume the same contract and add only
platform-specific configuration.

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

1. IndexStoreDB.
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
- IndexStoreDB libraries and modules.
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

Add a validator that compares the assembled candidate with both the product
contract and a pinned capability snapshot from the corresponding official
Swift.org toolchain.

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

## Phase 8: Integrate the contract into `tools/nucleus`

Expose the complete workflow through the existing top-level command:

- `tools/nucleus doctor` verifies sources, submodules, host prerequisites,
  component revisions, and product-manifest consistency.
- `tools/nucleus build` constructs, assembles, validates, and atomically
  publishes the complete toolchain as part of the staged bootstrap graph.
- `tools/nucleus test` runs the functional toolchain and Nucleus integration
  gates.
- A parity report lists required, found, mismatched, missing, and
  Nucleus-specific capabilities for the current candidate or installed
  toolchain.

Build and cache diagnostics name the owning product and its exact invalidation
inputs. No component may be skipped merely because an older candidate lacks its
artifacts.

## Completion Gate

The plan is complete when a fresh Linux candidate and a fresh macOS candidate:

1. Satisfy the machine-readable product contract.
2. Match the official distribution capability snapshot.
3. Provide LLDB and the Swift REPL.
4. Complete the SourceKit-LSP editor protocol test.
5. Pass Swift Format, DocC, and WasmKit functional tests.
6. Compile with dynamic, static, and embedded Swift runtimes.
7. Advertise the official LLVM backend set.
8. Build and test Nucleus through `tools/nucleus`.
9. Publish atomically with no bootstrap or temporary-path references.
