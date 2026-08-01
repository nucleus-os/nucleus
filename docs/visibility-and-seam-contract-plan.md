# Visibility and Seam Contract Plan

Status: source implementation complete; full native verification remains pending.

## Invariant

Visibility follows the real consumer boundary.

`public` marks declarations required by supported Swift source consumers outside
the root Nucleus package. `package` marks first-party API shared across targets
inside that package. `internal`, `fileprivate`, and `private` remain lexical
implementation details.

Target dependencies and declaration visibility form one contract. A target
depends directly on every module whose package API it consumes. Unrelated
targets never gain dependencies merely to reach convenient implementation
helpers.

Import access describes which imported declarations may participate in this
module's API:

- `public import` supports a public declaration that exposes the imported type;
- `package import` supports package API;
- `internal import` supports implementation only;
- `@_exported import` is reserved for a deliberate source facade.

`public import` is not re-export syntax.

First-party `@_spi` is absent. A future SPI requires a concrete supported
consumer outside the root package and a documented reason that an ordinary
public product cannot express the boundary. Tests, harnesses, benchmarks, and
same-package production targets never justify SPI.

Tests use public/package API and `@testable` for module internals. Production
visibility never widens solely for a test.

## Supported Source Products

The complete supported external Swift source surface is:

- `Nucleus`, the portable app-authoring facade;
- `NucleusDesktop`, the desktop app-authoring and desktop-host facade;
- `NucleusReactRuntime`, the React Native integration facade;
- `NucleusFoundation`, the shared foundational facade;
- `NucleusSessionProtocol`, consumed by Collider as a separate package;
- `NucleusAndroidRuntimeCore`, consumed by Collider as a separate package.

Every supported source product has an out-of-package compiler fixture or a real
separate-package consumer. Adding another supported source product requires its
consumer gate in the same change. Removing one is an intentional source break.

A SwiftPM product can instead be a build, packaging, executable, or dynamic
linkage contract. Such a product does not make its declarations public. A
deployment-only library retains package-scoped Swift API unless a supported
external source consumer requires otherwise.

## Target Architecture

The root package owns the complete first-party runtime graph. Same-package
runtime seams use package access and direct target dependencies. Collider and
its engine remain separate packages and consume the root only through
`NucleusSessionProtocol` and `NucleusAndroidRuntimeCore`.

The four source facades remain explicit:

- `Nucleus` exports the portable authoring modules;
- `NucleusDesktop` exports `Nucleus` and the supported desktop contracts;
- `NucleusReactRuntime` exports the supported React runtime module;
- `NucleusFoundation` exports types, diagnostics, and host protocols.

Implementation modules do not become supported source surfaces merely because
a facade or dynamic product links them. A facade signature exposes only types
that intentionally belong to its source contract, and its corresponding import
uses public access.

`AsyncRenderWakeSink` belongs to `NucleusAppHostProtocols`, not the renderer.
Desktop hosts expose the host-owned wake contract without making
`NucleusRenderer` a public source module. `NucleusAppHostBundle` and the desktop
host's concrete bundle and text-system storage remain package implementation.

Wayland protocol modules are package implementation. The generator emits
package declarations, package extensions, and package imports so regenerated
source cannot widen the contract. `WaylandProtocolRuntime` is the deployment
library containing `WaylandProtocolTypes` and `WaylandProtocolsC`; there is no
pass-through Swift facade target.

Foreign-language entry points remain real boundaries. Swift declarations used
by C++ bridge construction or `@c`/`@c @implementation` entry points retain the
access required by that boundary. Surrounding Swift implementation remains
package or internal.

## Phase 1 — Record the Contract

This phase is complete.

`AGENTS.md` defines the visibility invariant, supported source products, facade
semantics, and distinction between source and deployment products. Runtime
comments describe package seams rather than historical SPI contracts.

## Phase 2 — Delete Speculative and Test-Only SPI

This phase is complete.

The shell sanitizer reaches `ShellRenderWakeSink` through package API. The
unused React `Host.attachSurface` SPI and its attachment-only host bookkeeping
are deleted. No speculative compositor embedding API remains. A future
embedding API lands only with its production consumer and behavior contract.

React mount materialization remains an internal tested subsystem. Its context
lifecycle is named directly through `registerContext` and `unregisterContext`;
it is not presented as an external attachment seam.

## Phase 3 — Replace Same-Package SPI

This phase is complete.

The render-server, window-client implementation, renderer/platform, shell,
and compositor seams use package declarations. Their consumers use package,
internal, or `@testable` imports according to the API they consume. First-party
source contains no SPI declaration or SPI import.

