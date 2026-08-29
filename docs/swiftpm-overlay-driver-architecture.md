# SwiftPM Overlay Driver Architecture

## Invariant

Collider owns repository-scale orchestration, placement, artifact identity,
isolation, and publication. The pinned SwiftPM overlay owns package resolution,
package-graph semantics, plugins, test discovery, PIF construction, SwiftBuild
execution, and llbuild-backed incrementality. Collider never reproduces those
package-manager semantics and never invokes llbuild directly.

## Process Boundary

Production Linux build and test actions run the Nucleus driver from the exact
SwiftPM/SwiftBuild overlay mounted read-only at `/swiftpm-overlay`. The driver is
a command mode of the unified `swift-package-manager` executable, selected as
`swift-nucleus-driver`; it is not linked into Collider and does not move
toolchain code into the macOS orchestrator process.

An OCI action whose execution configuration names no overlay executable invokes
the official toolchain's SwiftPM directly. The overlay's own build and the
target-SDK runtime builds are exactly those actions: the driver does not exist
until the overlay that carries it has been built. This is bootstrap ordering,
not a retained alternative, and no action the overlay can serve may take that
path.

This process boundary is deliberate. The implementation APIs belong to the
pinned SwiftPM and SwiftBuild revisions and execute in the offline Linux build
environment beside the compiler and target SDK they control. Collider remains a
small, stable host executable whose identity does not absorb SwiftPM,
SwiftBuild, llbuild, or their dependency closure.

## Request and Event Contract

Collider lowers each OCI build, prebuild target, test invocation, and products
path query into a typed request. The request carries the operation, exact
selection, test filters and scheduling, package and scratch placement, build
system, target, SDK and toolsets, compiler and linker flags, traits, sanitizer,
parallelism, and resolved-file policy. It is serialized as JSON only while
crossing the process boundary; neither side reconstructs or parses a human
SwiftPM command line.

The driver maps that request directly into SwiftPM's option and command models.
Builds use `SwiftCommandState.createBuildSystem` and `BuildSystem.build`, tests
use the SwiftPM test command implementation, and product discovery uses the
selected build system's `buildProductsPath` API. Selecting `swiftbuild` therefore
uses SwiftBuild through SwiftPM's own integration and PIF generation rather than
through a second Collider implementation.

The driver writes newline-delimited structured events for start, progress,
command start, command finish, and completion. Completion is authoritative:
Collider requires a successful completion event and takes the published product
path from that event. Ordinary compiler and test output remains ordinary process
output and cannot corrupt the control stream.

The request and event shapes are one internal same-build contract. Collider and
the driver ship from the same monorepo revision and the overlay revision is part
of every consuming task identity, so the contract has no compatibility version
or legacy reader.

## Offline Acquisition and Publication

Networked dependency acquisition remains a host-side SwiftPM operation. It
materializes the exact `Package.resolved` closure before OCI execution because
containers never access external networks. This acquisition seam does not
compile products and does not duplicate package resolution logic in Collider.

The driver returns the build system's actual product directory. The native
builder entrypoint copies that directory into the bounded host export while
preserving the driver's control events, and the completion event names the
host-visible export. Collider then publishes its stable products link without
reconstructing SwiftPM or SwiftBuild scratch layouts.

## Extension Rule

New package operations extend the typed request, direct SwiftPM implementation,
and structured event model together. They do not add raw trailing argument
arrays, scrape console text, link SwiftPM into Collider, bypass SwiftPM to call
llbuild, or give an action the overlay can serve a parallel CLI-based OCI path.

Every request field reaches task identity, through the build context's identity
encoding or through the operation's identity arguments. A field in neither
cannot re-key its task, so a changed request would serve the previous result.
