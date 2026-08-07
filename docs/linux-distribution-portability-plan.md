# Linux Distribution Portability Plan

Status: active

## Invariant

Nucleus produces one Linux runtime artifact for each supported architecture. The
same artifact runs unchanged across supported glibc-based Linux distributions.
Distribution packages install that artifact and satisfy its host integration
requirements; they never select a different build, patch Nucleus, or introduce a
distribution-specific runtime path.

The supported Linux platform requires:

- arm64 or x86_64;
- a declared minimum glibc ABI;
- DRM/KMS, GBM, udev, and libinput;
- a Vulkan loader and a driver satisfying Nucleus's required Vulkan features;
- Wayland and Xwayland;
- libseat with either seatd or logind;
- D-Bus;
- PAM; and
- systemd user services.

Systemd is part of the initial platform contract. Supporting a distribution that
uses another service manager requires a concrete product requirement and a later
replacement of the systemd-dependent session boundary. It does not add alternate
code paths to this plan.

## Current State

The compositor, window manager, shell, and session protocol are Linux-facing and
contain no essential Ubuntu product architecture. Collider now declares glibc
2.38 as the minimum Linux ABI and classifies the supported ELF closure by SONAME
as either artifact-owned or host-owned. Unknown dependencies fail staging and
validation.

- the target Swift SDK is published as `nucleus-linux-glibc-2.38.sdk` beneath
  each architecture triple;
- Ubuntu Noble packages remain pinned SDK assembly inputs but do not appear in
  installed SDK paths or metadata;
- SDK and runtime validation reject glibc imports newer than `GLIBC_2.38`;
- libc++, libc++abi, libunwind, the Swift runtime, and Nucleus-owned native
  libraries are artifact-owned;
- glibc, graphics, input, seat, PAM, and service-manager libraries are
  host-owned by explicit SONAME;
- runtime staging uses the ownership contract regardless of the dependency's
  filesystem location;
- the only development-package inventory is `compositor/packages/ubuntu.txt`;
- installation always emits and validates a systemd user unit; and
- PAM authentication defaults to the host's `login` service when no service is
  supplied.

The Ubuntu package closure is a build input, not a valid definition of the
Nucleus Linux runtime contract. Filesystem location is also not a valid ownership
rule for an ELF dependency.

## Phase 1: Define the Linux ABI Contract

Status: complete

Declare the minimum supported glibc version and the host-owned ELF SONAME set in
Collider. The contract covers both arm64 and x86_64 and is identical for every
supported distribution.

Classify runtime dependencies into exactly two groups:

1. Artifact-owned libraries ship in the Nucleus runtime. This includes the Swift
   runtime, libc++, libc++abi, libunwind, and native libraries built and owned by
   Nucleus.
2. Host-owned libraries remain external because they represent the operating
   system, hardware stack, or security policy. This includes glibc and its dynamic
   loader, Vulkan drivers, DRM and GBM device integration, udev, libinput,
   libseat providers, PAM modules, and other explicitly named platform libraries.

Record the required SONAME and ABI expectations for every host-owned library.
Reject unclassified dynamic dependencies. Remove filesystem-prefix inference from
runtime dependency ownership.

Gate satisfied: Collider explains the owner of every staged ELF dependency from
its SONAME without consulting where the builder installed it. The runtime ELF
report records the minimum glibc ABI and the owner of every direct dependency.

## Phase 2: Establish a Distribution-Neutral Target SDK

Status: complete

Replace the Ubuntu Noble runtime ABI baseline with a Nucleus Linux SDK whose
identity states the architecture and minimum Linux ABI rather than the package
distribution used to assemble it.

The SDK contains:

- the declared glibc baseline and dynamic-loader contract;
- current headers for the required Linux, Wayland, Vulkan, and graphics APIs;
- the Nucleus-built Swift target runtime and overlays;
- libc++, libc++abi, and libunwind for the target architecture; and
- link-time representations of every explicitly host-owned library.

Package archives may remain pinned source material for SDK assembly, but their
distribution names do not appear in installed SDK paths or artifact identities.
Collider validates the resulting sysroot rather than assuming that its source
packages imply the required ABI.

Gate satisfied: both architecture lanes resolve the distribution-neutral SDK
path, generated metadata contains no distribution identity, and SDK validation
rejects produced executables or artifact-owned runtime libraries importing a
glibc symbol newer than the declared minimum.

## Phase 3: Make Runtime Staging Deterministic

Change runtime staging to follow the ownership contract from Phase 1.