The declaring targets retain only the dependencies required by their intended
consumers. Package access does not substitute for dependency-graph ownership.

## Phase 4 — Establish External Consumer Gates

This phase is complete.

`integration-tests/public-source-contracts/` is a separate Swift package with
four clients:

1. `PortableAuthoringClient` imports `Nucleus` and constructs a minimal
   application and view hierarchy.
2. `DesktopClient` imports `NucleusDesktop` and constructs the desktop host
   boundary.
3. `ReactRuntimeClient` imports `NucleusReactRuntime` and constructs the
   supported React host.
4. `FoundationClient` imports `NucleusFoundation` and exercises foundational
   values.

The fixture behavior test links only `FoundationClient`. Each client target
builds separately because the root dynamic products represent separate
deployment closures. Collider's package build is the external source gate for
`NucleusSessionProtocol` and `NucleusAndroidRuntimeCore`.

These gates compile and exercise behavior. They never inspect source modifiers,
probe for absent declarations, or assert source shape.

## Phase 5 — Reduce Implementation Visibility

This phase is complete at the source level.

Reduction follows dependency order:

1. Executable, service, shell, sanitizer, benchmark, generator, and test-support
   implementation converts to package access.
2. Renderer, render-model, render-host, compositor, Linux platform,
   window-client implementation, React implementation, and Android
   implementation convert to package access.
3. Facade backing modules retain public declarations only when a supported
   external signature or foreign-language boundary requires them.
4. `NucleusTypes` values remain public only when `NucleusUI`,
   `NucleusFoundation`, or another supported contract exposes them.
5. Imports are narrowed to public, package, or internal access according to the
   broadest declaration in which their types appear.

Dynamic and executable products invoked by Collider or required by runtime
packaging remain manifest products. Automatic library products with no source,
build, deployment, or packaging consumer are removed when identified; a target
does not need a same-package product wrapper.

## Phase 6 — Reconcile Facades and Wayland Deployment

This phase is complete at the source level.

`Nucleus`, `NucleusDesktop`, `NucleusFoundation`, and `NucleusReactRuntime`
remain deliberate `@_exported import` facades. External fixtures, rather than
same-package tests, define whether those facades are complete.

`SwiftWaylandProtocolRuntime` and its pass-through source target are deleted.
The dynamic product is `WaylandProtocolRuntime`. Same-package consumers depend
directly on `WaylandProtocolTypes`, `WaylandProtocolsC`, and the dispatch modules
they use. The generator and checked-in generated Swift sources use package
access consistently.

## Verification

Source-only checks establish that:

- no first-party SPI declaration or import remains;
- the deleted React attachment symbols have no call site;
- generated Wayland source and its generator use the same package visibility;
- supported facades and public signatures use explicit public import access;
- the root manifest contains no reference to the deleted Wayland facade target.

Full verification runs only in a provisioned host environment, after sourcing
`tools/host-env.sh`, in this strict order:

1. build `FoundationClient`, `PortableAuthoringClient`, `DesktopClient`, and
   `ReactRuntimeClient` separately;
2. run the external fixture behavior test;
3. run Collider's package tests;
4. run `collider build all`;
5. run `collider test all`;
6. run `collider sanitize all`;
7. run the Swift 6.4 `InternalImportsByDefault` diagnostic build;
8. run the Swift 6.4 `MemberImportVisibility` diagnostic build.

The source implementation does not claim these native gates passed while the
required SDK and toolchain environment is unavailable. That verification is a
validation handoff, not an alternate architecture.

Every touched Swift file is formatted with the pinned `swift-format` and the
root `.swift-format` contract when that toolchain is available.

## Enforcement

The compiler and behavior tests enforce the contract:

- external fixtures prove public source API from outside the root package;
- root builds prove package seams and direct target dependencies;
- import-access diagnostics prevent implementation dependencies from leaking
  into broader API;
- behavior and sanitizer suites prove runtime behavior independently of source
  visibility;
- review owns every new supported product, facade export, public declaration,
  or external SPI.

No enforcement test scans source for modifiers, counts declarations, asserts
that an API is absent, or treats a symbol inventory as behavior.

## Out of Scope

`@testable` remains the mechanism for a test target to reach the internals of
one module. Package API is not widened for tests that can use it.

Private and fileprivate distribution is unchanged except where dead code is
deleted with a removed entry point.

The C++ interop architecture is unchanged: C++ bridge subclasses retain Swift
instances, public headers avoid importer cycles with opaque pointers, C entry
points use `@c` forms, C headers preserve `extern "C"` linkage, and Swift-facing
C++ entry points contain exceptions behind `noexcept` boundaries.
