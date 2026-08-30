# Linux lane configuration

Status: active

## Invariant

Each architecture has one Linux SwiftPM build context. A lane states the
configuration it builds rather than receiving one by omission, and two lanes
that compile the same package closure share a context rather than each keeping
their own.

## Established measurements

The release gates asked for `.release`. The Linux runtime lane, the compositor,
and wayland took `.debug`, which `RecipeBuildContextID.linux` supplied as a
default nobody chose. One package closure therefore compiled twice per
verification sweep, into `cache/swiftpm/linux-arm64/unsanitized` under two
digests: 1,471 s for 5,140 targets under the release gates and 804 s for 6,872
targets under the Linux lane, together 60% of a 63-minute sweep. Both builds
produce `NucleusReactRuntimeFabricTests-test-runner`; the graphs overlap almost
entirely.

Converging costs no checking. First-party Swift declares no `assert`,
`assertionFailure`, or `debugPrecondition`, so nothing is elided by optimization;
its 220 `precondition` calls are retained in release, as are bounds checks and
overflow traps, because no target builds `-Ounchecked`. Release is also what a
release gate has to measure to gate anything.

`RecipeBuildContextID.linux` no longer defaults its configuration, so every lane
now names one. That is the guardrail; the convergence itself is Phase 2.

## Phase 1: Make teardown independent of release timing

Status: complete

Running the Linux lane in release surfaced two latent defects that debug timing
concealed. Both are lifetime assumptions that an optimized build is free to
break, and neither is a property of the configuration that revealed them.

The first is fixed. `WaylandLoopbackTests` built its server-side globals into an
array and wrote `_ = globals`, which discards immediately rather than extending
a lifetime. `wl_global_create` keeps a raw pointer rather than a reference, so an
optimized build destroyed every global before the client's first round trip, and
the registry reported everything wanted and nothing bound.

The second is open. `RouterHost` is held `unowned` by the router's drivers and
scene feeder -- correctly, since production has the host own them and outlive the
session -- while in tests `WaylandTestGraph` is its only strong reference.
Released after its last read, every later call through a driver reads a destroyed
object, and `WlSurface.deinit` reaches one through `surfaceDestroyed`. Pairing
each construction with `defer { withExtendedLifetime(graph) {} }` fixes the
sixteen local bindings and the two that discarded the graph while keeping its
server. It does not fix the suites holding a graph as a stored property, and it
leaves the design question that produced the crash: whether a back-reference read
during deinitialization should tolerate a host already torn down, rather than
requiring every present and future test to pin the fixture.

The design question is settled, and the answer is a rule the module already
keeps everywhere else: a `deinit` does not read an `unowned` reference. ARC
deinitializes an owner before the cascade it triggers finishes, and `unowned`
is only guaranteed during ordinary use, which deinitialization is not. Of every
`deinit` in the Wayland runtime module, exactly one reaches outward, and it is
`WlSurface`'s -- the rest release only what they own.

So the outward half of that deinitializer moves to an explicit destruction entry
point: `roleSurfaceDestroyed`, `detachFromParent`, `detachSubsurfaceChildren`,
the pointer-cursor unbind, `removeSurface`, `deferBufferRelease`, and
`sceneDelegate.surfaceDestroyed`. A `wl_surface` is owned solely by its
resource's `user_data`, so the resource's destruction is the real destroy event
and the deinitializer is only its echo; `WaylandDisplay` already attaches
resource and client lifetime listeners through
`swift_wayland_resource_lifetime_listener_attach`, so the seam exists and is in
use. What stays in `deinit` is what the surface owns: frame callbacks,
presentation feedback, and the buffer-release contract.

Three alternatives were considered and rejected. Making the back-references
`weak` converts a lifetime error into a silent no-op and taxes
`RouterSurfaceSceneDriver.host`, which is read on every commit. Pinning the
fixture with `withExtendedLifetime` -- which is what currently holds the tests
together -- cannot cover a suite that holds its graph as a stored property, and
protects only the tests that exist today. Destroying the display before the host
does not apply at all: tests construct surfaces directly, with no `wl_resource`
to destroy.

`WlSurface` now announces its destruction through
`WaylandResourceOwnerLifetime.willDestroyResourceOwner()`, which the resource
destructor calls immediately before releasing the owner -- the last moment at
which the owner and everything it references are all still alive. `deinit`
keeps what the surface owns: frame callbacks, presentation feedback, and the
buffer-release contract. The hook is general rather than surface-specific, so
any resource owner with outward work to do at destruction can adopt it.

The rule had a second violation, in the wire-test harness rather than the
router: `WaylandTestClient.deinit` closed its socket and dispatched, which let
the server notice the closure and destroy the `wl_client` and every resource it
owned. That is the router's whole destruction path, run at whatever moment ARC
released the client. It is now an explicit `destroy()`; the deinitializer closes
only the descriptor it owns.

Achieved state, measured: `collider test runtime` passes 7/7 in release with
every pin removed, and no `deinit` reached from this graph performs outward
work.

## Phase 2: Converge the lanes

Status: complete

The Linux runtime lane, the compositor, and wayland state `.release`, and the
debug Linux context registration is removed. `collider test runtime` and the
release gates then share one scratch directory per architecture, which the run
log shows directly: the lane builds under the release gates' context digest
rather than one of its own.

Gate met. The Linux runtime lane, the compositor, and wayland state `.release`,
and the debug Linux context is no longer registered. `collider test runtime`
builds in `cache/swiftpm/linux-arm64/unsanitized/sha256-f80d0a448df6968d`, which
is the release gates' own context: one non-sanitizer Linux context per
architecture, and the second multi-thousand-target build of the same closure is
gone.

## Non-goals

- Do not converge the sanitizer lane. Sanitizers pair with debug because their
  reports name code that optimization is free to have moved or erased, and that
  lane duplicates no other.
- Do not pursue the convergence by weakening what the release gates measure.
  Running them against debug binaries would collapse the contexts and stop them
  gating the configuration that ships.