Collider copies every artifact-owned transitive dependency into the staged
runtime regardless of its location inside the builder. It leaves every
host-owned dependency external regardless of whether an incidental copy exists
outside a conventional system directory. It fails on basename collisions,
unclassified dependencies, absolute dependency paths, unresolved relocations,
and undeclared ABI requirements.

All executables retain origin-relative runpaths. Artifact-owned libraries retain
origin-relative lookup within the runtime's `lib` directory. The staged tree does
not embed builder paths, target-SDK paths, container paths, or distribution names.

Gate: rebuilding the same source and inputs in independently provisioned builders
produces the same runtime dependency closure.

## Phase 4: Separate Runtime Layout from Host Integration

Keep the relocatable generation-based runtime layout as the only installed
product layout. Move host integration outputs into an explicit installation
payload alongside that runtime.

The common payload owns:

- Nucleus executables and artifact-owned libraries;
- session launch scripts;
- the systemd user-unit template;
- desktop and compositor session entries;
- D-Bus service and activation files;
- the dedicated Nucleus PAM service template; and
- machine-readable host capability requirements.

The systemd unit resolves the active runtime prefix without embedding a candidate
generation path. The session launcher continues to construct the private D-Bus,
Wayland, and XDG environment. It does not call a distribution package manager.

Replace the fallback to the generic `login` PAM service with a required `nucleus`
PAM service. Distribution integration installs an appropriate policy for that
service; the shell and helper do not infer a substitute.

Gate: the common installation payload can be placed under an arbitrary absolute
prefix and validated without Ubuntu package metadata.

## Phase 5: Add Distribution Packaging Adapters

Create packaging adapters that translate the common host capability contract into
distribution-native package dependencies and filesystem integration. Begin with
Ubuntu/Debian packaging, then add RPM-family and Arch-family packaging in that
order.

Each adapter performs only these responsibilities:

- declare package-manager dependencies for host-owned capabilities;
- install or reference the common Nucleus runtime payload;
- install systemd, D-Bus, desktop-session, and PAM integration files in the
  distribution's standard locations;
- establish the required seat and device-access policy; and
- remove those integration files cleanly when the package is removed.

Delete `compositor/packages/ubuntu.txt` after its remaining information has moved
into the Ubuntu/Debian adapter. No distribution adapter supplies compiler or
development packages to the product at runtime.

Gate: every adapter consumes the same architecture artifact and contains no
source-build logic.

## Phase 6: Qualify One Artifact Across Distributions

Build each architecture once. Exercise that exact staged artifact in a sequential
runtime matrix containing:

1. an environment at the minimum supported glibc ABI;
2. a conservative stable systemd distribution;
3. a current systemd distribution; and
4. a rolling systemd distribution.

Each environment validates:

- ELF loading and relocation;
- Swift and C++ runtime availability from the staged artifact;
- systemd user-unit validity;
- private D-Bus session construction;
- PAM service discovery without performing an interactive authentication;
- Wayland and Xwayland process discovery;
- libseat backend discovery;
- Vulkan loader and ICD discovery; and
- compositor, shell, and supervisor startup through noninteractive lifecycle
  tests.

The matrix does not rebuild Nucleus and does not maintain distribution-specific
expected binaries. Failures identify either a violated platform contract or an
incorrect packaging adapter.

Gate: the same artifact digest passes the complete runtime matrix for its
architecture.

## Phase 7: Complete Hardware Qualification

Run the already-qualified artifacts on physical arm64 and x86_64 Linux hardware.
Validate DRM master acquisition and release, input discovery, seat pause and
resume, Vulkan device creation, display hotplug, Xwayland, shell lifecycle,
locking, suspend, resume, and clean shutdown.

Hardware qualification records the graphics driver, kernel, seat provider, and
distribution, but none becomes an artifact selector. A driver-specific failure
is fixed at the Vulkan or kernel boundary and then requalified with the same
runtime contract.

Gate: both architecture artifacts pass physical compositor-session qualification
without distribution-specific Nucleus code or build outputs.

## Completion State

Ubuntu remains one supported packaging and qualification environment, not the
definition of the Linux product. Nucleus has one source graph, one Linux ABI
contract, one artifact per architecture, one relocatable runtime layout, and
small distribution adapters that own only host integration.

Non-systemd support remains out of scope until it is a real product target. When
that requirement exists, it replaces the systemd-dependent session and D-Bus
transport boundary directly; it does not layer another optional session path over
the completed design.
